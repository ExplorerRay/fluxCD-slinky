# Verification

Deployment health is **not** the same thing as function. Slurm schedules jobs
as root, so `sinfo` and Flux Kustomization readiness both stay green even when
SSSD is entirely offline and no real user can log in. Green dashboards prove
the manifests applied; they say nothing about identity. Each layer below must
be checked explicitly, in order, because a failure in one layer can hide
behind a healthy layer above it.

## 1. Cluster is up

For kind:

```sh
kubectl get nodes
```

For kubeadm/Kubespray, also check the system pods, since Calico and other
cluster-critical components live there:

```sh
kubectl get nodes
kubectl -n kube-system get pods
```

See [bootstrap.md](bootstrap.md) and the per-platform setup instructions in
[../bootstrap/kind/README.md](../bootstrap/kind/README.md) and
[../bootstrap/kubespray/README.md](../bootstrap/kubespray/README.md) if either
check fails to reach Ready.

## 2. Flux has reconciled

```sh
flux get kustomizations -A
flux get helmreleases -A
```

Expect **9 Kustomizations** and **7 HelmReleases**, all `Ready`. Flux applies
components in dependency order, and it fans out rather than running in a
single chain: `flux-cluster-repositories` gates `cert-manager` and
`rook-ceph`; `cert-manager` gates `mariadb-operator` and `slurm-operator`;
`rook-ceph` gates `freeipa`; `slurm-database` waits on `mariadb-operator`
plus `rook-ceph`; and `slurm` fans in from `slurm-operator`,
`slurm-database` and `freeipa`. A Kustomization never reconciles while
anything it depends on is unhealthy, so when one is stuck, check its own
`dependsOn` entries rather than assuming a linear order. See
[stack-overview.md](stack-overview.md) for the full dependency diagram.

This layer is necessary but not sufficient: a Ready Kustomization only means
the manifests applied and any built-in health checks passed. It does not mean
FreeIPA is serving identity or that a user can authenticate — see §4 and §5.

## 3. Storage

`rook-ceph` provides the cluster's default StorageClass, `ceph-block` (Ceph
RBD, ReadWriteOnce). `slurm-database` and `freeipa` both depend on it for
their PVCs. It also provides `ceph-filesystem` (CephFS, ReadWriteMany,
reclaim policy `Retain`), which backs a single PVC, `slurm-home` — the `/home`
shared by the login and compute pods. Confirm both StorageClasses exist and
`ceph-block` is default, and that PVCs are `Bound` rather than stuck
`Pending`:

```sh
kubectl get storageclass
kubectl get pvc -A
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph fs status
```

`ceph fs status` should show `ceph-filesystem` with one `active` MDS and one
standby — Rook always runs a standby per active MDS.

The dev-grade cluster is single-node, single-OSD, `replica: 1`, backed by a
loopback device over a sparse file — see the storage upgrade path in
[stack-overview.md](stack-overview.md) if PVCs fail to bind after a reboot
(the loop device does not survive one and must be recreated before kubelet
starts).

## 4. FreeIPA is actually serving identity

A Ready `freeipa` Kustomization means the StatefulSet applied — it does not
mean `ipactl` reports the FreeIPA services as running. First install takes
about 8m40s before the pod, `ipa-0` in namespace `freeipa`, becomes
ready. Check the server directly:

```sh
kubectl -n freeipa exec ipa-0 -- ipactl status
```

Also confirm at least one user/group exists to authenticate as — FreeIPA
starts empty, so with no users created, §5 will fail for a different reason
than a broken server. See the FreeIPA section of [bootstrap.md](bootstrap.md)
for creating users and groups with the `ipa` CLI, and for the one-time step of
extracting the FreeIPA CA into the `slurm` namespace (`freeipa-ca` ConfigMap),
which SSSD needs to validate the LDAPS certificate.

## 5. A user can log in and run a job

Find the login pod, then confirm SSSD resolves the user — this proves both
SSSD itself and the `freeipa-ca` mount are working:

```sh
kubectl -n slurm get pods --no-headers | awk '/login/{print $1}'
kubectl -n slurm exec <login-pod> -- getent passwd <user>
```

Log in over the login NodePort, **32222**, and run work:

```sh
ssh -p 32222 <user>@<node-ip>
pwd                  # /home/<user>
srun hostname

cat > job.sh <<'EOF'
#!/bin/bash
hostname
pwd
id -Gn
EOF
sbatch job.sh
sacct --format=JobID,JobName,User,State,ExitCode,NodeList
cat slurm-<jobid>.out
```

The session lands in `/home/<user>`, with no `Could not chdir to home
directory` warning. `/home` is one CephFS volume (the `slurm-home` PVC)
mounted in both the login and `slurmd` containers, and the home directory
itself is created by `pam_mkhomedir` at first login — mode `700`, owned by the
user's IPA uid and primary gid, populated from `/etc/skel`. So `job.sh` is
written straight into the home directory, the job runs there on the compute
node, and its `slurm-<jobid>.out` appears in the same directory on the login
pod. Expect the batch job to reach `COMPLETED` with exit code `0:0`, and the
output file to print the compute node's hostname and `/home/<user>`.

**First login with an SSH key needs the home to exist already.** sshd reads
`~/.ssh/authorized_keys` *during authentication*, and `pam_mkhomedir` only
runs in the PAM session stack *after* it — so a user whose home does not yet
exist cannot log in by key at all; there is no `authorized_keys` for sshd to
find. Either log in by password the first time, or create the home first from
the login pod — `su` runs the same `common-session` PAM stack sshd does, so
this goes through `pam_mkhomedir` exactly as a real login would:

```sh
kubectl -n slurm exec <login-pod> -c login -- su - <user> -c true
```

then install the key into `/home/<user>/.ssh/authorized_keys` (mode `600`,
`.ssh` mode `700`, both owned by the user).

**Shared `/home`.** These checks prove the volume really is shared, private
per user, and persistent. All were measured on kind-multi and kubeadm-single. From the cluster:

```sh
kubectl -n slurm get pvc slurm-home            # Bound, RWX, ceph-filesystem
kubectl get pv $(kubectl -n slurm get pvc slurm-home -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'   # Retain
kubectl -n slurm exec <login-pod> -c login -- sh -c 'mount | grep " /home "; stat -c "%u:%g %a" /home'
kubectl -n slurm exec <worker-pod> -c slurmd -- sh -c 'mount | grep " /home "; stat -c "%u:%g %a" /home'
```

Both containers must show the **same** `type ceph` mount (same
`/volumes/csi/csi-vol-…` path) at `/home`, and `/home` itself must be
`0:0 755` — root-owned and not world-writable, so no user can create another
user's home before that user's first login. Then, as the user:

```sh
stat -c '%u:%g %a' ~                 # <uid>:<gid> 700
touch ~/from-login
srun sh -c 'pwd; touch ~/from-compute; ls ~/from-login'
ls -ln ~/from-compute                # owned by <uid>, visible on login
mkdir /home/someoneelse              # must fail: Permission denied
```

and the negative checks from the login pod and the compute pod:

```sh
kubectl -n slurm exec <login-pod> -c login -- su -s /bin/sh nobody -c 'ls /home/<user>'
#   ls: cannot open directory '/home/<user>': Permission denied
kubectl -n slurm exec <worker-pod> -c slurmd -- sh -c 'ls -l /home; getent passwd <user>; echo rc=$?'
#   numeric owner on /home/<user>, rc=2
```

The last one is not a failure: outside a job step nss_slurm has no identity
to serve, so the compute pod shows the home directory's owner as a bare uid —
the same scoping as the `getent` negative check below. File ownership still
agrees across pods because login (SSSD) and compute (nss_slurm) resolve the
same IPA uid.

Finally, persistence: delete the login and worker pods
(`kubectl -n slurm delete pod <login-pod> <worker-pod>`), wait for them to
come back, and confirm every file above is still there from both sides.
Deleting the worker leaves its node `DOWN` (`Reason=slurm-operator: Pod is
terminating`) and it does not recover by itself; run
`scontrol update nodename=<node> state=RESUME` before the `srun` side.

**Identity resolution inside a job.** This is the check that would catch
a regression in nss_slurm — the mechanism, wired into the `slurmd`
image's stock `nsswitch.conf`, that resolves a job's identity on the
compute node without any SSSD there. Compare the login node against
inside a job:

```sh
id -Gn                        # on the login node
srun id -Gn                   # inside a job
srun id -un                   # inside a job
srun whoami                   # inside a job
srun getent passwd <user>     # inside a job
```

The group names must match on both sides, and `id -un`, `whoami`, and
`getent passwd` must all resolve fully inside the job — see
[runtime-requirements.md](runtime-requirements.md) for the nss_slurm
reference material and `enable_nss_slurm`, the one documented
`LaunchParameters` switch for it.

This check only proves anything if the test user has a supplementary
group to begin with. On a freshly built cluster, FreeIPA's default
`ipausers` group is non-POSIX and carries no `gidNumber`, so a user with
no other memberships has none — both sides trivially match. Put the user
in a POSIX group first — the user-creation block in
[bootstrap.md](bootstrap.md#freeipa) does this — and confirm it took
before trusting a pass:

```sh
id -Gn <user>                 # on the login node: more than one group
```

If it lists only the user's own group, add a POSIX group membership with
the bootstrap block's `ipa group-add-member` line and flush the SSSD cache.

Only then does a pass mean anything.

A useful negative check: `getent passwd <user>` run in the `slurmd`
container *outside* a job step should fail (rc=2). nss_slurm only
answers for users of steps currently running on that node, and this is
also how you confirm no SSSD has crept onto compute — if the lookup
succeeds outside a step, something other than nss_slurm is resolving it.

**Accounting parity.** Identity checks above only cover what a job sees
at runtime; they say nothing about what got *recorded*. Confirm the
accounting rows carry a resolved identity too, from the login pod:

```sh
sacct -a -X --format=JobID,User,UID,Group,GID,Account,State
```

`User` and `Group` must both be names rather than numbers, and `Account`
must be populated. This is worth re-running after any change to
`LaunchParameters` or to compute-node identity: those rows are written
from the launch credential, so a regression in what the controller sends
shows up here even when the job itself still completes. Compare rows
written before and after such a change — they should be identical.

**Controller/dbd lack of SSSD has a narrow, known cost.** The controller
and `slurmdbd` still have no working SSSD, by design — job submission,
in-job identity, and accounting records are unaffected. What breaks,
from a shell inside the controller pod: `sacct -u <user>` and `squeue -u
<user>` both fail with an invalid-user error (the numeric uid is not a
workaround — `sacct` validates the id through NSS before filtering), and
`sacct`'s `Group` column renders numeric instead of a name. Unfiltered
`sacct` still shows the right username, because it is stored as a string
in the accounting DB rather than looked up. Run filtered queries from
the login pod, where SSSD does run, to see resolved names.

If any of these checks fail, [troubleshooting.md](troubleshooting.md) is
keyed by symptom (e.g. login pod can't resolve a user, job loses its
secondary groups, SSH hangs).

## What "working" looks like

| Layer | Check | Expect |
| --- | --- | --- |
| Cluster | `kubectl get nodes` | All nodes `Ready` |
| Flux | `flux get kustomizations -A` / `flux get helmreleases -A` | 9 Kustomizations, 7 HelmReleases `Ready` |
| Storage | `kubectl get pvc -A` | All PVCs `Bound` |
| FreeIPA | `kubectl -n freeipa exec ipa-0 -- ipactl status` | All FreeIPA services running |
| Identity resolution | `kubectl -n slurm exec <login-pod> -- getent passwd <user>` | User resolves |
| Login | `ssh -p 32222 <user>@<node-ip>` | Session opens in `/home/<user>` |
| Job execution | `srun hostname`, then `sbatch job.sh` from `~` + `sacct` | `COMPLETED`, `0:0`; `slurm-<jobid>.out` in `~` |
| Shared `/home` | `srun touch ~/x`, then `ls -ln ~/x` on login | Same file, owned by the user's uid |
| Group parity | `id -G` vs `srun bash -c 'id -G'` | Same gids on both sides |

None of these substitute for the ones above it — a cluster can pass every row
above "Identity resolution" while identity is completely broken.

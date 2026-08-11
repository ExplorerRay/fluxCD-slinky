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
their PVCs. Confirm the StorageClass exists and is default, and that PVCs are
`Bound` rather than stuck `Pending`:

```sh
kubectl get storageclass
kubectl get pvc -A
```

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
for creating users via the web UI or the CLI, and for the one-time step of
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
srun hostname
sbatch job.sh
sacct --format=JobID,JobName,User,State,ExitCode,NodeList
```

Expect the batch job to reach `COMPLETED` with exit code `0:0`.

Two harmless surprises, so they aren't mistaken for bugs:

- SSH prints `Could not chdir to home directory /home/<user>` and drops you in
  `/` — there is no shared filesystem between login and compute pods.
- A batch job's `--output` file is written on the **compute** node's
  filesystem, not the login pod's, for the same reason.

**Supplementary-group parity.** This is the check that catches a missing
`LaunchParameters=send_gids`. Compare group membership on the login node
against inside a job:

```sh
id -G                        # on the login node
srun bash -c 'id -G'         # inside a job
```

They must list the **same** gids. If the job shows only the primary gid,
`send_gids` is missing and group-based access control (shared directories,
licence groups) will fail silently while the job still reports `COMPLETED` —
see [runtime-requirements.md](runtime-requirements.md) for the `send_gids`
reference material and where it is configured.

**Identity is numeric-only on compute nodes, by design.** Compute nodes
deliberately run no SSSD. `id -u` and `id -G` are correct there, but `id -un`
and `whoami` cannot resolve a name — this is expected, not a fault. Similarly,
`sacct`'s `User` column shows a numeric uid rather than a name when run from a
pod without SSSD (e.g. the controller); run it from the login pod to see the
resolved name.

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
| Login | `ssh -p 32222 <user>@<node-ip>` | Session opens (chdir warning is harmless) |
| Job execution | `srun hostname`, `sbatch job.sh` + `sacct` | `COMPLETED`, `0:0` |
| Group parity | `id -G` vs `srun bash -c 'id -G'` | Same gids on both sides |

None of these substitute for the ones above it — a cluster can pass every row
above "Identity resolution" while identity is completely broken.

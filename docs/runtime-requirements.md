# Runtime Requirements

The in-cluster FreeIPA identity server (`infrastructure/freeipa`) runs
systemd as PID 1. That single fact drives a set of container-runtime and
host-kernel requirements that are easy to get wrong and, when wrong, fail
silently — a pod stuck at `0/1 Running` with an empty log, or a job that
quietly loses a supplementary group. This document collects the reference
material behind those requirements: the two ways to grant systemd the
cgroup access it needs, the platform-specific accommodations already
implemented for kind and kubeadm, the hardening options that look
reasonable but break the deployment, how Slurm's compute nodes
resolve identity via `nss_slurm` even though they run no SSSD, what the
controller can and cannot do without SSSD (and why access control here
belongs in Slurm accounts), and the traps around the CephFS `/home`
they share with the login nodes.

## systemd in a container needs a writable cgroup

The FreeIPA image runs systemd as PID 1, so it needs cgroup and mount
access. There are two ways to grant that, with very different **host
kernel** requirements — pick based on your host.

## Option A — privileged (simplest; DEV ONLY)

Container root ≈ host root. It starts on any kernel with no extra setup.
The catch is SELinux: on an **SELinux-enforcing host** the container's
systemd (with `CAP_SYS_ADMIN`) mounts selinuxfs and reloads the *image's*
SELinux policy into the **shared host kernel**, unmapping the host's
`container_*` types and breaking docker/containerd host-wide. So on
enforcing hosts you MUST set the host to **SELinux permissive** while
FreeIPA runs (`setenforce 0`; the policy swap is then harmless), or use
Option B. On non-SELinux hosts this is a clean no-op.

## Option B — user namespaces (more secure)

`hostUsers: false` + non-privileged. This is what `infrastructure/freeipa`
ships, and it is **verified working** on single-node kind: `privileged:
false` with **no added capabilities at all**. A user namespace confines
the container so it cannot touch host-global kernel state (including
SELinux). It has a hard **kernel-version floor**:

> ⚠️ **Kernel requirement: host kernel ≥ 6.3.** On older kernels a
> `hostUsers: false` pod fails at *sandbox creation* with
> `error mounting "sysfs" to rootfs at "/sys": operation not permitted`
> — the kernel refuses to mount sysfs inside a user namespace. (Do not go
> looking for a matching `dmesg` line; see the note under the kind
> accommodations below.)
>
> **RHEL / Rocky / AlmaLinux 9.x ship kernel 5.14 and freeze it for the
> whole release** (`dnf upgrade` stays on 5.14), so user-namespace pods
> will **not** start there. To use Option B you need kernel ≥ 6.3 — e.g.
> ELRepo `kernel-ml` (unsupported/"as-is"; needs Secure Boot off + DKMS
> rebuilds), or RHEL/Rocky 10 (ships 6.12), or any distro on a 6.x kernel.
>
> It also needs containerd ≥ 2.1 with `cgroup_writable = true` and
> `SystemdCgroup = true` (see freeipa/freeipa-container
> `tests/containerd-2.1-config.toml`) so non-privileged systemd can manage
> its cgroup subtree.

## Platform accommodations

Option B needs the host's containerd configured to hand out a writable
cgroup, and — on kind specifically — a second fix for a masked sysfs. Both
platforms already implement their accommodation; this section explains
what each does and why, since the failure modes are opaque if either goes
missing.

### kind

Under kind, Option B needs two extra things. Both are now implemented in
`bootstrap/kind/` — you do **not** have to do anything by hand — but they
are described here because the failure modes are opaque if either goes
missing.

**1. `cgroup_writable` on the node's containerd** — injected by
`containerdConfigPatches` in `bootstrap/kind/kind-config-single.yaml`. Note
the patch deliberately uses the **containerd config version 2** plugin
path (`plugins."io.containerd.grpc.v1.cri"…`), not the version-3 spelling
from upstream's reference file: kind's node image ships `config.toml` at
`version = 2`, and a version-3 patch against it is silently discarded. On
`kindest/node:v1.36.1` the node already ships containerd 2.3.1 with
`SystemdCgroup = true`, so `cgroup_writable` is the only key that actually
changes. Verify:

```sh
docker exec kind-control-plane containerd --version
docker exec kind-control-plane containerd config dump | grep cgroup_writable
```

**2. A fully-visible sysfs on the node** (kind issue
[#3436](https://github.com/kubernetes-sigs/kind/issues/3436), still open)
— `bootstrap/kind/setup.sh` mounts one at `/mnt/sysfs` on every node. kind
bind-mounts `/sys/devices/virtual/dmi/id/product_uuid` and `product_name`
read-only into each node, which leaves the node's sysfs partially covered;
the kernel then refuses runc's sysfs mount inside a user namespace.
Without it, **every** `hostUsers: false` pod — not just FreeIPA — fails at
*sandbox creation*, never starting a container at all:

```
Failed to create pod sandbox: ... runc create failed: unable to start container
process: error during container init: error mounting "sysfs" to rootfs at "/sys":
mount src=sysfs, dst=/sys, ... flags=MS_RDONLY|MS_NOSUID|MS_NODEV|MS_NOEXEC:
operation not permitted
```

Note the fix is to add a *fresh, child-free* sysfs instance at a new path,
not to uncover `/sys` — unmounting the two product-file covers is not
sufficient, because `/sys` still has other submounts beneath it. Do not
expect `VFS: Mount too revealing` in `dmesg`; on kernel 6.12 the userspace
error above appears with no corresponding kernel log line. Verify:

```sh
docker exec kind-control-plane mount | grep sysfs   # expect an entry on /mnt/sysfs
```

### kubeadm

Under kubeadm/Kubespray, Option B needs the same `cgroup_writable` setting
that kind gets from `containerdConfigPatches` — but scoped to FreeIPA
rather than applied to every pod on the node. Two pieces, both in git,
both applied by Kubespray and Flux with no manual step:

1. **A second containerd runtime handler**, `runc-cgroupfs`, declared via
   `containerd_extra_args` in
   `bootstrap/kubespray/inventory/group_vars/all/containerd.yml`. It is
   the only handler with `cgroup_writable = true`; the default `runc`
   handler is left alone.
2. **A RuntimeClass of the same name** plus `runtimeClassName:
   runc-cgroupfs` on the FreeIPA StatefulSet, in
   `infrastructure/freeipa/overlays/kubeadm/`. Only FreeIPA references it.

Why scoped and not simply set on the default `runc` handler — two
reasons, one mechanical and one security:

- **Kubespray cannot add the key to the existing `runc` table.** As of
  v2.31.0 its containerd template emits only `runtime_type`,
  `base_runtime_spec` and the `options` block per runtime, and
  `cgroup_writable` is a *runtime-level* key — a sibling of `runtime_type`,
  not an `options` entry. `containerd_extra_runtime_args` injects into the
  CRI plugin section, one level too high, and redeclaring the `runc`
  table would be duplicate TOML and break parsing. Declaring a *new*
  table Kubespray never emits is valid (TOML allows defining a
  super-table after a sub-table).
- **`cgroup_writable` is per-runtime-handler, not per-pod.** Enabling it
  on the default handler gives **every** pod a writable cgroup, which
  lets an ordinary container rewrite its own limits — verified: a
  64Mi-limited pod raised its own `memory.max` to 512Mi. Scoping it keeps
  that away from normal workloads.

Unlike kind, a kubeadm node needs **no sysfs workaround** — that one is
specific to kind's product_uuid bind-mounts. A stock Kubespray node's
`/sys` is fully visible, so `hostUsers: false` pods reach sandbox creation
fine.

The failure mode without this accommodation is opaque, so it is worth
recognising. containerd mounts `/sys/fs/cgroup` read-only and never chowns
the delegated subtree into the pod's uid map, so systemd's write to
`cgroup.subtree_control` fails, systemd never reaches `basic.target`,
dbus never starts, `ipa-server-install` never runs, and the readiness
probe fails forever with:

```
Failed to connect to bus: No such file or directory
```

The pod sits `0/1 Running` with **zero restarts** and an empty or
near-empty log, which reads like a hang rather than a misconfiguration.

## What the scoped handler grants (and does not) — kubeadm

This measures the **kubeadm** setup, where `cgroup_writable` is confined to
the `runc-cgroupfs` handler. kind differs — see the note at the end of this
section. Measured on Debian 13 and Rocky Linux 10 (containerd 2.2.3,
k8s v1.35.4):

| | ordinary pod (default `runc`) | FreeIPA (`runc-cgroupfs` + userns) |
| --------------------------------- | ----------------------------- | ---------------------------------- |
| `/sys/fs/cgroup` mount            | `ro`                          | `rw`                               |
| write `cgroup.subtree_control`    | EROFS                         | **allowed** (what systemd needs)    |
| raise its own `memory.max`        | EROFS                         | **EPERM — withheld**                |
| see host or sibling-pod cgroups   | no                            | **no**                             |

The last two rows are the point. Containers get a **private cgroup
namespace**, so a pod's own cgroup is the root of its view — it cannot
name or reach the host hierarchy or another pod's cgroup. And under a
user namespace containerd performs correct cgroup v2 **delegation
containment**: it chowns `cgroup.procs` and `cgroup.subtree_control` into
the pod's uid map but deliberately leaves `memory.max` outside it. So the
FreeIPA pod can manage cgroups beneath itself and cannot raise even its
own limits.

Contrast with the privileged model (Option A), which gets a writable
cgroupfs for free but runs in the **host** cgroup namespace with the
host's full `/dev` — it can see and write the entire host hierarchy.

Verify a node after provisioning:

```sh
containerd --version                                    # need >= 2.1
sudo /usr/local/bin/containerd config dump | grep -E 'cgroup_writable|SystemdCgroup'
#   expect cgroup_writable = false on runc, = true on runc-cgroupfs
kubectl get runtimeclass runc-cgroupfs
kubectl -n freeipa get pod ipa-0 -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl -n freeipa exec ipa-0 -- mount | grep ' /sys/fs/cgroup '   # expect rw
```

If the handler is missing from containerd, pods using the RuntimeClass
fail to start with a clear handler error rather than hanging at `0/1` —
a deliberate improvement over the silent failure above. Requires
containerd >= 2.1; older builds silently ignore `cgroup_writable`.

Verified working 2026-08-10 on single-node kubeadm clusters (Kubespray
v2.31.0, k8s v1.35.4, containerd 2.2.3) on **both** Debian 13 and Rocky
Linux 10.

## Dead ends

Several tempting shortcuts and hardening tweaks look like they should
work here. None of them do; the manifest deliberately avoids all of them.

- **Capabilities are not a middle ground.** The rw-vs-ro cgroupfs
  decision is made from the `privileged` boolean at OCI-spec generation
  time, so `privileged: false` with `SYS_ADMIN` (or five more
  capabilities) still yields a read-only cgroupfs — verified. Worse,
  adding `capabilities.add: [SYS_ADMIN]` actively breaks the FreeIPA
  install: the server installs, then the final `ipa-client-install` step
  fails with `KerberosError: No valid Negotiate header in server
  response` (httpd logs `gss_acquire_cred[_from]() failed to get server
  creds … SPNEGO cannot find mechanisms to negotiate`) and the installer
  rolls everything back. Inside the user namespace systemd needs no extra
  capability; granting one lets it apply per-service sandboxing that
  breaks the `/tmp`-based ccache handoff between httpd and gssproxy.

- **`Delegate=yes` is not the missing piece**, and is already present:
  both `containerd.service` and every `cri-containerd-*.scope` carry it.
  That only tells host systemd not to interfere with the subtree; it
  changes neither the read-only cgroupfs mount inside the container's
  mount namespace nor the ownership of the delegation files. Verified: a
  container that is host root **and** owns `cgroup.subtree_control` with
  mode 0644 still fails with `EROFS`, because the kernel checks the
  mount's read-only flag before permissions.

- **`readOnlyRootFilesystem: true` breaks the image.** Upstream sets
  this, but upstream runs under podman, which materialises the image's
  `VOLUME` declarations. Kubernetes ignores them, so the image's init
  dies at once with `cp: cannot create regular file '/etc/hosts.dist':
  Read-only file system`. The writable `/run`, `/tmp` and `/dev/shm`
  emptyDirs in the manifest cover what those volumes would have.

In all three cases this is DEV ONLY (see the [README](../README.md)
security note).

### kind does not scope it

Worth stating plainly, because it sits awkwardly beside the reasoning above:
kind's `containerdConfigPatches` sets `cgroup_writable = true` on the
**default** `runc` handler, and the kind overlay uses no RuntimeClass. So on
kind *every* pod gets a writable cgroup — exactly the exposure the kubeadm
path is scoped to avoid, including the ability for an ordinary pod to raise
its own `memory.max`. That is accepted rather than overlooked: a kind cluster
is a disposable single-developer sandbox in Docker, so the blast radius is
one workstation. If kind ever hosts anything shared, give it the same
RuntimeClass treatment as kubeadm.

## Compute nodes and nss_slurm

Only the login pods get SSSD. The controller does not run it either, by
upstream design rather than omission — see [Controller identity and Slurm
accounting](#controller-identity-and-slurm-accounting) — and compute nodes
deliberately do not: `nodesets.<name>.ssh.enabled` is the only gate that
gives slurmd an `sssdConfRef` (`nodeset-cr.yaml` sets
`spec.ssh.sssdConfRef` only inside its `if $nodeset.ssh.enabled` block,
unlike `loginset-cr.yaml` which sets it unconditionally), so unless
`ssh`-to-compute is wanted there is no reason to run SSSD on every
compute pod.

That is safe because the `slurmd` image ships `nss_slurm` wired into its
stock `nsswitch.conf` — `passwd: files slurm sss systemd` and `group:
files slurm [SUCCESS=merge] sss [SUCCESS=merge] systemd`. Nothing in
this repo mounts or edits that file; it is the image default. Measured
on Debian 13 and Rocky Linux 10 with zero configuration applied, as a
user in a secondary IPA group, from the login pod:

| probe | result |
| --- | --- |
| `srun id -un` / `srun whoami` | resolves to the username |
| `srun id -Gn` | primary **and** secondary group names |
| `srun getent passwd <user>` | full entry, including GECOS, home, shell |

It is genuinely `nss_slurm` doing this, not SSSD leaking onto compute:
there is no `sssd` process and no `/etc/sssd/sssd.conf` in the `slurmd`
container. The discriminator is scope — `getent passwd <user>` run
*outside* a job step on that node returns rc=2, while the same lookup
*inside* a step resolves. Answering only for users of steps currently
running on the node is precisely the nss_slurm contract.
`/etc/nss_slurm.conf` is absent and not needed either: the hostname
matches `NodeName` and `SlurmdSpoolDir` is the default
`/var/spool/slurmd`.

Worth knowing if you go digging: this works even though slurmctld itself
has no working SSSD, and it worked *before* `enable_nss_slurm` was set.
The mechanism is `AuthInfo=use_client_ids`, which lets the `auth/slurm`
plugin authenticate users without relying on LDAP or the operating
system. `nss_slurm.html` is explicit that the identity nss_slurm serves
can be populated "on information from client systems if
`AuthInfo=use_client_ids` is set" rather than from slurmctld's own
lookup — which is exactly this topology, with real user information only
on the login nodes.

Nothing in this repo sets it, and neither does the chart (checked on
1.2.1 and 1.2.3): the slurm-operator hardcodes it alongside
`AuthType=auth/slurm` in `internal/builder/common/const.go`. It is a
property of the operator rather than of anything version-controlled
here, so it is worth re-checking after an operator upgrade:

```sh
scontrol show config | grep AuthInfo
```

The same option is what lets slurmctld and slurmdbd work without SSSD at
all; what that does and does not cover is in [Controller identity and
Slurm accounting](#controller-identity-and-slurm-accounting).

`LaunchParameters=send_gids` is not an option in 26.05 — the only
occurrence of that string in Slurm's documentation is inside the
*negative* option `disable_send_gids`, which turns off default
gid/user_name sending and is explicitly ignored once `enable_nss_slurm`
is set. Set `LaunchParameters=enable_nss_slurm` through
`controller.extraConfMap` instead — but be precise about what it does
here. It is the switch `nss_slurm.html` prescribes, making *slurmctld*
look up and send passwd/group details as part of the launch credential,
and it enables the `scontrol getent <node>` diagnostic. It is not what
makes identity resolve on this stack: `use_client_ids` already populates
the credential from the login client, which is why resolution was
measured working with the flag absent. Set it regardless — it is the
documented, portable mechanism, and it keeps identity from depending
solely on an operator-side constant this repo cannot pin. Never patch
the rendered Controller CR's
`extraConf` field directly: the chart's controller helper seeds its
config list from `extraConf`/`extraConfMap` and then **appends** the
generated `PartitionName` line, so patching the rendered field bypasses
that and leaves the cluster with `No partitions in the system` — every
job then fails with `No partition specified or system default
partition`.

Interactive job identity (`srun --pty`) is unaffected by any of this —
nss_slurm resolves it the same way a batch job does. What SSSD on
compute would still be needed for is `ssh`-to-compute via
`pam_slurm_adopt` (the `nodesets.<name>.ssh.enabled` gate above), which
is a distinct feature from job identity.

## Controller identity and Slurm accounting

Neither slurmctld nor slurmdbd runs SSSD, and that is upstream's design
rather than a gap in this repo. The slurm-operator architecture doc
(`docs/concepts/architecture.md`, `use_client_ids`) describes a cluster
"where only login nodes have access to LDAP or OS user data", and in July
2026 the maintainers declined to add SSSD to the controller
(SlinkyProject/slurm-operator#93, #129) to keep the operator agnostic to
the identity provider; their suggested route for a site that needs it is
a custom `slurmctld` image with SSSD set up in it and its configuration
mounted through the controller's `podSpec`, which this repo does not do.
Chart 1.2.3's top-level `sssd:` block — "Cluster
SSSD configuration" — is one shared `sssd.conf`, consumed only by
`loginset-cr.yaml` and by `nodeset-cr.yaml` under `ssh.enabled`; nothing
renders it into the Controller, Accounting or RestApi CRs, none of which
has an `sssdConfRef` field.

The `slurmctld` image does ship SSSD and a supervisord `[program:sssd]`,
but the operator mounts no `sssd.conf` and runs the pod as non-root uid
401, which SSSD cannot start under. On every controller start that
program exits a few times with `No /etc/sssd/sssd.conf` and supervisord
marks it `FATAL`. That log noise is expected, not a fault — slurmctld is
unaffected.

**How the controller knows users anyway.** Every `auth/slurm` credential
carries the caller's uid and username (`AuthInfo=use_client_ids`), and
slurmctld and slurmdbd copy that pair into their accounting user table
(`assoc_mgr_set_uid` in Slurm's `auth/slurm` plugin). So everything
keyed by Slurm *accounting* works for a directory user, provided the
user is registered with `sacctmgr` ([bootstrap.md](bootstrap.md#freeipa),
step 3). The mapping is learned from the user's own first request: until
then `scontrol show assoc_mgr users=<user>` lists them with uid
`4294967294` (unknown), which does not affect their own jobs, because the
submission itself carries the uid — measured with enforcement on, on a
user's first job straight after a slurmctld restart. This repo sets
`AccountingStorageEnforce=associations`
(`applications/slurm/base/values.yaml`), so a user who is *not*
registered is refused at submission with `Invalid account or
account/partition combination specified`. Under the chart default
(`none`) the same user's jobs would run, recorded with `AssocID=0` and an
empty `Account`.

**What fails is anything where slurmctld must resolve a name or group
itself**, through its own NSS. Measured on chart 1.2.3 / Slurm 26.05.4
with a FreeIPA user in a POSIX group:

| Feature | Without controller SSSD | Use instead |
| --- | --- | --- |
| A job's association, account, QoS | works | — |
| Reservation `Accounts=` | works: a job under the account is admitted, one under another account is denied, and with `AccountingStorageEnforce=associations` a user cannot claim an account they are not in (below). With enforcement it also admits the account's sub-accounts, so `Accounts=root` admits every registered user | — |
| Partition `AllowAccounts=`/`AllowQos=` | works (from Slurm's source, not measured); `AllowAccounts` needs `AccountingStorageEnforce=associations`, as reservation `Accounts=` does | — |
| Partition `AllowGroups=` | denies every directory user, members of the group included, whether given the group name or its numeric gid | `AllowAccounts=` / `AllowQos=` |
| Reservation `Users=` | rejected at creation (`Reservation request has invalid user`), by name or by numeric uid, even after slurmctld has learned the uid | reservation `Accounts=` |
| Reservation `Groups=` | same lookup as `AllowGroups` (from source, not measured) | reservation `Accounts=` |
| `sacct -u`, `squeue -u` in the controller pod | `Invalid user`, by name or by numeric uid | run them from the login pod |

`AllowGroups=` means Unix (POSIX) groups as `id` shows them, not Slurm
accounts; the two are only linked if a site names accounts after groups.
Slurm's group check (`validate_group()`, `get_groups_members()`) reads
only the controller's NSS and never the groups carried in the user's
credential. Reservation `Users=` likewise converts names with
`getpwnam` rather than consulting the accounting table. Root and
`SlurmUser` pass `AllowGroups` unconditionally, and root was admitted to
an `Accounts=` reservation it was not part of, so test access control as
an ordinary user. `AllowUserBoot` in `helpers.conf` also names users,
and has not been measured.

**Accounts are only a boundary once enforced, hence
`AccountingStorageEnforce=associations`.** The account rows above work
on the account a job names, and with `AccountingStorageEnforce` unset
nothing stops a user with no association at all from naming any
account. Measured without enforcement: such a FreeIPA user was refused
by an `Accounts=root` reservation when submitting plainly, admitted as
soon as they added `-A root`, and the job was recorded with
`Account=root` and `AssocID=0` (a registered user's `-A root` was still
refused by the reservation). Measured with `associations`: `-A root`, with
or without the reservation, is refused at submission (`Invalid account
or account/partition combination specified`), as is any job from an
unregistered FreeIPA user, while a registered user's own jobs, `srun`
steps and `Accounts=` reservation run as before. Enforcement also changes
what a reservation's `Accounts=` matches: without it only the named
account (an `Accounts=root` reservation refused a `sciteam` member);
with it the job's whole association chain, so the same reservation
admitted them, because every account sits under `root`, while one for a
sibling account still refused them. Reserve for a leaf account, or for a
parent account on purpose to cover the group under it.

`sacct`'s `User` column comes from the job's association when it has one;
otherwise the uid is resolved by whoever runs `sacct`, so a job without an
association shows a bare uid from the controller pod and the name from
the login pod. `Group` is always resolved by the reader.

None of this needs SSSD on the controller if access control is expressed
as Slurm accounts and QoS rather than Unix groups or user lists. That
does mean keeping accounting in step with FreeIPA: group membership does
not flow into Slurm by itself, so a new user needs a `sacctmgr add user`
alongside the `ipa user-add`, or that user cannot submit at all.
`associations` is the part of `AccountingStorageEnforce` that makes
accounts a boundary; to also apply association and QoS limits, extend it
to `associations,limits,qos` in `controller.extraConfMap`.

## Shared /home on CephFS

Login and compute pods share one `/home`: a single ReadWriteMany PVC,
`slurm-home` (`applications/slurm/base/home-pvc.yaml`), on the
`ceph-filesystem` StorageClass, mounted at `/home` in the `login` and `slurmd`
containers. Four things about it are easy to break and not obvious from the
manifests.

**Home directories come from a PAM override.** The login image ships
`pam_mkhomedir` with its `pam-auth-update` profile disabled. The
`slurm-login-pam` ConfigMap (`applications/slurm/base/pam/common-session`)
holds the image's own `common-session` after `pam-auth-update --enable
mkhomedir`, with `skel=/etc/skel umask=0077` on that line, and is mounted over
`/etc/pam.d/common-session` with `subPath`. Two consequences:

- A `subPath` mount hides the image's file entirely, so a login image upgrade
  cannot change it. Re-diff the ConfigMap against the new image's stock file
  whenever the login image tag changes; the mkhomedir line must be the only
  difference. Regenerate it from the image rather than by hand, then re-add
  `skel=/etc/skel umask=0077` to the mkhomedir line (keep pam-auth-update's
  trailing spaces so the diff stays one line):

  ```sh
  docker run --rm --entrypoint sh ghcr.io/slinkyproject/login:<tag> -c \
    'pam-auth-update --enable mkhomedir --package >/dev/null 2>&1;
     cat /etc/pam.d/common-session'
  ```
- A `subPath` mount never picks up ConfigMap edits — not after the usual
  kubelet sync delay, not ever. Restart the login pod after changing it.

**Never set `fsGroup` on a pod that mounts it.** The CephFS CSI driver runs
with `CSI_CEPHFS_FSGROUPPOLICY: File`, so a pod `securityContext.fsGroup`
makes kubelet recursively chown and chmod the *whole* volume to that group on
every mount — every user's home, flattened to one group. Neither pod sets it
today; `applications/slurm/base/values.yaml` carries the warning beside the
volume.

**`/home` root ownership.** `pam_mkhomedir` runs as root and creates each
`/home/<user>` itself, so the volume root must be root-owned and not
world-writable, or any user could pre-create another user's home. A
`home-perms` init container on the login pod pins it to `root:root 0755`. On
kind-multi it was a no-op: ceph-csi (v3.12) already created the subvolume
root as `0:0 755`. It stays as a defensive guard against a ceph-csi or Ceph
default changing.

**Deleting home data is never automatic.** The PVC carries
`kustomize.toolkit.fluxcd.io/prune: disabled`, so removing it from git does
not make Flux delete it. The `slurm` Namespace carries the same annotation,
because pruning the namespace — say, by deleting the `slurm` Kustomization —
would delete every PVC in it regardless of the PVC's own annotation. The
StorageClass is `reclaimPolicy: Retain`, so a
deleted claim leaves its PV `Released` and the CephFS subvolume intact. The
filesystem itself has `preserveFilesystemOnDelete: true`. Note the claim
cannot actually be deleted while the login or worker pods mount it — the
`kubernetes.io/pvc-protection` finalizer holds it `Terminating` until they are
gone.

Recovery after the claim *has* been deleted — measured with a throwaway
claim on `ceph-filesystem`, which re-bound to its old PV and returned the
original data:

```sh
pv=<the Released PV's name>
kubectl get pv "$pv"                                   # STATUS Released, RECLAIM POLICY Retain
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph fs subvolume ls ceph-filesystem csi             # subvolume still listed
kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.subvolumeName}{"\n"}'
kubectl patch pv "$pv" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
```

then recreate `slurm-home` with `spec.volumeName: <pv>` added (same size,
access mode and StorageClass), and it binds back to the same data. With
`Retain`, Kubernetes never removes the subvolume: discarding home data for
good means deleting the PV *and* running `ceph fs subvolume rm
ceph-filesystem <subvolume> csi` from the toolbox.

## See also

- [Bootstrap guide](bootstrap.md) — the manual FreeIPA and Slurm identity
  steps this document's requirements support.
- [Verifying identity end to end](verification.md) — confirm SSSD, LDAPS,
  and `nss_slurm` resolution actually work after deploying against these
  requirements, and that jobs are recorded under a Slurm account.
- [Shared `/home` checks](verification.md#5-a-user-can-log-in-and-run-a-job)
  — confirm the CephFS `/home` is shared, private per user, and persistent.

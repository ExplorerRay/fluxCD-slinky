# Runtime Requirements

The in-cluster FreeIPA identity server (`infrastructure/freeipa`) runs
systemd as PID 1. That single fact drives a set of container-runtime and
host-kernel requirements that are easy to get wrong and, when wrong, fail
silently — a pod stuck at `0/1 Running` with an empty log, or a job that
quietly loses a supplementary group. This document collects the reference
material behind those requirements: the two ways to grant systemd the
cgroup access it needs, the platform-specific accommodations already
implemented for kind and kubeadm, the hardening options that look
reasonable but break the deployment, and how Slurm's compute nodes
resolve identity via `nss_slurm` even though they run no SSSD.

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

Only the login pods get SSSD. The controller cannot have it at all (the
chart exposes no `sssdConfRef` on the Controller CR), and compute nodes
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
with zero configuration applied, as a user in a secondary IPA group,
from the login pod:

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
has no working SSSD. `AuthInfo=use_client_ids` is documented to let the
`auth/slurm` plugin authenticate users without relying on LDAP or the
operating system, "coupled with nss_slurm", precisely so a cluster can
operate with real user information only on the login nodes.

That lack of controller SSSD is not free. From a shell inside the
controller pod: `sacct -u <user>` and `squeue -u <user>` both fail with
an invalid-user error (the numeric uid is not a workaround — `sacct`
validates the id through NSS before filtering), and `sacct`'s `Group`
column renders numeric instead of a name. Unfiltered `sacct` still shows
the right username, because it is stored as a string in the accounting
DB rather than looked up. Job submission, in-job identity, and
accounting records themselves are all unaffected. `AllowGroups=` on a
partition, `Users=` on a reservation, and `AllowUserBoot` in
`helpers.conf` would all need real NSS on the controller to work; none
of them are used today.

`LaunchParameters=send_gids` is not an option in 26.05 — the only
occurrence of that string in Slurm's documentation is inside the
*negative* option `disable_send_gids`, which turns off default
gid/user_name sending and is explicitly ignored once `enable_nss_slurm`
is set. Set `LaunchParameters=enable_nss_slurm` through
`controller.extraConfMap` instead: it is the one documented switch for
this feature, and it also enables the `scontrol getent <node>`
diagnostic on compute nodes. Never patch the rendered Controller CR's
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

## See also

- [Bootstrap guide](bootstrap.md) — the manual FreeIPA and Slurm identity
  steps this document's requirements support.
- [Verifying identity end to end](verification.md) — confirm SSSD, LDAPS,
  and `nss_slurm` resolution actually work after deploying against these
  requirements.

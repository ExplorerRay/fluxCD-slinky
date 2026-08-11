# Bootstrap

Create the Kubernetes cluster before installing Flux. Flux should start only
after the target cluster can run normal pods.

## kind

See [bootstrap/kind/README.md](../bootstrap/kind/README.md) for setup instructions.

kind allows you to run Kubernetes clusters in Docker containers, useful for
local development. Both the single-node and multi-node variants are created
with `bash bootstrap/kind/setup.sh single` or `bash bootstrap/kind/setup.sh
multi` — the argument selects the kind config (single control-plane node, or
control-plane + 2 workers) and the cluster name is always fixed to `kind` so
node hostnames stay deterministic.

### Readiness check

After cluster creation, verify it is ready:

```sh
kubectl get nodes
```

### Flux path

Deploy Flux with the entrypoint matching the variant you created:

```yaml
path: ./clusters/kind-single   # single-node kind cluster
path: ./clusters/kind-multi    # multi-node kind cluster
```

## kubeadm

See [bootstrap/kubespray/README.md](../bootstrap/kubespray/README.md) for setup instructions.

kubeadm with Kubespray is used to provision Kubernetes clusters on bare metal or
VMs. `clusters/kubeadm-single` and `clusters/kubeadm-multi` are the Flux
entrypoints for the kubeadm-based cluster variants. Kubespray provisions the
cluster and installs Calico before Flux starts.

The non-privileged FreeIPA StatefulSet (`infrastructure/freeipa`) additionally
needs a containerd runtime handler that delegates a writable cgroup subtree.
Kubespray configures it from `inventory/group_vars/all/containerd.yml` and Flux
applies the matching RuntimeClass, so no manual step is required — see [the
kubeadm accommodation](#the-kubeadm-accommodation-implemented).

Kubespray clusters can range from single-node (with control-plane, etcd, and
worker roles on one machine) to multi-node (with separate control-plane and
worker nodes). Example inventories are provided at
`bootstrap/kubespray/inventory/single.yml` (one schedulable node) and
`bootstrap/kubespray/inventory/multi.yml` (separate control-plane and workers).
They map to Flux paths and OSD hosts as follows:

| Inventory     | Flux path              | OSD host |
| ------------- | ----------------------- | -------- |
| `single.yml`  | `./clusters/kubeadm-single` | `node1`  |
| `multi.yml`   | `./clusters/kubeadm-multi`  | `node2`  |

### Calico network plugin

In the Kubespray inventory, use Calico as the network plugin:

```yaml
kube_network_plugin: calico
container_manager: containerd
```

For a simple on-premises cluster, start with VXLAN unless you intentionally want
BGP-routed pod networks:

```yaml
calico_datastore: "kdd"
calico_network_backend: vxlan
calico_vxlan_mode: "Always"
calico_ipip_mode: "Never"
nat_outgoing: true
```

### Readiness check

After Kubespray completes, confirm the cluster is ready:

```sh
kubectl get nodes
kubectl -n kube-system get pods
```

### Flux path

Deploy Flux with the entrypoint matching the inventory you provisioned:

```yaml
path: ./clusters/kubeadm-single   # inventory/single.yml
path: ./clusters/kubeadm-multi    # inventory/multi.yml
```

## Rook-Ceph loop device preparation

The dev-grade single-node Ceph cluster (`infrastructure/rook-ceph`) has no spare
disk, partition, or LV. Its single OSD is backed by a **loopback device over a
sparse file**: `/dev/loop100` backed by `/var/lib/rook/osd0.img` (200G sparse,
allocated on demand). Loop attachments do **not** survive a reboot, so the
device must be (re)created on every boot **before** kubelet — and therefore Rook
and Ceph — start.

### Kernel modules

The host kernel must provide the `rbd` and `ceph` modules. Load and persist
them:

```sh
sudo modprobe rbd ceph
echo -e "rbd\nceph" | sudo tee /etc/modules-load.d/rook-ceph.conf
```

### kubeadm: systemd unit

Install the boot-time systemd unit and helper script from
`bootstrap/rook-ceph/`:

```sh
sudo install -m 0755 bootstrap/rook-ceph/rook-osd-loop.sh /usr/local/sbin/rook-osd-loop.sh
sudo install -m 0644 bootstrap/rook-ceph/rook-osd-loop.service /etc/systemd/system/rook-osd-loop.service
sudo systemctl daemon-reload
sudo systemctl enable --now rook-osd-loop.service
```

The unit creates the sparse file with `truncate` if missing and attaches it
with `losetup`, ordered `Before=kubelet.service`. See
[bootstrap/rook-ceph/README.md](../bootstrap/rook-ceph/README.md).

### kind: setup step

`bootstrap/kind/setup.sh <single|multi>` creates the sparse file and runs
`losetup /dev/loop100` on the host before `kind create cluster`. The loop
device and its backing image are mounted into the node that hosts the OSD via
`extraMounts` in `bootstrap/kind/kind-config-single.yaml` (the sole
control-plane node) or `bootstrap/kind/kind-config-multi.yaml` (a worker
node). Re-running `setup.sh` after a reboot re-attaches the device
idempotently.

### Node hostname

Each cluster entrypoint variant already bakes in a deterministic OSD node
hostname, so no manual edit is normally required:

| Variant           | OSD node hostname   |
| ----------------- | -------------------- |
| `kind-single`      | `kind-control-plane` |
| `kind-multi`       | `kind-worker`         |
| `kubeadm-single`   | `node1`               |
| `kubeadm-multi`    | `node2`               |

These come from `infrastructure/rook-ceph/overlays/<variant>/node-values.yaml`,
which is layered on top of the shared `overlays/kind` or `overlays/kubeadm`
values via a second HelmRelease `valuesFrom` entry. Only custom setups —
a kubespray inventory that uses different hostnames than `node1`/`node2`, or a
kind cluster created under a different `--name` — need to edit the relevant
`node-values.yaml` to match the real node hostname:

```sh
kubectl get nodes -o name
```

## FreeIPA

The in-cluster FreeIPA identity server (`infrastructure/freeipa`) is a
hand-rolled StatefulSet reachable at `ipa.freeipa.svc.cluster.local` (realm
`FREEIPA.SVC.CLUSTER.LOCAL`). Slurm's login and compute pods authenticate
against it over LDAPS via SSSD.

Flux brings the components up on its own (FreeIPA, then slurm, by dependency
order). Only the manual actions Flux cannot perform are listed below. The dev
credentials are already committed (plaintext) in the per-cluster `secret.yaml`
files — change them there if desired before deploying.

### Runtime: systemd-in-container needs privileged OR user namespaces

The FreeIPA image runs systemd as PID 1, so it needs cgroup and mount access.
There are two ways to grant that, with very different **host kernel**
requirements — pick based on your host:

**Option A — privileged pod (simplest; DEV ONLY).** Container root ≈ host root.
It starts on any kernel with no extra setup. The catch is SELinux: on an
**SELinux-enforcing host** the container's systemd (with `CAP_SYS_ADMIN`) mounts
selinuxfs and reloads the *image's* SELinux policy into the **shared host
kernel**, unmapping the host's `container_*` types and breaking
docker/containerd host-wide. So on enforcing hosts you MUST set the host to
**SELinux permissive** while FreeIPA runs (`setenforce 0`; the policy swap is
then harmless), or use Option B. On non-SELinux hosts this is a clean no-op.

**Option B — user namespaces (`hostUsers: false`) + non-privileged (more
secure).** This is what `infrastructure/freeipa` ships, and it is **verified
working** on single-node kind: `privileged: false` with **no added capabilities
at all**. A user namespace confines the container so it cannot touch host-global
kernel state (including SELinux). It has a hard **kernel-version floor**:

> ⚠️ **Kernel requirement: host kernel ≥ 6.3.** On older kernels a
> `hostUsers: false` pod fails at *sandbox creation* with
> `error mounting "sysfs" to rootfs at "/sys": operation not permitted`
> — the kernel refuses to mount sysfs inside a user namespace. (Do not go
> looking for a matching `dmesg` line; see the note under accommodation 2.)
>
> **RHEL / Rocky / AlmaLinux 9.x ship kernel 5.14 and freeze it for the whole
> release** (`dnf upgrade` stays on 5.14), so user-namespace pods will **not**
> start there. To use Option B you need kernel ≥ 6.3 — e.g. ELRepo `kernel-ml`
> (unsupported/"as-is"; needs Secure Boot off + DKMS rebuilds), or RHEL/Rocky 10
> (ships 6.12), or any distro on a 6.x kernel.
>
> It also needs containerd ≥ 2.1 with `cgroup_writable = true` and
> `SystemdCgroup = true` (see freeipa/freeipa-container
> `tests/containerd-2.1-config.toml`) so non-privileged systemd can manage its
> cgroup subtree.

#### The two kind accommodations (both implemented)

Under kind, Option B needs two extra things. Both are now implemented in
`bootstrap/kind/` — you do **not** have to do anything by hand — but they are
described here because the failure modes are opaque if either goes missing.

**1. `cgroup_writable` on the node's containerd** — injected by
`containerdConfigPatches` in `bootstrap/kind/kind-config-single.yaml`. Note the
patch deliberately uses the **containerd config version 2** plugin path
(`plugins."io.containerd.grpc.v1.cri"…`), not the version-3 spelling from
upstream's reference file: kind's node image ships `config.toml` at `version = 2`,
and a version-3 patch against it is silently discarded. On
`kindest/node:v1.36.1` the node already ships containerd 2.3.1 with
`SystemdCgroup = true`, so `cgroup_writable` is the only key that actually
changes. Verify:

```sh
docker exec kind-control-plane containerd --version
docker exec kind-control-plane containerd config dump | grep cgroup_writable
```

**2. A fully-visible sysfs on the node** (kind issue
[#3436](https://github.com/kubernetes-sigs/kind/issues/3436), still open) —
`bootstrap/kind/setup.sh` mounts one at `/mnt/sysfs` on every node. kind
bind-mounts `/sys/devices/virtual/dmi/id/product_uuid` and `product_name`
read-only into each node, which leaves the node's sysfs partially covered; the
kernel then refuses runc's sysfs mount inside a user namespace. Without it,
**every** `hostUsers: false` pod — not just FreeIPA — fails at *sandbox
creation*, never starting a container at all:

```
Failed to create pod sandbox: ... runc create failed: unable to start container
process: error during container init: error mounting "sysfs" to rootfs at "/sys":
mount src=sysfs, dst=/sys, ... flags=MS_RDONLY|MS_NOSUID|MS_NODEV|MS_NOEXEC:
operation not permitted
```

Note the fix is to add a *fresh, child-free* sysfs instance at a new path, not to
uncover `/sys` — unmounting the two product-file covers is not sufficient,
because `/sys` still has other submounts beneath it. Do not expect
`VFS: Mount too revealing` in `dmesg`; on kernel 6.12 the userspace error above
appears with no corresponding kernel log line. Verify:

```sh
docker exec kind-control-plane mount | grep sysfs   # expect an entry on /mnt/sysfs
```

#### The kubeadm accommodation (implemented)

Under kubeadm/Kubespray, Option B needs the same `cgroup_writable` setting that
kind gets from `containerdConfigPatches` — but scoped to FreeIPA rather than
applied to every pod on the node. Two pieces, both in git, both applied by
Kubespray and Flux with no manual step:

1. **A second containerd runtime handler**, `runc-cgroupfs`, declared via
   `containerd_extra_args` in
   `bootstrap/kubespray/inventory/group_vars/all/containerd.yml`. It is the only
   handler with `cgroup_writable = true`; the default `runc` handler is left
   alone.
2. **A RuntimeClass of the same name** plus `runtimeClassName: runc-cgroupfs` on
   the FreeIPA StatefulSet, in `infrastructure/freeipa/overlays/kubeadm/`. Only
   FreeIPA references it.

Why scoped and not simply set on the default `runc` handler — two reasons, one
mechanical and one security:

- **Kubespray cannot add the key to the existing `runc` table.** As of v2.31.0
  its containerd template emits only `runtime_type`, `base_runtime_spec` and the
  `options` block per runtime, and `cgroup_writable` is a *runtime-level* key —
  a sibling of `runtime_type`, not an `options` entry.
  `containerd_extra_runtime_args` injects into the CRI plugin section, one level
  too high, and redeclaring the `runc` table would be duplicate TOML and break
  parsing. Declaring a *new* table Kubespray never emits is valid (TOML allows
  defining a super-table after a sub-table).
- **`cgroup_writable` is per-runtime-handler, not per-pod.** Enabling it on the
  default handler gives **every** pod a writable cgroup, which lets an ordinary
  container rewrite its own limits — verified: a 64Mi-limited pod raised its own
  `memory.max` to 512Mi. Scoping it keeps that away from normal workloads.

Unlike kind, a kubeadm node needs **no sysfs workaround** — that one is specific
to kind's product_uuid bind-mounts. A stock Kubespray node's `/sys` is fully
visible, so `hostUsers: false` pods reach sandbox creation fine.

`Delegate=yes` is **not** the missing piece and is already present: both
`containerd.service` and every `cri-containerd-*.scope` carry it. That only tells
host systemd not to interfere with the subtree; it changes neither the read-only
cgroupfs mount inside the container's mount namespace nor the ownership of the
delegation files. Verified: a container that is host root **and** owns
`cgroup.subtree_control` with mode 0644 still fails with `EROFS`, because the
kernel checks the mount's read-only flag before permissions.

The failure mode without this is opaque, so it is worth recognising. containerd
mounts `/sys/fs/cgroup` read-only and never chowns the delegated subtree into the
pod's uid map, so systemd's write to `cgroup.subtree_control` fails, systemd
never reaches `basic.target`, dbus never starts, `ipa-server-install` never runs,
and the readiness probe fails forever with:

```
Failed to connect to bus: No such file or directory
```

The pod sits `0/1 Running` with **zero restarts** and an empty or near-empty log,
which reads like a hang rather than a misconfiguration.

##### What the scoped handler does and does not grant

Measured on Debian 13 and Rocky Linux 10 (containerd 2.2.3, k8s v1.35.4):

| | ordinary pod (default `runc`) | FreeIPA (`runc-cgroupfs` + userns) |
| --------------------------------- | ----------------------------- | ---------------------------------- |
| `/sys/fs/cgroup` mount            | `ro`                          | `rw`                               |
| write `cgroup.subtree_control`    | EROFS                         | **allowed** (what systemd needs)    |
| raise its own `memory.max`        | EROFS                         | **EPERM — withheld**                |
| see host or sibling-pod cgroups   | no                            | **no**                             |

The last two rows are the point. Containers get a **private cgroup namespace**,
so a pod's own cgroup is the root of its view — it cannot name or reach the host
hierarchy or another pod's cgroup. And under a user namespace containerd
performs correct cgroup v2 **delegation containment**: it chowns `cgroup.procs`
and `cgroup.subtree_control` into the pod's uid map but deliberately leaves
`memory.max` outside it. So the FreeIPA pod can manage cgroups beneath itself and
cannot raise even its own limits.

Contrast with the privileged model (Option A), which gets a writable cgroupfs for
free but runs in the **host** cgroup namespace with the host's full `/dev` — it
can see and write the entire host hierarchy.

Note also that capabilities are not a middle ground here: the rw-vs-ro cgroupfs
decision is made from the `privileged` boolean at OCI-spec generation time, so
`privileged: false` with `SYS_ADMIN` (or five more capabilities) still yields a
read-only cgroupfs — verified. And per the note above, adding `SYS_ADMIN`
actively breaks the FreeIPA install.

Verify a node after provisioning:

```sh
containerd --version                                    # need >= 2.1
sudo containerd config dump | grep -E 'cgroup_writable|SystemdCgroup'
#   expect cgroup_writable = false on runc, = true on runc-cgroupfs
kubectl get runtimeclass runc-cgroupfs
kubectl -n freeipa get pod ipa-0 -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl -n freeipa exec ipa-0 -- mount | grep ' /sys/fs/cgroup '   # expect rw
```

If the handler is missing from containerd, pods using the RuntimeClass fail to
start with a clear handler error rather than hanging at `0/1` — a deliberate
improvement over the silent failure above. Requires containerd >= 2.1; older
builds silently ignore `cgroup_writable`.

Verified working 2026-08-10 on single-node kubeadm clusters (Kubespray v2.31.0,
k8s v1.35.4, containerd 2.2.3) on **both** Debian 13 and Rocky Linux 10.

#### Do not add capabilities, and do not set readOnlyRootFilesystem

Two tempting hardening tweaks both break this deployment, so the manifest
deliberately omits them:

- **`capabilities.add: [SYS_ADMIN]`** — the server installs, then the final
  `ipa-client-install` step fails with `KerberosError: No valid Negotiate header
  in server response` (httpd logs `gss_acquire_cred[_from]() failed to get server
  creds … SPNEGO cannot find mechanisms to negotiate`) and the installer rolls
  everything back. Inside the user namespace systemd needs no extra capability;
  granting one lets it apply per-service sandboxing that breaks the `/tmp`-based
  ccache handoff between httpd and gssproxy.
- **`readOnlyRootFilesystem: true`** — upstream sets this, but upstream runs
  under podman, which materialises the image's `VOLUME` declarations. Kubernetes
  ignores them, so the image's init dies at once with `cp: cannot create regular
  file '/etc/hosts.dist': Read-only file system`. The writable `/run`, `/tmp` and
  `/dev/shm` emptyDirs in the manifest cover what those volumes would have.

Either way this is DEV ONLY (see the [README](../README.md) security note).

1. **Extract the FreeIPA CA into the slurm namespace.** Once FreeIPA is healthy
   (`kubectl -n freeipa exec sts/ipa -- ipactl status`; the first install takes
   several minutes), copy its CA into the `freeipa-ca` ConfigMap. SSSD validates
   the LDAPS certificate against this CA (`ldap_tls_reqcert = demand`), and the
   ConfigMap is not a git manifest, so it must be created by hand. It MUST exist
   before the slurm pods start, or the CA volume mount leaves them Pending:

   ```sh
   kubectl -n freeipa exec sts/ipa -- cat /etc/ipa/ca.crt \
     | kubectl -n slurm create configmap freeipa-ca --from-file=ca.crt=/dev/stdin
   ```

2. **Create users and groups in the web UI.** FreeIPA starts empty, so Slurm
   cannot resolve anyone yet. The management console is exposed (DEV ONLY) via
   the `ipa-web` NodePort on **30443**. FreeIPA enforces a referer/host check
   against its FQDN, so browse it by that name rather than the raw node IP — add
   to your client `/etc/hosts`:

   ```
   <node-ip>  ipa.freeipa.svc.cluster.local
   ```

   then open `https://ipa.freeipa.svc.cluster.local:30443/ipa/ui`, log in as
   `admin` (dev password from the FreeIPA secret), and add users/groups under
   **Identity**. Trust the FreeIPA CA (`ca.crt`) to avoid the TLS warning. On
   kind (where NodePorts aren't host-mapped by default) use `kubectl -n freeipa
   port-forward sts/ipa 30443:443` and browse `https://…:30443/ipa/ui` instead.

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->

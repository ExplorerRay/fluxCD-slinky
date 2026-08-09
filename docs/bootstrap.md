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

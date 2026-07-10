# Bootstrap

Create the Kubernetes cluster before installing Flux. Flux should start only
after the target cluster can run normal pods.

## kind

See [bootstrap/kind/README.md](../bootstrap/kind/README.md) for setup instructions.

kind allows you to run Kubernetes clusters in Docker containers, useful for
local development. You can create single-node clusters using the default CNI,
or multi-node clusters with a custom configuration file to simulate multiple
Kubernetes nodes (control-plane and workers).

### Readiness check

After cluster creation, verify it is ready:

```sh
kubectl get nodes
```

### Flux path

Deploy Flux with the following entrypoint:

```yaml
path: ./clusters/kind
```

## kubeadm

See [bootstrap/kubespray/README.md](../bootstrap/kubespray/README.md) for setup instructions.

kubeadm with Kubespray is used to provision Kubernetes clusters on bare metal or
VMs. `clusters/kubeadm` is the Flux entrypoint for the kubeadm-based cluster.
Kubespray provisions the cluster and installs Calico before Flux starts.

Kubespray clusters can range from single-node (with control-plane, etcd, and
worker roles on one machine) to multi-node (with separate control-plane and
worker nodes). Example inventories are provided at
`bootstrap/kubespray/inventory/single.yml` (one schedulable node) and
`bootstrap/kubespray/inventory/multi.yml` (separate control-plane and workers).

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

Deploy Flux with the following entrypoint:

```yaml
path: ./clusters/kubeadm
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

`bootstrap/kind/setup.sh` creates the sparse file and runs `losetup
/dev/loop100` on the host before `kind create cluster`. The loop device and its
backing image are mounted into the kind worker node via `extraMounts` in
`bootstrap/kind/kind-config.yaml`. Re-running `setup.sh` after a reboot
re-attaches the device idempotently.

### Node hostname

After the cluster is up, set the OSD node name in the overlay values to match
the real node hostname:

```sh
kubectl get nodes -o name
```

Edit `infrastructure/rook-ceph/overlays/<cluster>/values.yaml` and replace
`CHANGEME-node-hostname` under `cephClusterSpec.storage.nodes[].name`.

## FreeIPA

The in-cluster FreeIPA identity server (`infrastructure/freeipa`) is a
hand-rolled StatefulSet reachable at `ipa.freeipa.svc.cluster.local` (realm
`FREEIPA.SVC.CLUSTER.LOCAL`). Slurm's login and compute pods authenticate
against it over LDAPS via SSSD.

Flux brings the components up on its own (FreeIPA, then slurm, by dependency
order). Only the manual actions Flux cannot perform are listed below. The dev
credentials are already committed (plaintext) in the per-cluster `secret.yaml`
files — change them there if desired before deploying.

### Runtime: privileged pod (dev only)

The FreeIPA image runs systemd as PID 1, so it needs cgroup and mount access. To
keep this simple, the StatefulSet runs as a **privileged pod**. This works on
any node that already runs `slurmd` — no user namespaces, no
`UserNamespacesSupport` feature gate, and no special containerd
cgroup-delegation config. There is **nothing extra to set up** here.

The trade-off is reduced isolation (container root ≈ host root), which is why
this is DEV ONLY (see the [README](../README.md) security note). The more secure
upstream alternative — `hostUsers: false` (user namespaces) + a read-only root
filesystem — avoids privileged but requires a recent containerd configured to
delegate the cgroup hierarchy into the user namespace (see
freeipa/freeipa-container `tests/containerd-2.1-config.toml`). Switch to that
model for production.

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

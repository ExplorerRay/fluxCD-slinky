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

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->

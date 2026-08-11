# Kubespray Bootstrap

Operational runbook for provisioning and managing the Kubernetes cluster. For rationale and architecture, see `docs/bootstrap.md`.

## Prerequisites

- [Kubespray](https://github.com/kubernetes-sigs/kubespray) cloned to `$KUBESPRAY_DIR` (default: `/opt/kubespray`)
- Ansible installed: `pip install -r $KUBESPRAY_DIR/requirements.txt`
- SSH access to all nodes in your chosen inventory file

## Before Running

Two example inventories are provided under `bootstrap/kubespray/inventory/`:
`single.yml` and `multi.yml`. Pick one and populate it with actual node IPs and
hostnames. `run.sh` uses `single.yml` by default; select another with the
`INVENTORY_HOSTS` env var (e.g. `INVENTORY_HOSTS=multi.yml`).

### Single-node cluster — `single.yml`

For a minimal deployment with one node handling control-plane, etcd, and worker
roles. Because the node is also in `kube_node`, Kubespray leaves it schedulable
(no control-plane NoSchedule taint), so all workloads run on it:

```yaml
all:
  hosts:
    node1:
      ansible_host: localhost
  children:
    kube_control_plane:
      hosts: {node1:}
    kube_node:
      hosts: {node1:}
    etcd:
      hosts: {node1:}
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
```

### Multi-node cluster — `multi.yml`

For a distributed deployment with separate control-plane and worker nodes. The provided `multi.yml` has node1 as the control-plane + etcd and node2, node3 as workers:

```yaml
all:
  hosts:
    node1:
      ansible_host: 192.168.0.1
    node2:
      ansible_host: 192.168.0.2
    node3:
      ansible_host: 192.168.0.3
  children:
    kube_control_plane:
      hosts: {node1:}
    kube_node:
      hosts: {node2:, node3:}
    etcd:
      hosts: {node1:}
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
```

## Initial Cluster Setup

```bash
bash bootstrap/kubespray/run.sh cluster
```

This provisions the kubeadm cluster and installs Calico CNI.

## User namespaces for FreeIPA (no manual step)

The non-privileged, user-namespaced FreeIPA StatefulSet needs containerd >= 2.1
with `cgroup_writable = true`. Rather than enabling it on the default `runc`
handler — which would give **every** pod a writable cgroup and let an ordinary
container rewrite its own limits — a dedicated `runc-cgroupfs` handler is
declared in `inventory/group_vars/all/containerd.yml` via
`containerd_extra_args`, and only FreeIPA selects it through a RuntimeClass
(`infrastructure/freeipa/overlays/kubeadm/`).

`run.sh cluster` applies it; there is nothing extra to run. Verify:

```bash
sudo containerd config dump | grep -E 'cgroup_writable|SystemdCgroup'
#   expect cgroup_writable = false on runc, = true on runc-cgroupfs
```

Skip nothing — the handler is harmless if FreeIPA is not deployed. Details and
the failure mode are in the
[bootstrap guide](../../docs/bootstrap.md#the-kubeadm-accommodation-implemented).

## Deploy Flux

Follow the [deploy procedure](../../README.md#deploy-procedure) in the root README using `clusters/kubeadm-single` or `clusters/kubeadm-multi` as the path, matching the inventory you provisioned:

- `inventory/single.yml` → Flux path `./clusters/kubeadm-single` (OSD host: `node1`)
- `inventory/multi.yml` → Flux path `./clusters/kubeadm-multi` (OSD host: `node2`)

Whichever host is the OSD host for your variant, install the `rook-osd-loop`
systemd unit (`bootstrap/rook-ceph/`) on it — see the [Rook-Ceph loop device
preparation](../../docs/bootstrap.md#rook-ceph-loop-device-preparation)
section of the bootstrap guide.

## Kubernetes Upgrades

1. Edit kube_version in `inventory/group_vars/k8s_cluster/k8s-cluster.yml`
2. Run the upgrade:

```bash
bash bootstrap/kubespray/run.sh upgrade
```

**Note:** Do NOT add Calico to FluxCD—Kubespray manages it during upgrades to avoid dual-management conflicts.

## Teardown

This is a real cluster. Teardown is infrastructure-dependent and must be performed manually through your cloud provider or physical infrastructure management tools.

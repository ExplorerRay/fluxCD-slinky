# Kubespray Bootstrap

Operational runbook for provisioning and managing the Kubernetes cluster. For rationale and architecture, see `docs/bootstrap.md`.

## Prerequisites

- [Kubespray](https://github.com/kubernetes-sigs/kubespray) cloned to `$KUBESPRAY_DIR` (default: `/opt/kubespray`)
- Ansible installed: `pip install -r $KUBESPRAY_DIR/requirements.txt`
- SSH access to all nodes in `inventory/hosts.yml`

## Before Running

Edit `bootstrap/kubespray/inventory/hosts.yml` and populate with actual node IPs and hostnames.

### Single-node cluster

For a minimal deployment with one node handling control-plane, etcd, and worker roles:

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

### Multi-node cluster

For a distributed deployment with separate control-plane and worker nodes. The provided `bootstrap/kubespray/inventory/hosts.yml` includes this topology with node1 as the control-plane and node2, node3 as workers:

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

## Deploy Flux

Follow the [deploy procedure](../../README.md#deploy-procedure) in the root README using `clusters/kubeadm` as the path.

## Kubernetes Upgrades

1. Edit kube_version in `inventory/group_vars/k8s_cluster/k8s-cluster.yml`
2. Run the upgrade:

```bash
bash bootstrap/kubespray/run.sh upgrade
```

**Note:** Do NOT add Calico to FluxCD—Kubespray manages it during upgrades to avoid dual-management conflicts.

## Teardown

This is a real cluster. Teardown is infrastructure-dependent and must be performed manually through your cloud provider or physical infrastructure management tools.

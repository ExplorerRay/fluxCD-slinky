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
worker nodes). An example inventory in YAML format is provided at
`bootstrap/kubespray/inventory/hosts.yaml`.

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

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->

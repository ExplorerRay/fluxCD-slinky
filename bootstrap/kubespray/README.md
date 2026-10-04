# Kubespray Bootstrap

Operational runbook for provisioning and managing the Kubernetes cluster. For rationale and architecture, see `docs/bootstrap.md`.

## Prerequisites

- [Kubespray](https://github.com/kubernetes-sigs/kubespray) cloned to
  `$KUBESPRAY_DIR` (default: `/opt/kubespray`) at a released tag — this repo
  is verified against `v2.31.0`; other versions may work but are untested:

  ```bash
  git clone --branch v2.31.0 --depth 1 \
    https://github.com/kubernetes-sigs/kubespray.git /opt/kubespray
  ```
- Ansible installed: `pip install -r $KUBESPRAY_DIR/requirements.txt`
- On RHEL-family nodes (Rocky/AlmaLinux/RHEL), the cloud image omits the
  `kernel-modules-extra` RPM, which leaves `ip_set.ko`/`xt_set.ko` missing
  and kube-proxy/Calico failing partway through the playbook. Before
  running the cluster playbook:

  ```bash
  sudo dnf install -y kernel-modules-extra-$(uname -r)
  sudo modprobe ip_set xt_set
  ```

  See [troubleshooting](../../docs/troubleshooting.md) for the failure
  mode if this is skipped.
- SSH access to all nodes in your chosen inventory file
- **At least 20 GiB of RAM** on the `kubeadm-single` node
  — see [Resource requirements](#resource-requirements).

## Resource requirements

Kubernetes schedules on memory *requests* — not on actual usage and not on
limits. The sum of the requests of every pod on a node must fit the node's
*allocatable* memory, which is its RAM minus what the kubelet reserves
(about 1.3 GiB less on a 20 GiB node: 19562512Ki ≈ 18.66 GiB allocatable).
On `kubeadm-multi` the same rule applies per node, and DaemonSet pods
(`csi-cephfsplugin`, `csi-rbdplugin`, …) count on every node.

Pod memory requests for `kubeadm-single`, dominated by Rook-Ceph, total
**13554 Mi (13.2 GiB)**:

| namespace     | requests   |
| ------------- | ---------- |
| `rook-ceph`   | 10850 Mi   |
| `freeipa`     | 2048 Mi    |
| `flux-system` | 384 Mi     |
| `kube-system` | 272 Mi     |
| **total**     | **13554 Mi** |

These were measured on a 20 GiB node with 1Gi MDS requests (`rook-ceph`
12386 Mi, total 15090 Mi) and reduced by the 1536 Mi that lowering them to
256Mi frees; the lowered figures have not been re-measured.

The heavyweights, as configured in
`infrastructure/rook-ceph/overlays/kubeadm/values.yaml` (Rook adds a 100 Mi
log-collector sidecar to the osd, mon, mgr and mds pods, included here):
`rook-ceph-osd-0` at 4196 Mi (request = `osd_memory_target` 4Gi), `ipa-0` at
2048 Mi, `rook-ceph-mon-a` and `rook-ceph-mgr-a` at 1124 Mi each, the two
`csi-*-provisioner` pods at 1024 Mi each, and the `csi-*plugin` DaemonSets at
640 Mi per node. The two CephFS MDS pods request only 356 Mi each. These
requests are sized for this dev, single-OSD cluster's idle footprint; the
limits are higher (OSD 8Gi, mon 4Gi, mds 2Gi) and keep the burst headroom.

On a 20 GiB node that leaves **5550 Mi (5.4 GiB)** of allocatable unrequested.
Slurm, MariaDB, cert-manager and the Slinky operator set **no** requests, so
the scheduler does not account for them at all — that headroom is all they
get, and it is why 20 GiB rather than "just above the
total" is the recommendation. Actual usage is far lower than the requests:
an idle node sits around 6–8 GiB used (OSD ~1.7 GiB, mgr ~0.7 GiB, mon
~0.5 GiB, each MDS ~30 MiB). No `kubeadm-multi` measurement exists yet; size
each node for the requests that land on it.

Check how full a node is:

```bash
kubectl describe node <node> | grep -A6 'Allocated resources'
```

### What too little memory looks like

Observed on a 20 GiB `kubeadm-single` node before the requests were lowered,
when they totaled 20210 Mi against 18.66 GiB allocatable: the standby MDS did
not fit and, then running at `system-cluster-critical` priority, **preempted**
`ipa-0` (event `Preempted by pod … on node node1`). `ipa-0` then stayed
`Pending` (`No preemption victims found`), the `freeipa` Kustomization never
became Ready, and `slurm` sat blocked on `dependency 'flux-system/freeipa' is
not ready`. The MDS no longer has that priority class, so today an
over-full node leaves the *last* pod `Pending` with `Insufficient memory`
instead — usually `ipa-0` or a Ceph daemon. Nodes report
`MemoryPressure: False` throughout; it is a scheduling failure, not OOM.
See [troubleshooting](../../docs/troubleshooting.md#ipa-0-stuck-pending-events-mention-insufficient-memory).

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

`ansible_host: localhost` is a named host, not Ansible's implicit
`localhost`, so Ansible reaches it over SSH like any other target. When you
run the playbook from `node1` itself — the usual single-node case — that
means the host must be able to SSH to *itself*, and nothing else in this
inventory implies it. Before running the playbook, make sure you have a
keypair and that it is authorized for your own account:

```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
grep -qxFf ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys 2>/dev/null \
  || cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
ssh <user>@<ansible_host> true   # must succeed with no prompt
```

The same applies to any node you drive from itself, including `node1` in
`multi.yml` below.

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
sudo /usr/local/bin/containerd config dump | grep -E 'cgroup_writable|SystemdCgroup'
#   expect cgroup_writable = false on runc, = true on runc-cgroupfs
```

Skip nothing — the handler is harmless if FreeIPA is not deployed. Details and
the failure mode are in the
[runtime requirements](../../docs/runtime-requirements.md#kubeadm).

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

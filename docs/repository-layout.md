# Repository Layout

Cluster entrypoints live under `clusters/`, one directory per variant — a
single-node and a multi-node flavor of each platform:

```text
clusters/
  kind-single/
  kind-multi/
  kubeadm-single/
  kubeadm-multi/
```

Shared component resources and Helm values live in `base` directories.
Overlays hold only what really differs per platform:

```text
applications/slurm/
  base/
  overlays/
    kind/
    kubeadm/
```

Flux cluster entrypoints should point to overlays, not directly to base
directories. For example:

```yaml
path: ./applications/slurm/overlays/kind
```

Use this rule:

- Put identical resources and values in `base`, including a component's
  Helm `values.yaml`.
- Put only real platform differences in `overlays/kind` or
  `overlays/kubeadm`. An overlay with none just includes `../../base`.

This keeps common behavior in one place while allowing one cluster to add
resources that the other cluster does not need. `overlays/kind` and
`overlays/kubeadm` are shared by *both* variants (single and multi) of that
platform — the single-node and multi-node entrypoints for a platform point at
the same overlay for every component except one.

The exception is `rook-ceph`. Its OSD node placement
(`cephClusterSpec.storage.nodes`) differs per variant, so each variant gets
its own overlay layered on top of the shared one:

```text
infrastructure/rook-ceph/
  base/                 # values.yaml shared by every variant
  overlays/
    kind/               # platform-values.yaml (mgr/mon/OSD sizing), mapOptions
    kubeadm/            # platform-values.yaml (mgr/mon/OSD sizing)
    kind-single/        # resources: [../kind]    + node-values.yaml
    kind-multi/         # resources: [../kind]    + node-values.yaml
    kubeadm-single/     # resources: [../kubeadm] + node-values.yaml
    kubeadm-multi/      # resources: [../kubeadm] + node-values.yaml
```

Each variant overlay's `node-values.yaml` supplies just the OSD node name
(`kind-control-plane`, `kind-worker`, `node1`, or `node2`).
`base/helmrelease-cluster.yaml` merges the three in order — `values.yaml`,
then `platform-values.yaml`, then `node-values.yaml` — so the per-variant
hostname is layered on top of the platform and shared values. The cluster
entrypoints in `clusters/` point the `rook-ceph` Kustomization at the matching
variant overlay, while every other component's Kustomization still points at
the shared `overlays/kind` or `overlays/kubeadm`.

## Bootstrap Directory

The `bootstrap/` directory contains one-time cluster provisioning scripts and
configuration. These scripts are run once before FluxCD takes over cluster
management and are **not** managed by FluxCD:

```text
bootstrap/
  kind/
    kind-config-single.yaml  # single control-plane node (also hosts the OSD)
    kind-config-multi.yaml   # control-plane + 2 workers (one hosts the OSD)
    setup.sh                 # creates the kind cluster for a variant
    README.md
  kubespray/
    inventory/
      single.yml          # single schedulable node
      multi.yml           # separate control-plane and workers
      group_vars/
        all/
        k8s_cluster/
    run.sh              # wraps ansible-playbook
    README.md
```

Once bootstrap completes and the cluster is operational, FluxCD assumes
control of all workload management through the cluster entrypoints in
`clusters/`. For example, the Calico CNI is installed by Kubespray during
bootstrap and is intentionally not added to FluxCD to avoid dual-management
conflicts during Kubernetes upgrades.

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->

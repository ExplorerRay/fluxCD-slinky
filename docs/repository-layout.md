# Repository Layout

Cluster entrypoints live under `clusters/`:

```text
clusters/
  kind/
  kubeadm/
```

Shared component resources live in `base` directories. Cluster-specific
resources and values live in overlays:

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

- Put identical resources in `base`.
- Put cluster-specific values or extra resources in `overlays/kind` or
  `overlays/kubeadm`.

This keeps common behavior shared while allowing one cluster to add resources
that the other cluster does not need.

## Bootstrap Directory

The `bootstrap/` directory contains one-time cluster provisioning scripts and
configuration. These scripts are run once before FluxCD takes over cluster
management and are **not** managed by FluxCD:

```text
bootstrap/
  kind/
    kind-config.yaml    # kind cluster configuration
    setup.sh            # creates kind cluster and bootstraps Flux
    README.md
  kubespray/
    inventory/
      hosts.yaml
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

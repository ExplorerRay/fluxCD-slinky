# fluxCD-slinky
Custom IaC project for slinky-related projects

## ⚠️ Development only — not production ready

This is a proof-of-concept. Some secrets are committed to git **in plaintext**
for convenience, including the FreeIPA admin / Directory Manager password and
the SSSD bind password (`infrastructure/freeipa/overlays/*/secret.yaml` and
`applications/slurm/overlays/*/secret.yaml`). The FreeIPA server runs as a
**privileged pod** (simplest way to run systemd-in-container), but inside a
**user namespace** (`hostUsers: false`) so those capabilities cannot mutate
host-global kernel state — without it, the container's systemd reloads its own
SELinux policy into the shared host kernel and breaks docker/containerd on
SELinux (RHEL-family) hosts. The storage layer is likewise dev-grade
(single-node Ceph on a loopback file, no replication).

**Do not deploy this as-is anywhere real.** Before any production use, at
minimum: move secrets out of git (e.g. SOPS/age or sealed-secrets), rotate all
credentials, tighten FreeIPA further (drop privileged in favour of an explicit
capability set + read-only rootfs), and back storage with real disks and
replication.

## Cluster model

This repository manages more than one Kubernetes cluster with Flux, each with
a single-node and a multi-node variant:

- `clusters/kind-single` — local kind cluster entrypoint, single control-plane
  node.
- `clusters/kind-multi` — local kind cluster entrypoint, control-plane + 2
  workers.
- `clusters/kubeadm-single` — kubeadm/kubespray cluster entrypoint, single
  schedulable node.
- `clusters/kubeadm-multi` — kubeadm/kubespray cluster entrypoint, separate
  control-plane and workers.
- `base` directories contain shared resources.
- `overlays/kind` and `overlays/kubeadm` contain cluster-specific resources and
  values, shared by both variants of that platform (single and multi) — this
  rule still holds. The one exception is `rook-ceph`, which has per-variant
  overlays (`overlays/kind-single`, `overlays/kind-multi`,
  `overlays/kubeadm-single`, `overlays/kubeadm-multi`) layered on top of the
  shared overlay to bake in the deterministic OSD node hostname for each
  variant.

See:

- [Stack overview](docs/stack-overview.md)
- [Bootstrap guide](docs/bootstrap.md)
- [Repository layout](docs/repository-layout.md)

## Deploy Procedure

1. Provision a Kubernetes cluster — see the [bootstrap guide](docs/bootstrap.md) for kind or kubeadm setup.
2. `cd clusters/<cluster_name>/flux-system/`
3. Create `gotk-components.yaml`
   - With Flux CLI: `flux install --export > gotk-components.yaml`
   - Without Flux CLI: `curl -sL https://github.com/fluxcd/flux2/releases/latest/download/install.yaml > gotk-components.yaml`
4. Create `gotk-sync.yaml`

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  url: https://github.com/ExplorerRay/fluxCD-slinky.git
  ref:
    branch: main
  interval: 1m0s
  timeout: 60s
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./clusters/<cluster_name>
  force: false
  prune: true
  interval: 10m0s
```

`<cluster_name>` is one of `kind-single`, `kind-multi`, `kubeadm-single`, or
`kubeadm-multi`. The repository is public, so Flux fetches it anonymously — no
GitHub PAT or `flux-system` secret is needed.

5. `git commit`
6. `kubectl apply -f gotk-components.yaml` and wait for the components to be ready (this also creates the `flux-system` namespace)
7. `kubectl apply -f gotk-sync.yaml` and wait for the Kustomization to be ready

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->

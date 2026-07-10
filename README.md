# fluxCD-slinky
Custom IaC project for slinky-related projects

## ⚠️ Development only — not production ready

This is a proof-of-concept. Some secrets are committed to git **in plaintext**
for convenience, including the FreeIPA admin / Directory Manager password and
the SSSD bind password (`infrastructure/freeipa/overlays/*/secret.yaml` and
`applications/slurm/overlays/*/secret.yaml`). The FreeIPA server runs as a
**privileged pod** (simplest way to run systemd-in-container). The storage layer
is likewise dev-grade (single-node Ceph on a loopback file, no replication).

**Do not deploy this as-is anywhere real.** Before any production use, at
minimum: move secrets out of git (e.g. SOPS/age or sealed-secrets), rotate all
credentials, run FreeIPA unprivileged (user namespaces + read-only rootfs), and
back storage with real disks and replication.

## Cluster model

This repository manages more than one Kubernetes cluster with Flux:

- `clusters/kind` is the local kind cluster entrypoint.
- `clusters/kubeadm` is the Flux-managed cluster entrypoint.
- `base` directories contain shared resources.
- `overlays/kind` and `overlays/kubeadm` contain cluster-specific resources and
  values.

See:

- [Stack overview](docs/stack-overview.md)
- [Bootstrap guide](docs/bootstrap.md)
- [Repository layout](docs/repository-layout.md)

## Deploy Procedure

1. Provision a Kubernetes cluster — see the [bootstrap guide](docs/bootstrap.md) for kind or kubeadm setup.
2. Create a Personal Access Token in GitHub following [this guide](https://fluxcd.io/flux/installation/bootstrap/github/#github-pat)
3. `kubectl create namespace flux-system`
4. `kubectl -n flux-system create secret generic flux-system --from-literal=username=<github_username> --from-literal=password=<personal_access_token>`
5. `cd clusters/<cluster_name>/flux-system/`
6. Create `gotk-components.yaml`
   - With Flux CLI: `flux install --export > gotk-components.yaml`
   - Without Flux CLI: `curl -sL https://github.com/fluxcd/flux2/releases/latest/download/install.yaml > gotk-components.yaml`
7. Create `gotk-sync.yaml`

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
  secretRef:
    name: flux-system
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

8. `git commit`
9. `kubectl apply -f gotk-components.yaml` and wait for the components to be ready
10. `kubectl apply -f gotk-sync.yaml` and wait for the Kustomization to be ready

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->

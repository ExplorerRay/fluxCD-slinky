# fluxCD-slinky
Custom IaC project for slinky-related projects

## ⚠️ Development only — not production ready

This is a proof-of-concept. Some secrets are committed to git **in plaintext**
for convenience, including the FreeIPA admin / Directory Manager password and
the SSSD bind password (`infrastructure/freeipa/overlays/*/secret.yaml` and
`applications/slurm/overlays/*/secret.yaml`). The FreeIPA server runs
systemd-in-container, which needs either a **privileged pod** (simplest — but on
SELinux-enforcing hosts its systemd reloads the image's SELinux policy into the
shared host kernel and breaks docker/containerd unless the host is set to
SELinux permissive) or a **user namespace** (`hostUsers: false`, more secure).
The user-namespace model **requires host kernel ≥ 6.3** — RHEL/Rocky/AlmaLinux
9.x ship a frozen 5.14 kernel that is too old, and userns pods fail to start on
it. See the [runtime requirements](docs/runtime-requirements.md) for the full
trade-offs and kernel requirement. The storage layer is likewise dev-grade
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

- [Stack overview](docs/stack-overview.md) — components, Flux dependency
  order, and the identity architecture (who runs SSSD and why).
- [Bootstrap guide](docs/bootstrap.md) — the procedure for standing up a
  cluster and Flux, in order.
- [Repository layout](docs/repository-layout.md)
- [Runtime requirements](docs/runtime-requirements.md) — read before
  deploying on kubeadm/bare metal: container-runtime and host-kernel
  prerequisites for FreeIPA's systemd-in-container.
- [Verification](docs/verification.md) — read after deploying: proves the
  cluster and identity stack actually work, not just that Flux is Ready.
- [Troubleshooting](docs/troubleshooting.md) — read when something's wrong:
  a symptom-keyed index of observed failures.

## Deploy Procedure

1. Provision a Kubernetes cluster — see the [bootstrap guide](docs/bootstrap.md) for kind or kubeadm setup.
2. `cd clusters/<cluster_name>/flux-system/`

`<cluster_name>` is one of `kind-single`, `kind-multi`, `kubeadm-single`, or
`kubeadm-multi`. The repository is public, so Flux fetches it anonymously — no
GitHub PAT or `flux-system` secret is needed.

`gotk-components.yaml` and `gotk-sync.yaml` already ship in each
`flux-system/` directory, pinned to a tested Flux version and pointing at
this repository, so the normal path is just to apply them:

3. `kubectl apply -f gotk-components.yaml` and wait for the components to be ready (this also creates the `flux-system` namespace)
4. `kubectl apply -f gotk-sync.yaml` and wait for the Kustomization to be ready

### Creating a new cluster entrypoint

The steps below are only for a *new* `<cluster_name>` that doesn't already
have a `flux-system/` directory — not for the four existing ones above, where
regenerating these files risks overwriting the pinned, working Flux version
with an untested newer one.

1. Create `gotk-components.yaml`
   - With Flux CLI: `flux install --export > gotk-components.yaml`
   - Without Flux CLI: `curl -sL https://github.com/fluxcd/flux2/releases/latest/download/install.yaml > gotk-components.yaml`
2. Create `gotk-sync.yaml`

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

3. `git commit` **and push** the new `flux-system/` directory to the branch
   the `GitRepository` above tracks. Flux clones that branch from the remote,
   not your working copy, so an unpushed commit is invisible to it and the
   Kustomization will fail to find `./clusters/<cluster_name>`. If you cannot
   push to this repository, fork it and point `spec.url` at your fork.
4. `kubectl apply -f gotk-components.yaml` and wait for the components to be ready (this also creates the `flux-system` namespace)
5. `kubectl apply -f gotk-sync.yaml` and wait for the Kustomization to be ready

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->

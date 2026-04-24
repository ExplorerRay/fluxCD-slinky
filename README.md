# fluxCD-slinky
Custom IaC project for slinky-related projects

## Deploy Procedure

1. Create a Personal Access Token in Github following [this guide](https://fluxcd.io/flux/installation/bootstrap/github/#github-pat)
2. `kubectl create namespace flux-system`
3. `kubectl -n flux-system create secret generic flux-system --from-literal=password=<personal_access_token>`
4. `cd clusters/<cluster_name>/flux-system/`
5. Create `gotk-components.yaml`
   - With Flux CLI: `flux install --export > gotk-components.yaml`
   - Without Flux CLI: `curl -sL https://github.com/fluxcd/flux2/releases/latest/download/install.yaml > gotk-components.yaml`
6. Create `gotk-sync.yaml`

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

7. `git commit`
8. `kubectl apply -f gotk-components.yaml` and wait for the components to be ready
9. `kubectl apply -f gotk-sync.yaml` and wait for the Kustomization to be ready

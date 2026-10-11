#!/usr/bin/env bash
# Deploy clusters/kind-ci onto a fresh kind-single cluster
# (bootstrap/kind/setup.sh single), then do the two bootstrap steps Flux
# cannot (docs/bootstrap.md, FreeIPA): the freeipa-ca ConfigMap and a test
# user in a POSIX group. Used by .github/workflows/e2e.yaml; followed by
# tests/e2e/checks.sh.
#
# Flux clones REPO_URL at REVISION — not this working copy — so the commit
# must be pushed. Idempotent: safe to re-run against a partly deployed cluster.
#
# Environment (defaults in brackets):
#   REPO_URL      repository Flux clones   [origin remote, as https]
#   REPO_BRANCH   branch containing REVISION [current branch]
#   REVISION      commit SHA to deploy       [HEAD]
#   E2E_USER / E2E_GROUP / E2E_PASSWORD  test identity, shared with checks.sh
#                 [e2euser / e2eteam / E2e-dev-only-1]

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_URL="${REPO_URL:-$(git -C "$REPO_ROOT" remote get-url origin)}"
REPO_BRANCH="${REPO_BRANCH:-$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)}"
REVISION="${REVISION:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
E2E_USER="${E2E_USER:-e2euser}"
E2E_GROUP="${E2E_GROUP:-e2eteam}"
E2E_PASSWORD="${E2E_PASSWORD:-E2e-dev-only-1}"

if [[ "$REPO_BRANCH" == HEAD ]]; then
  echo "ERROR: cannot infer the branch from a detached HEAD; set REPO_BRANCH" >&2
  exit 1
fi

# Flux clones anonymously; an ssh remote would need a deploy key.
case "$REPO_URL" in
  git@github.com:*) REPO_URL="https://github.com/${REPO_URL#git@github.com:}" ;;
esac

log() { echo "==> $*"; }

# retry <seconds> <command...>: run until it succeeds or the deadline passes.
retry() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    if ((SECONDS >= deadline)); then
      echo "ERROR: timed out waiting for: $*" >&2
      return 1
    fi
    sleep 10
  done
}

wait_ks() {
  log "waiting for Kustomization $1 (timeout $2)"
  kubectl -n flux-system wait "kustomization/$1" --for=condition=Ready --timeout="$2"
}

log "deploying $REPO_URL $REPO_BRANCH@$REVISION (clusters/kind-ci)"

log "installing Flux (kind-single's pinned components)"
kubectl apply --server-side -f "$REPO_ROOT/clusters/kind-single/flux-system/gotk-components.yaml"
kubectl wait crd/gitrepositories.source.toolkit.fluxcd.io \
  crd/kustomizations.kustomize.toolkit.fluxcd.io --for=condition=Established --timeout=2m
kubectl -n flux-system wait deployment --all --for=condition=Available --timeout=5m

log "pointing Flux at the commit under test"
kubectl apply -f - <<EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  url: "${REPO_URL}"
  ref:
    branch: "${REPO_BRANCH}"
    commit: "${REVISION}"
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
  path: ./clusters/kind-ci
  prune: true
  interval: 10m0s
EOF

# Create the namespace up front so the freeipa-ca ConfigMap below has somewhere
# to go regardless of Kustomization timing. Flux adopts the namespace. Slurm
# pods that start before the ConfigMap exists retry the mount and recover once
# it is created.
kubectl create namespace slurm --dry-run=client -o yaml | kubectl apply -f -

# Dependency order (clusters/kind-ci). Timeouts follow measured installs:
# Ceph and FreeIPA (~9 min first install) dominate.
wait_ks flux-system 5m
wait_ks flux-cluster-repositories 5m
wait_ks cert-manager 10m
wait_ks rook-ceph 25m
wait_ks mariadb-operator 10m
wait_ks freeipa 25m

log "waiting for every FreeIPA service to report RUNNING"
retry 900 kubectl -n freeipa exec ipa-0 -- ipactl status

log "copying the FreeIPA CA into slurm/freeipa-ca"
kubectl -n freeipa exec ipa-0 -- cat /etc/ipa/ca.crt |
  kubectl -n slurm create configmap freeipa-ca --from-file=ca.crt=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -

log "creating FreeIPA user $E2E_USER in POSIX group $E2E_GROUP"
admin_password="$(kubectl -n freeipa get secret freeipa-admin -o jsonpath='{.data.password}' | base64 -d)"
# Script on stdin so the passwords stay out of process arguments.
kubectl -n freeipa exec -i ipa-0 -- bash -s <<EOF
set -euo pipefail
echo '${admin_password}' | kinit admin >/dev/null
# ipa reads stdin by default; keep it off the script feeding this shell.
if ! ipa user-show '${E2E_USER}' </dev/null >/dev/null 2>&1; then
  ipa user-add '${E2E_USER}' --first=E2E --last=User --shell=/bin/bash </dev/null >/dev/null
fi
# Unconditional so a re-run, or a run interrupted after user-add, always ends
# with a usable password equal to E2E_PASSWORD.
printf '%s\n%s\n' '${E2E_PASSWORD}' '${E2E_PASSWORD}' | ipa passwd '${E2E_USER}' >/dev/null
# ipa passwd leaves the password expired; push expiry out so
# non-interactive ssh does not hit a forced password change.
ipa user-mod '${E2E_USER}' --setattr=krbpasswordexpiration=20301231000000Z </dev/null >/dev/null
ipa group-show '${E2E_GROUP}' </dev/null >/dev/null 2>&1 || ipa group-add '${E2E_GROUP}' </dev/null >/dev/null
# Exits non-zero when already a member; the membership check below decides.
ipa group-add-member '${E2E_GROUP}' --users='${E2E_USER}' </dev/null >/dev/null 2>&1 || true
ipa group-show '${E2E_GROUP}' </dev/null | grep -q "Member users:.*\b${E2E_USER}\b"
EOF

wait_ks slurm-operator 10m
wait_ks slurm-database 15m
wait_ks slurm 10m

# The slurm Kustomization does not wait for its workloads; do it here.
log "waiting for the Slurm pods"
slurm_pods_exist() {
  [[ -n "$(kubectl -n slurm get pod -l app.kubernetes.io/component=login -o name)" ]] &&
    [[ -n "$(kubectl -n slurm get pod -l app.kubernetes.io/component=worker -o name)" ]]
}
log "waiting for the slurm HelmRelease to be Ready"
kubectl -n slurm wait helmrelease/slurm --for=condition=Ready --timeout=10m
retry 600 slurm_pods_exist
kubectl -n slurm wait pod -l app.kubernetes.io/part-of=slurm --for=condition=Ready --timeout=15m

log "waiting for a Slurm node to be idle"
slurm_node_idle() {
  kubectl -n slurm exec deploy/slurm-login-slinky -c login -- sinfo -h -o '%t' | grep -qx idle
}
retry 300 slurm_node_idle

log "deploy complete"

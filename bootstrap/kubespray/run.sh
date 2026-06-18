#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
INVENTORY="$REPO_ROOT/bootstrap/kubespray/inventory"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-/opt/kubespray}"

ACTION="${1:-cluster}"

case "$ACTION" in
  cluster)
    ansible-playbook -i "$INVENTORY/hosts.yml" "$KUBESPRAY_DIR/cluster.yml" -b
    ;;
  upgrade)
    ansible-playbook -i "$INVENTORY/hosts.yml" "$KUBESPRAY_DIR/upgrade-cluster.yml" -b
    ;;
  *)
    echo "Usage: $0 [cluster|upgrade]"
    exit 1
    ;;
esac

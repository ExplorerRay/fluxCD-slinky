#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
INVENTORY="$REPO_ROOT/bootstrap/kubespray/inventory"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-/opt/kubespray}"

# Inventory topology: single.yml (one schedulable node) or multi.yml.
INVENTORY_HOSTS="${INVENTORY_HOSTS:-single.yml}"
HOSTS="$INVENTORY/$INVENTORY_HOSTS"

ACTION="${1:-cluster}"

echo "Using inventory: $HOSTS"

case "$ACTION" in
  cluster)
    ansible-playbook -i "$HOSTS" "$KUBESPRAY_DIR/cluster.yml" -b
    ;;
  upgrade)
    ansible-playbook -i "$HOSTS" "$KUBESPRAY_DIR/upgrade-cluster.yml" -b
    ;;
  *)
    echo "Usage: $0 [cluster|upgrade]"
    exit 1
    ;;
esac

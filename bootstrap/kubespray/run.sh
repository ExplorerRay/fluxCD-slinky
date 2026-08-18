#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
INVENTORY="$REPO_ROOT/bootstrap/kubespray/inventory"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-/opt/kubespray}"

if [ ! -f "$KUBESPRAY_DIR/cluster.yml" ]; then
  echo "No kubespray checkout at \$KUBESPRAY_DIR ($KUBESPRAY_DIR):" \
       "cluster.yml not found. See bootstrap/kubespray/README.md." >&2
  exit 1
fi

# Inventory topology: single.yml (one schedulable node) or multi.yml.
INVENTORY_HOSTS="${INVENTORY_HOSTS:-single.yml}"
HOSTS="$INVENTORY/$INVENTORY_HOSTS"

ACTION="${1:-cluster}"

echo "Using inventory: $HOSTS"

# Run from $KUBESPRAY_DIR, the way kubespray's own docs do. Ansible auto-loads
# an ansible.cfg only from the current directory, and kubespray's sets
# roles_path and library to paths relative to itself -- so from anywhere else
# that config never loads and the first play dies with "the role
# 'dynamic_groups' was not found". $HOSTS is absolute, so the inventory still
# resolves from here.
cd "$KUBESPRAY_DIR"

case "$ACTION" in
  cluster)
    ansible-playbook -i "$HOSTS" cluster.yml -b
    ;;
  upgrade)
    ansible-playbook -i "$HOSTS" upgrade-cluster.yml -b
    ;;
  *)
    echo "Usage: $0 [cluster|upgrade]"
    exit 1
    ;;
esac

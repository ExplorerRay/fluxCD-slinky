#!/usr/bin/env bash
set -euo pipefail

VARIANT="${1:-multi}"
case "$VARIANT" in
  single|multi) ;;
  *)
    echo "Usage: $0 [single|multi]" >&2
    echo "  single: 1 control-plane node (schedulable, hosts the OSD)" >&2
    echo "  multi:  1 control-plane + 2 workers (default; one worker hosts the OSD)" >&2
    exit 1
    ;;
esac
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Dev-grade Rook-Ceph OSD backing device.
# The single OSD is backed by a loopback device over a sparse file. The device
# is mounted into the OSD-hosting kind node via extraMounts in
# kind-config-<variant>.yaml.
# Loop devices vanish on host reboot, so this must run before each cluster
# creation. The steps below are idempotent.
ROOK_OSD_IMG="${ROOK_OSD_IMG:-/var/lib/rook/osd0.img}"
ROOK_OSD_LOOP="${ROOK_OSD_LOOP:-/dev/loop100}"
ROOK_OSD_SIZE="${ROOK_OSD_SIZE:-200G}"

sudo mkdir -p "$(dirname "$ROOK_OSD_IMG")"
if [[ ! -f "$ROOK_OSD_IMG" ]]; then
  sudo truncate -s "$ROOK_OSD_SIZE" "$ROOK_OSD_IMG"
fi
if ! sudo losetup "$ROOK_OSD_LOOP" >/dev/null 2>&1; then
  sudo losetup "$ROOK_OSD_LOOP" "$ROOK_OSD_IMG"
fi

kind create cluster --name kind --config "$REPO_ROOT/bootstrap/kind/kind-config-${VARIANT}.yaml"

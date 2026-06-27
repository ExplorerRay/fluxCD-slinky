#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-kind}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Dev-grade Rook-Ceph OSD backing device.
# The single OSD is backed by a loopback device over a sparse file. The device
# is mounted into the kind worker node via extraMounts in kind-config.yaml.
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

kind create cluster --name "$CLUSTER_NAME" --config "$REPO_ROOT/bootstrap/kind/kind-config.yaml"

#!/usr/bin/env bash
# Recreate the loopback-backed OSD device for the dev-grade single-node Ceph.
#
# Loop devices and their backing attachments do NOT survive a reboot, so this
# script must run on every boot BEFORE kubelet (and therefore Rook/Ceph) start.
# It is idempotent: it only creates the sparse file if missing and only
# attaches the loop device if not already attached.
set -euo pipefail

IMG="${ROOK_OSD_IMG:-/var/lib/rook/osd0.img}"
LOOP="${ROOK_OSD_LOOP:-/dev/loop100}"
SIZE="${ROOK_OSD_SIZE:-200G}"

mkdir -p "$(dirname "$IMG")"

# Create the sparse backing file if it does not exist (no real disk on host).
if [[ ! -f "$IMG" ]]; then
  truncate -s "$SIZE" "$IMG"
fi

# Attach the loop device if it is not already backed by this image.
if ! losetup "$LOOP" >/dev/null 2>&1; then
  losetup "$LOOP" "$IMG"
fi

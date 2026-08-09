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

# kind clusters created here cannot survive a host reboot: the loop device
# attachment, the /sys rw remount, and any kernel RBD mappings are all lost.
# A cluster whose node containers are stopped is therefore an unusable
# leftover — remove it. A running cluster is never deleted silently; tear it
# down explicitly first (README "Teardown").
if kind get clusters 2>/dev/null | grep -qx kind; then
  if [[ -n "$(docker ps -q --filter label=io.x-k8s.kind.cluster=kind)" ]]; then
    echo "ERROR: a kind cluster is already running." >&2
    echo "Tear it down first — see bootstrap/kind/README.md (Teardown)." >&2
    exit 1
  fi
  echo "Removing stopped leftover kind cluster (unusable after reboot)"
  kind delete cluster --name kind
fi

# Dev-grade Rook-Ceph OSD backing device.
# The single OSD is backed by a loopback device over a sparse file. The device
# is mounted into the OSD-hosting kind node via extraMounts in
# kind-config-<variant>.yaml.
# Loop devices vanish on host reboot, so this must run before each cluster
# creation. The steps below are idempotent.
ROOK_OSD_IMG="${ROOK_OSD_IMG:-/var/lib/rook/osd0.img}"
ROOK_OSD_LOOP="${ROOK_OSD_LOOP:-/dev/loop100}"
ROOK_OSD_SIZE="${ROOK_OSD_SIZE:-200G}"

# Remove stale Ceph state left by previous clusters. The dataDirHostPath
# (/var/lib/rook) is bind-mounted into the OSD node and outlives the cluster:
# a new mon scheduled there adopts the OLD cluster's store and keys, and the
# operator then fails auth with "RADOS permission denied (errno 13)" while
# waiting for mon quorum forever. The OSD image goes too (recreated below), so
# every cluster starts from a clean slate. Safe here: the guard above ensured
# no kind cluster is running. Only the fixed dataDirHostPath is ever wiped
# recursively — never $(dirname "$ROOK_OSD_IMG"), which an overridden
# ROOK_OSD_IMG could point at an arbitrary directory (e.g. $HOME).
sudo rm -rf /var/lib/rook
sudo rm -f "$ROOK_OSD_IMG"

sudo mkdir -p "$(dirname "$ROOK_OSD_IMG")"
if [[ ! -f "$ROOK_OSD_IMG" ]]; then
  sudo truncate -s "$ROOK_OSD_SIZE" "$ROOK_OSD_IMG"
fi
# If the kind node containers auto-restart after a host reboot (docker restart
# policy), docker recreates the then-missing bind-mount source as a DIRECTORY,
# which breaks losetup ("Is a directory"). Remove the artifact.
if [[ -d "$ROOK_OSD_LOOP" ]]; then
  sudo rmdir "$ROOK_OSD_LOOP"
fi
# The device node itself also vanishes on reboot; recreate it (block device,
# major 7 = loop, minor from the device name) before attaching.
if [[ ! -e "$ROOK_OSD_LOOP" ]]; then
  sudo mknod "$ROOK_OSD_LOOP" b 7 "${ROOK_OSD_LOOP#/dev/loop}"
fi
# If the device is still attached to a deleted backing file (teardown removed
# /var/lib/rook while the loop stayed up), detach so we attach the fresh image.
if sudo losetup "$ROOK_OSD_LOOP" 2>/dev/null | grep -q '(deleted)'; then
  sudo losetup -d "$ROOK_OSD_LOOP"
fi
if ! sudo losetup "$ROOK_OSD_LOOP" >/dev/null 2>&1; then
  sudo losetup "$ROOK_OSD_LOOP" "$ROOK_OSD_IMG"
fi

kind create cluster --name kind --config "$REPO_ROOT/bootstrap/kind/kind-config-${VARIANT}.yaml"

# Disable auto-restart on the node containers. kind defaults to restarting
# them on boot, but a rebooted cluster is broken here (see above) — and worse,
# docker recreates the then-missing /dev/loop100 bind-mount source as a
# directory, breaking the next setup run. Recreate via this script instead.
for node in $(kind get nodes --name kind); do
  docker update --restart=no "$node" >/dev/null
done

# kind mounts /sys read-only inside the node containers, which breaks krbd
# mapping: `rbd map` writes to /sys/bus/rbd/ and fails with EROFS, leaving
# every ceph-block PVC consumer stuck in ContainerCreating. Remount it rw.
# Node containers share the host kernel, so this is dev-grade by design.
for node in $(kind get nodes --name kind); do
  docker exec "$node" mount -o remount,rw /sys
done

# Workaround for kind issue #3436 (still open): kind bind-mounts
# /sys/devices/virtual/dmi/id/product_uuid and product_name read-only into each
# node container. Those mounts leave the node's sysfs instance PARTIALLY
# COVERED, and the kernel refuses to let runc mount a fresh sysfs inside a user
# namespace over a partially-covered one — every `hostUsers: false` pod then
# fails at sandbox creation with
#   error mounting "sysfs" to rootfs at "/sys": operation not permitted
# This breaks the non-privileged FreeIPA StatefulSet (infrastructure/freeipa).
# NOTE: this failure is silent in the kernel log — on 6.12.100 the userspace
# error above appears with NO corresponding dmesg line (in particular there is
# no "VFS: Mount too revealing", which older write-ups lead you to expect), so
# an empty dmesg rules nothing out.
# The fix from that issue thread: give the node a second, FULLY VISIBLE sysfs
# instance. runc picks that one as the source for the container's /sys, and the
# "too revealing" check passes. Idempotent — safe to re-run.
for node in $(kind get nodes --name kind); do
  docker exec "$node" sh -c \
    "mkdir -p /mnt/sysfs; mountpoint -q /mnt/sysfs || mount -t sysfs none /mnt/sysfs"
done

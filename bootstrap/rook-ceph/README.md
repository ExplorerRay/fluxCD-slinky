# Rook-Ceph OSD Loop Device (kubeadm)

The dev-grade single-node Ceph cluster has no spare disk, partition, or LV. Its
single OSD is backed by a **loopback device over a sparse file**
(`/dev/loop100` → `/var/lib/rook/osd0.img`, 200G sparse).

Loop devices do **not** survive a reboot, so they must be recreated on every
boot **before** kubelet (and therefore Rook/Ceph) start. The systemd unit in
this directory does exactly that.

## Prerequisites

- The host kernel must have the `rbd` and `ceph` modules available. Load and
  persist them:

  ```bash
  sudo modprobe rbd ceph
  echo -e "rbd\nceph" | sudo tee /etc/modules-load.d/rook-ceph.conf
  ```

## Install

```bash
sudo install -m 0755 bootstrap/rook-ceph/rook-osd-loop.sh /usr/local/sbin/rook-osd-loop.sh
sudo install -m 0644 bootstrap/rook-ceph/rook-osd-loop.service /etc/systemd/system/rook-osd-loop.service
sudo systemctl daemon-reload
sudo systemctl enable --now rook-osd-loop.service
```

Verify the device is attached:

```bash
losetup /dev/loop100
lsblk /dev/loop100
```

## Tunables (environment overrides)

The script honors these environment variables (defaults shown):

- `ROOK_OSD_IMG=/var/lib/rook/osd0.img`
- `ROOK_OSD_LOOP=/dev/loop100`
- `ROOK_OSD_SIZE=200G`

## Notes

- The OSD node hostname is set per cluster variant, not in the shared
  `overlays/kubeadm/values.yaml`: it lives in
  `infrastructure/rook-ceph/overlays/kubeadm-single/node-values.yaml`
  (`node1`) and `overlays/kubeadm-multi/node-values.yaml` (`node2`). These
  already match the provided Kubespray inventories, so no edit is normally
  needed — only a custom inventory using different hostnames requires one.
- This unit is intentionally **not** managed by FluxCD — it is host-level boot
  provisioning, like the Calico CNI install during Kubespray bootstrap.

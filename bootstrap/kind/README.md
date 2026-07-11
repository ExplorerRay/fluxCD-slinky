# Kind Bootstrap Runbook

## Prerequisites

- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)

## Setup

### Create cluster

Both variants are created with `bootstrap/kind/setup.sh`, which also prepares
the Rook-Ceph loop device (`/dev/loop100`) before `kind create cluster`. The
cluster name is always `kind`, so node hostnames stay deterministic
(`kind-control-plane`, `kind-worker`).

#### Single-node cluster

Uses `bootstrap/kind/kind-config-single.yaml` (1 control-plane node). kind
automatically makes the sole node schedulable, and it hosts the OSD — so this
variant now needs the config file and loop device too:

```bash
bash bootstrap/kind/setup.sh single
```

#### Multi-node cluster

Uses `bootstrap/kind/kind-config-multi.yaml` (1 control-plane + 2 workers; one
worker hosts the OSD):

```bash
bash bootstrap/kind/setup.sh multi
```

Running `bash bootstrap/kind/setup.sh` with no argument defaults to `multi`.

### Deploy Flux

Follow the [deploy procedure](../../README.md#deploy-procedure) in the root
README, using `clusters/kind-single` as the path for the single-node variant or
`clusters/kind-multi` for the multi-node variant.

## Teardown

Unmap any kernel RBD devices BEFORE deleting the cluster. The kernel Ceph
client lives in the node containers' network namespaces; once those are
deleted, stale mappings can neither reach the (gone) cluster nor be removed —
they hang `ceph-volume raw list` on the next cluster's OSD prepare, and only a
host reboot clears them. Then wipe the OSD loop device so the next cluster
gets a clean disk:

```bash
# /sys/bus/rbd is host-kernel-global; any node with the rw /sys remount works.
# Resolve the node dynamically — the single variant has no kind-worker.
node=$(kind get nodes --name kind | head -n1)
for id in $(ls /sys/bus/rbd/devices/ 2>/dev/null); do
  docker exec "$node" sh -c "echo '$id force' > /sys/bus/rbd/remove_single_major"
done
kind delete cluster --name kind
```

A force-unmap can still hang forever if the RBD image holds a mounted
filesystem with dirty journal I/O and the Ceph daemons are already gone — the
`osd_request_timeout=60` StorageClass map option bounds this to ~60s for
devices mapped by the CSI driver. If a removal does wedge (writer stuck in
D-state), only a host reboot clears it.

Stale host state (`/var/lib/rook`: old mon store + keys, ceph config, OSD
image) is removed automatically by `setup.sh` on the next run — a new mon
adopting the old store would fail auth with "RADOS permission denied
(errno 13)". To reclaim the space immediately without creating a new cluster:

```bash
sudo losetup -d /dev/loop100
sudo rm -rf /var/lib/rook
```

## Notes

- kind uses `kindnet` as CNI — no Calico needed locally

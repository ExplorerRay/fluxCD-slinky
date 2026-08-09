# Kind Bootstrap Runbook

## Prerequisites

- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- **At least 16 GiB of RAM on the host** (both variants) — see below.

## Resource requirements

**Give the host at least 16 GiB of RAM.** 8 GiB or 10 GiB does not work, and the
way it fails is easy to misread as a bug in the stack.

Measured pod memory *requests* for the full stack (kind-multi,
`kindest/node:v1.36.1`, `ROOK_OSD_SIZE=60G`) total **15.9 GiB**, dominated by
Rook-Ceph:

| namespace     | requests   |
| ------------- | ---------- |
| `rook-ceph`   | 13114 Mi   |
| `freeipa`     | 2048 Mi    |
| `kube-system` | 390 Mi     |
| `flux-system` | 384 Mi     |
| **total**     | **15936 Mi** |

The individual heavyweights are `rook-ceph-osd-0` at 4196 Mi (the chart sets
`osd_memory_target = 4Gi`), `ipa-0` at 2048 Mi, `rook-ceph-mon-a` at 1124 Mi,
four `csi-*-provisioner` pods at 1024 Mi each, the `csi-*plugin` DaemonSets at
640 Mi *per node*, and `rook-ceph-mgr-a` at 612 Mi.

Note these are *requests*, not usage — actual consumption is far lower (a
healthy single-node cluster sits around 7 GiB). Scheduling is what fails, not
the kernel OOM killer, so the symptoms are misleading.

### What too little RAM looks like

Observed on a 10 GiB VM running the single-node variant: memory requests reach
99% of allocatable, and `rook-ceph-operator` — a **128 Mi** pod — cannot
schedule. From there it cascades:

1. `rook-ceph-operator` → `FailedScheduling: Insufficient memory`
2. → `cephblockpool/ceph-blockpool` stays `Progressing`, never created
3. → every `ceph-block` PVC fails `ProvisioningFailed: pool (ceph-blockpool)
   not found` — permanently, not the transient race described under Notes
4. → `ipa-0` and `mariadb-0` sit `Pending` on unbound PVCs

Most pods are `Running` and every node condition is healthy
(`MemoryPressure: False`), so the cluster looks fine while being permanently
unable to provision storage. If you see a *persistent* `pool not found`, check
for a Pending `rook-ceph-operator` before suspecting Ceph.

### kind-multi does not need less memory — it just hides the ceiling

Every kind "node" is a container sharing one kernel, so **each node advertises
the entire host's memory as allocatable**. On a 14 GiB VM all three nodes report
~13.6 GiB allocatable *each*, so the scheduler believes it has ~40 GiB and
happily places 15.9 GiB of requests onto 13 GiB of real RAM. The multi variant
therefore schedules successfully where single-node refuses — not because it is
lighter, but because the scheduler cannot see the real limit. It works only
because requests exceed actual usage.

Size for the real total, not for what `kubectl describe node` reports.

### Disk

~19 GiB of actual usage with `ROOK_OSD_SIZE=60G` (the OSD image is sparse). The
repo default is 200G; if the host filesystem is smaller than that, override it:
`ROOK_OSD_SIZE=60G bash bootstrap/kind/setup.sh <variant>`.

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

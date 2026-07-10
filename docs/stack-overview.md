# Stack Overview

This repository deploys a [Slurm](https://slurm.schedmd.com/) HPC cluster on
Kubernetes using the [SlinkyProject](https://github.com/SlinkyProject) operator
stack, managed by FluxCD.

## Components

| Component | Namespace | Role |
|---|---|---|
| cert-manager | `cert-manager` | TLS certificate management; required by the Slurm operator |
| rook-ceph | `rook-ceph` | Rook-managed single-node Ceph providing the `ceph-block` default StorageClass |
| freeipa | `freeipa` | In-cluster FreeIPA identity server; Slurm authenticates via SSSD/LDAPS |
| mariadb-operator | `mariadb` | Kubernetes operator that manages MariaDB instances via CRDs |
| slurm-database | `slurm` | MariaDB instance storing Slurm accounting data (`slurm_acct_db`) |
| slurm-operator | `slinky` | SlinkyProject operator that reconciles Slurm cluster CRDs |
| slurm | `slurm` | The Slurm cluster itself: slurmctld, slurmd workers, and a login node |

## Dependency order

```
flux-cluster-repositories
  ├─ cert-manager
  │    └─ mariadb-operator
  │         └─ slurm-database ──┐
  │    └─ slurm-operator ───────┼─ slurm
  └─ rook-ceph ─────────────────┤
       ├─ slurm-database         │
       └─ freeipa ───────────────┘
```

`rook-ceph` reconciles directly off `flux-cluster-repositories` (in parallel
with `cert-manager`) and provides the default `ceph-block` StorageClass.
`slurm-database` depends on both `mariadb-operator` and `rook-ceph` because its
PVC requires the default StorageClass. `freeipa` depends on `rook-ceph` (its
`/data` PVC uses `ceph-block`), and `slurm` in turn depends on `freeipa` so the
FreeIPA server exists before login/compute pods try to authenticate against it
over LDAPS.

Flux enforces this order via `dependsOn` on each Kustomization.

## End state

Once all Kustomizations are healthy, the cluster runs:

- `slurmctld` — the Slurm controller
- `slurmd` — worker nodes accepting jobs
- A login node reachable over SSH on NodePort `32222`

Verify with:

```sh
kubectl -n slurm get pods
kubectl -n slurm exec <login-pod> -- sinfo   # should list partitions and worker nodes
```

## Storage upgrade path (dev -> prod)

The `rook-ceph` component is currently **dev-grade and block-only**: a single
node, one mon/mgr/OSD, `replica: 1`, failure domain `osd`, and the OSD backed by
a loopback device over a sparse file (`/dev/loop100`). It exposes one default
StorageClass, `ceph-block` (Ceph RBD, ReadWriteOnce). There is no CephFS
filesystem and no object store (RGW) yet — those are deferred.

To promote it to a production-grade layout:

1. In the overlay `values.yaml`
   (`infrastructure/rook-ceph/overlays/<cluster>/values.yaml`), replace the
   `/dev/loop100` entry in `cephClusterSpec.storage.nodes[].devices` with a real
   disk or LV name, and add the additional real nodes/devices.
2. Once at least three real nodes exist, bump
   `cephBlockPools[].spec.replicated.size` to `3` and change `failureDomain`
   from `osd` to `host`.
3. Drop the loopback bootstrap mechanism (the systemd unit for kubeadm and the
   `losetup` step for kind).

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->

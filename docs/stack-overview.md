# Stack Overview

This repository deploys a [Slurm](https://slurm.schedmd.com/) HPC cluster on
Kubernetes using the [SlinkyProject](https://github.com/SlinkyProject) operator
stack, managed by FluxCD.

## Components

| Component | Namespace | Role |
|---|---|---|
| cert-manager | `cert-manager` | TLS certificate management; required by the Slurm operator |
| mariadb-operator | `mariadb` | Kubernetes operator that manages MariaDB instances via CRDs |
| slurm-database | `slurm` | MariaDB instance storing Slurm accounting data (`slurm_acct_db`) |
| slurm-operator | `slinky` | SlinkyProject operator that reconciles Slurm cluster CRDs |
| slurm | `slurm` | The Slurm cluster itself: slurmctld, slurmd workers, and a login node |

## Dependency order

```
flux-cluster-repositories
  └─ cert-manager
       └─ mariadb-operator
            └─ slurm-database ──┐
       └─ slurm-operator ───────┴─ slurm
```

Flux enforces this order via `dependsOn` on each Kustomization.

## End state

Once all Kustomizations are healthy, the cluster runs:

- `slurmctld` — the Slurm controller
- `slurmd` — worker nodes accepting jobs
- A login node reachable over SSH on NodePort `32222`

Verify with:

```sh
kubectl -n slurm get pods
ssh -p 32222 root@<node-ip>
sinfo   # should list partitions and worker nodes
```

<!-- vim: set ft=markdown ff=unix fenc=utf-8 et sw=2 ts=2 sts=2 tw=79: -->

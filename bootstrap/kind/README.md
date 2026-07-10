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

```bash
kind delete cluster --name kind
```

## Notes

- kind uses `kindnet` as CNI — no Calico needed locally

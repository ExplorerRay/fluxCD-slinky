# Kind Bootstrap Runbook

## Prerequisites

- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)

## Setup

### Create cluster

#### Single-node cluster

```bash
kind create cluster --name kind
```

No config file needed — uses default kindnet CNI.

#### Multi-node cluster

Uses `bootstrap/kind/kind-config.yaml` (1 control-plane + 2 workers):

```bash
bash bootstrap/kind/setup.sh
```

Optional: specify cluster name (default: `kind`)
```bash
bash bootstrap/kind/setup.sh my-cluster-name
```

### Deploy Flux

Follow the [deploy procedure](../../README.md#deploy-procedure) in the root README using `clusters/kind` as the path.

## Teardown

```bash
kind delete cluster --name kind
```

For custom cluster name:
```bash
kind delete cluster --name <cluster-name>
```

## Notes

- kind uses `kindnet` as CNI — no Calico needed locally

#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-kind}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

kind create cluster --name "$CLUSTER_NAME" --config "$REPO_ROOT/bootstrap/kind/kind-config.yaml"

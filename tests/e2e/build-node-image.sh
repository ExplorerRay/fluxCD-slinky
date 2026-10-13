#!/usr/bin/env bash
# Build a kind node image with every image in tests/e2e/preload-images.txt
# already in the node's containerd, so the e2e cluster starts without pulling
# the stack from upstream registries. Used by
# .github/workflows/kind-node-image.yaml; .github/workflows/e2e.yaml boots
# kind-single from the result (KIND_NODE_IMAGE, bootstrap/kind/setup.sh).
#
# This is how kind preloads its own images: start containerd in a node
# container whose entrypoint is overridden, fetch the images, then commit the
# container with the original entrypoint. kind runs nodes with an anonymous
# /var volume, which docker seeds from the image's /var, so the content store
# lands in every node created from the image.
#
# Images are fetched, not unpacked: unpacking would need overlayfs on top of
# the builder's overlayfs rootfs, which the kernel refuses. containerd unpacks
# each image on first use instead, from local content, without the network.
#
# Usage: tests/e2e/build-node-image.sh <image-ref>
# Environment (defaults in brackets):
#   BASE_IMAGE    node image to start from [kind v0.32.0's default]
#   IMAGE_SOURCE  org.opencontainers.image.source label, links a GHCR package
#                 to its repository [unset]
#   PULL_JOBS     parallel fetches [4]

set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_IMAGE="${BASE_IMAGE:-kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5}"
PULL_JOBS="${PULL_JOBS:-4}"
LIST="$REPO_ROOT/tests/e2e/preload-images.txt"
BUILDER="kind-preload-build-$$"

log() { echo "==> $*"; }

mapfile -t images < <(sed 's/#.*//' "$LIST" | awk 'NF { print $1 }')
if ((${#images[@]} == 0)); then
  echo "ERROR: no images listed in $LIST" >&2
  exit 1
fi

log "starting builder from $BASE_IMAGE"
# /run and /tmp as tmpfs, as in a real kind node, so containerd's sockets and
# state stay out of the commit. --init reaps containerd once it is stopped;
# `sleep` as PID 1 would leave it a zombie that pgrep still matches.
docker run -d --name "$BUILDER" --init --privileged --tmpfs /run --tmpfs /tmp \
  --entrypoint sleep "$BASE_IMAGE" infinity >/dev/null
trap 'docker rm -f "$BUILDER" >/dev/null' EXIT

docker exec "$BUILDER" bash -c 'nohup containerd >/tmp/containerd.log 2>&1 &'
for _ in $(seq 30); do
  docker exec "$BUILDER" ctr version >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$BUILDER" ctr version >/dev/null

log "fetching ${#images[@]} images ($PULL_JOBS at a time)"
# Retries absorb transient registry errors; a fetch resumes from the blobs it
# already has.
fetch() {
  local builder=$1 ref=$2 attempt
  for attempt in 1 2 3; do
    if docker exec "$builder" ctr -n k8s.io content fetch --platform linux/amd64 "$ref" >/dev/null; then
      echo "    fetched $ref"
      return 0
    fi
    echo "    attempt $attempt failed: $ref" >&2
    sleep $((attempt * 5))
  done
  echo "ERROR: could not fetch $ref" >&2
  return 1
}
export -f fetch
# shellcheck disable=SC2016 # $1 and $2 are expanded by the inner bash
printf '%s\n' "${images[@]}" | xargs -P "$PULL_JOBS" -I{} bash -c 'fetch "$1" "$2"' _ "$BUILDER" {}

# Every listed reference must now be a CRI-visible image in k8s.io.
present="$(docker exec "$BUILDER" ctr -n k8s.io images ls -q)"
for ref in "${images[@]}"; do
  if ! grep -qxF "$ref" <<<"$present"; then
    echo "ERROR: $ref is not in the builder's image store" >&2
    exit 1
  fi
done

log "stopping containerd"
# SIGTERM flushes its metadata database; commit only once it has exited.
docker exec "$BUILDER" pkill -TERM -x containerd
for _ in $(seq 30); do
  docker exec "$BUILDER" pgrep -x containerd >/dev/null || break
  sleep 1
done
if docker exec "$BUILDER" pgrep -x containerd >/dev/null; then
  echo "ERROR: containerd did not exit" >&2
  exit 1
fi

log "committing $IMAGE"
# Restore kindest/node's entrypoint and clear the `sleep infinity` override.
changes=(
  --change 'ENTRYPOINT ["/usr/local/bin/entrypoint", "/sbin/init"]'
  --change 'CMD []'
  --change "LABEL io.github.fluxcd-slinky.preload.base=$BASE_IMAGE"
)
if [[ -n "${IMAGE_SOURCE:-}" ]]; then
  changes+=(--change "LABEL org.opencontainers.image.source=$IMAGE_SOURCE")
fi
docker commit "${changes[@]}" "$BUILDER" "$IMAGE" >/dev/null
docker image inspect "$IMAGE" --format 'size={{.Size}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}} stopsignal={{.Config.StopSignal}}'
log "built $IMAGE"

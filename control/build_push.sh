#!/usr/bin/env bash
# build_push.sh — build the arb-controller image and push it to Docker Hub.
# Run this where you have Docker + this source (e.g. the Mac). `docker login` first.
# The Pi then just pulls it (see run.sh) — no build on the Pi.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-jwkidd3/arb-controller:latest}"
PLATFORM="${PLATFORM:-linux/arm64}"   # controller Pi is 64-bit

echo "Building $IMAGE for $PLATFORM ..."
docker build --platform "$PLATFORM" -t "$IMAGE" .
echo "Pushing $IMAGE ..."
docker push "$IMAGE"
echo "Done. On the Pi:  IMAGE=$IMAGE ./run.sh"

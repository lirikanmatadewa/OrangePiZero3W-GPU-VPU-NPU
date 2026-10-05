#!/bin/bash
# Build the GPU, VPU, and NPU userspace tarballs in Docker.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR="$REPO_DIR/work"
SCRIPT_DIR="$REPO_DIR/scripts"
IMAGE_DIR="$WORK_DIR"
IMAGE_CONFIG_FILE="$REPO_DIR/.env"
source "$SCRIPT_DIR/image-config.sh"
load_image_config

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not in PATH" >&2
  exit 1
fi

exec docker run --rm --privileged \
  -v "$REPO_DIR:/repo" \
  -v "$WORK_DIR:/work" \
  -e IMAGE_CONFIG_FILE=/repo/.env \
  -e OPI_IMAGE="$OPI_IMAGE" \
  -e RADXA_IMAGE="$RADXA_IMAGE" \
  -w /work \
  debian:bookworm-slim \
  bash -c 'apt-get update && apt-get install -y util-linux && exec bash /repo/scripts/make-tarball.sh'

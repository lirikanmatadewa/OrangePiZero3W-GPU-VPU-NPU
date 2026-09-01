#!/bin/bash
# Build the GPU, VPU, and NPU userspace tarballs in Docker.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR="$REPO_DIR/work"
RADXA_IMAGE="$WORK_DIR/radxa-a733_bullseye_kde_r2.output_512.img"
OPI_IMAGE="$WORK_DIR/Orangepizero3w_1.0.0_ubuntu_jammy_desktop_xfce_linux6.6.98.img"

for image in "$RADXA_IMAGE" "$OPI_IMAGE"; do
  if [ ! -f "$image" ]; then
    echo "ERROR: required image is missing: $image" >&2
    exit 1
  fi
done

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not in PATH" >&2
  exit 1
fi

exec docker run --rm --privileged \
  -v "$REPO_DIR:/repo" \
  -v "$WORK_DIR:/work" \
  -w /work \
  debian:bookworm-slim \
  bash -c 'apt-get update && apt-get install -y util-linux && exec bash /repo/scripts/make-tarball.sh'

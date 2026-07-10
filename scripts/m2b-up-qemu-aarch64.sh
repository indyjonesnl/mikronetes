#!/usr/bin/env bash
# Start the M2b 4-node microVM cluster with emulated (TCG) qemu-system-aarch64:
#   node-1: control-plane, 10.88.0.2, tap mkn0
#   node-2: worker,        10.88.0.3, tap mkn1
#   node-3: worker,        10.88.0.4, tap mkn2
#   node-4: worker,        10.88.0.5, tap mkn3
#
# The nodes share bridge mkn-br0 via scripts/m2b-net.sh. Build arm64 images first
# with scripts/m2b-build-images.sh (CONTAINERD_RS_ARCH=arm64 CRUN_ARCH=arm64).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
  echo "ERROR: qemu-system-aarch64 not found on PATH" >&2
  echo "Install qemu-system-arm (or equivalent) to boot the emulated aarch64 cluster" >&2
  exit 1
fi

exec env BACKEND=qemu-aarch64 bash "$SCRIPT_DIR/m2b-up.sh"

#!/usr/bin/env bash
# Start the M2b 4-node microVM cluster with Cloud Hypervisor:
#   node-1: control-plane, 10.88.0.2, tap mkn0
#   node-2: worker,        10.88.0.3, tap mkn1
#   node-3: worker,        10.88.0.4, tap mkn2
#   node-4: worker,        10.88.0.5, tap mkn3
#
# The nodes share bridge mkn-br0 via scripts/m2b-net.sh. Build images first with:
#   bash scripts/m2b-build-images.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CH_BIN="${CH_BIN:-/usr/local/bin/cloud-hypervisor}"

if [ ! -x "$CH_BIN" ]; then
  echo "ERROR: cloud-hypervisor not executable at $CH_BIN" >&2
  echo "Set CH_BIN=/path/to/cloud-hypervisor or install it at /usr/local/bin/cloud-hypervisor" >&2
  exit 1
fi

exec env BACKEND=ch CH_BIN="$CH_BIN" bash "$SCRIPT_DIR/m2b-up.sh"

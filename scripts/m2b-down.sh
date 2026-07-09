#!/usr/bin/env bash
# Stop M2b Cloud Hypervisor/QEMU node processes without touching Docker Desktop
# or unrelated VMs. Use RESET_STATE=1 to remove per-node state disks after stop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${OUT:-$REPO_ROOT/out/m2b}"
RESET_STATE="${RESET_STATE:-0}"

for node in node-1 node-2 node-3 node-4; do
  node_dir="$OUT/$node"
  pid_file="$node_dir/ch.pid"
  if [ -f "$pid_file" ]; then
    pid="$(cat "$pid_file")"
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      echo "stopping $node cloud-hypervisor pid $pid"
      kill "$pid" || true
    fi
    rm -f "$pid_file"
  fi
done

{ pgrep -af "qemu-system-x86_64 .*${OUT}/node-[1-4]/m2b.img" || true; } \
  | awk '{print $1}' \
  | while read -r pid; do
      [ -n "$pid" ] || continue
      echo "stopping M2b qemu pid $pid"
      kill "$pid" || true
    done

if [ "$RESET_STATE" = 1 ]; then
  for node in node-1 node-2 node-3 node-4; do
    rm -f "$OUT/$node/state.img"
  done
fi

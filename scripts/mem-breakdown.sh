#!/usr/bin/env bash
# Per-component memory breakdown across the RUNNING cluster, so we can see which
# k8s/runtime component is the largest RAM user and focus optimization there.
#
# Metric: PSS (proportional set size, from /proc/<pid>/smaps_rollup) — shared pages
# are split across sharers, so summing PSS doesn't double-count shared libraries.
# Each node container's /proc also sees its pod processes (it IS the node), so one
# sweep per container captures control-plane binaries, the runtime, kubelet, and pods.
#
# Usage: mem-breakdown.sh [raw-out]   (run against an up cluster)
#
# Container list (which node containers to sweep) is parameterized:
#   - MEM_CONTAINERS env (space-separated) overrides the default, OR
#   - pass them as args after the raw-out file:
#       mem-breakdown.sh [raw-out] [container ...]
#   - default: the k0s PoC names (mikronetes-controller worker1 worker2).
# e.g. for the all-Rust rusternetes cluster:
#   MEM_CONTAINERS="rusternetes-cdrsf-node-1 rusternetes-cdrsf-node-2" \
#     scripts/mem-breakdown.sh mem-breakdown-raw.txt
set -uo pipefail
cd "$(dirname "$0")/.."
RAW="${1:-mem-breakdown-raw.txt}"
shift || true
: > "$RAW"

DEFAULT_CONTAINERS="mikronetes-controller mikronetes-worker1 mikronetes-worker2"
if [ "$#" -gt 0 ]; then
  CONTAINERS="$*"
else
  CONTAINERS="${MEM_CONTAINERS:-$DEFAULT_CONTAINERS}"
fi

for c in $CONTAINERS; do
  docker exec "$c" sh -c '
    for d in /proc/[0-9]*; do
      [ -r "$d/smaps_rollup" ] || continue
      pss=$(awk "/^Pss:/ {print \$2; exit}" "$d/smaps_rollup" 2>/dev/null)
      [ -z "$pss" ] && continue
      argv0=$(tr "\000" "\n" < "$d/cmdline" 2>/dev/null | head -n1)
      [ -z "$argv0" ] && continue
      echo "PSS:${pss} BASE:${argv0##*/}"
    done
  ' 2>/dev/null | sed "s|^|CONTAINER:${c} |" >> "$RAW"
done

python3 scripts/mem-breakdown.py "$RAW"

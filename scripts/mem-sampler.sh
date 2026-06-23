#!/usr/bin/env bash
# Sample node-container memory every <interval>s until killed.
# Appends one line per container per tick: EPOCH,NAME,USED  (USED e.g. "217.3MiB").
# Best-effort: a not-yet-started or vanished container is skipped, never fatal.
# Usage: mem-sampler.sh <csv-path> [interval-seconds]
set -u

CSV="${1:?usage: mem-sampler.sh <csv-path> [interval]}"
INTERVAL="${2:-2}"
CONTAINERS="mikronetes-controller mikronetes-worker1 mikronetes-worker2"

while true; do
  ts=$(date +%s)
  for c in $CONTAINERS; do
    # MemUsage looks like "217.3MiB / 512MiB"; take the used side.
    usage="$(docker stats --no-stream --format '{{.MemUsage}}' "$c" 2>/dev/null)" || continue
    [ -z "$usage" ] && continue
    used="${usage%% *}"
    [ -n "$used" ] && echo "${ts},${c},${used}" >> "$CSV"
  done
  sleep "$INTERVAL"
done

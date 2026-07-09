#!/usr/bin/env bash
# M2c-1 memory reporter: per-node/per-application memory (boot + idle samples)
# via hostPID/hostNetwork memprobe pods, plus node-1's control-plane total vs
# the 512MiB cap. Copied from M2b's memprobe machinery (scripts/m2b-smoke.sh)
# with an extended tracked-process set (kube-proxy, rusternetes-dns, apache2,
# php-fpm, httpd) so the PHP workload's memory shows up in the table.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${OUT:-$REPO_ROOT/out/m2b}"
VMIP="${VMIP:-10.88.0.2}"
MEM="${MEM:-512}"
CONTROL_PLANE_MEM="${CONTROL_PLANE_MEM:-${CP_MEM:-$MEM}}"
IDLE_SETTLE_SECS="${IDLE_SETTLE_SECS:-10}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5000}"
REGISTRY_ENDPOINT="${REGISTRY_ENDPOINT:-10.88.0.1:${REGISTRY_HOST_PORT}}"
MEMPROBE_IMAGE="${REGISTRY_ENDPOINT}/busybox:1.36.1"

fail=0
pass() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

node_ip() {
  case "$1" in
    node-1) echo 10.88.0.2 ;;
    node-2) echo 10.88.0.3 ;;
    node-3) echo 10.88.0.4 ;;
    node-4) echo 10.88.0.5 ;;
  esac
}

ensure_memprobe() {
  kc apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: m2b-memprobe
data:
  collect.sh: |
    #!/bin/sh
    set -eu
    mkdir -p /www
    proc_root=/host/proc
    [ -d "$proc_root/1" ] || proc_root=/proc
    while true; do
      {
        printf "application,rss_kib,processes\n"
        for d in "$proc_root"/[0-9]*; do
          [ -r "$d/status" ] || continue
          name=$(awk '/^Name:/ {print $2; exit}' "$d/status")
          rss=$(awk '/^VmRSS:/ {print $2; exit}' "$d/status")
          [ -n "$name" ] || continue
          [ -n "$rss" ] || rss=0
          case "$name" in
            machined|containerd-rs|rusternetes|kubelet|kube-proxy|flanneld|rusternetes-dns|whoami|apache2|php-fpm|httpd|crun|runc|pause)
              printf "%s %s\n" "$name" "$rss"
              ;;
          esac
        done | awk '
          { rss[$1]+=$2; count[$1]++ }
          END {
            for (app in rss) {
              printf "%s,%d,%d\n", app, rss[app], count[app]
            }
          }' | sort
      } > /www/memory.csv.tmp
      mv /www/memory.csv.tmp /www/memory.csv
      sleep 2
    done
YAML

  for node in node-1 node-2 node-3 node-4; do
    pod="m2b-memprobe-${node}"
    kc delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels:
    app: m2b-memprobe
spec:
  nodeName: ${node}
  hostPID: true
  hostNetwork: true
  restartPolicy: Always
  tolerations:
  - operator: Exists
  containers:
  - name: probe
    image: ${MEMPROBE_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "mkdir -p /www; sh /config/collect.sh & exec httpd -f -p 18080 -h /www"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: script
      mountPath: /config
    - name: host-proc
      mountPath: /host/proc
      readOnly: true
  volumes:
  - name: script
    configMap:
      name: m2b-memprobe
  - name: host-proc
    hostPath:
      path: /proc
      type: Directory
YAML
  done

  for node in node-1 node-2 node-3 node-4; do
    ip=$(node_ip "$node")
    ok=0
    for _ in $(seq 1 120); do
      if curl -sf --max-time 2 "http://${ip}:18080/memory.csv" 2>/dev/null \
        | awk -F, 'NR > 1 && $2 > 0 { found=1 } END { exit !found }'; then
        ok=1
        break
      fi
      sleep 1
    done
    [ "$ok" = 1 ] || bad "memprobe not ready on $node"
  done
}

print_memory_sample() {
  local phase="$1"
  local slug="$2"
  echo "=== per-node memory: $phase ==="
  printf "| Node | Phase | Application | RSS MiB | Processes |\n"
  printf "|------|-------|-------------|---------|-----------|\n"
  for node in node-1 node-2 node-3 node-4; do
    ip=$(node_ip "$node")
    csv="$OUT/m2b-memory-${node}-${slug}.csv"
    if curl -sf --max-time 5 "http://${ip}:18080/memory.csv" > "$csv" \
      && awk -F, 'NR > 1 && $2 > 0 { found=1 } END { exit !found }' "$csv"; then
      awk -F, -v node="$node" -v phase="$phase" '
        NR > 1 {
          printf "| %s | %s | %s | %.1f | %s |\n", node, phase, $1, $2 / 1024, $3
        }
      ' "$csv"
    else
      bad "failed memory sample for $node ($phase)"
    fi
  done
}

echo "=== memory boot/readiness ==="
ensure_memprobe
print_memory_sample "boot/readiness" "boot"

echo "settling ${IDLE_SETTLE_SECS}s before idle memory sample"
sleep "$IDLE_SETTLE_SECS"
print_memory_sample "booted/idle" "idle"

cp_total=$(awk -F, 'NR>1 && $1 ~ /rusternetes|containerd-rs|flanneld|crun|kube-proxy/ {s+=$2} END{printf "%.1f", s/1024}' "$OUT/m2b-memory-node-1-idle.csv")
printf "\nnode-1 control-plane total (idle): %s MiB / 512 MiB cap\n" "$cp_total"

if [ "$fail" -eq 0 ]; then
  exit 0
else
  exit 1
fi

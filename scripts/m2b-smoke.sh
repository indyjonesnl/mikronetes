#!/usr/bin/env bash
# M2b smoke gate: four nodes, cross-node CNI, per-node memory reporting.
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

# IPv4 CIDR membership, pure bash. Used to assert each pod IP falls inside its
# own node's podCIDR — the invariant a broken flannel IPAM violates by handing
# every node a lease out of the same subnet.
ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24)|(b<<16)|(c<<8)|d )); }
ip_in_cidr() {
  local ip="$1" cidr="$2" base len mask ipi basei
  base="${cidr%/*}"; len="${cidr#*/}"
  case "$len" in ''|*[!0-9]*) return 1;; esac
  [ "$len" -ge 0 ] && [ "$len" -le 32 ] || return 1
  ipi=$(ip2int "$ip"); basei=$(ip2int "$base")
  if [ "$len" -eq 0 ]; then mask=0; else mask=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF )); fi
  [ $(( ipi & mask )) -eq $(( basei & mask )) ]
}

echo "=== 1. all nodes Ready ==="
for node in node-1 node-2 node-3 node-4; do
  if [ "$(kc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; then
    pass "$node Ready"
  else
    bad "$node not Ready"
  fi
done

echo "=== 2. flannel-rs Ready on all nodes ==="
ready=$(kc get ds -n kube-flannel kube-flannel-ds -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
if [ "${ready:-0}" -ge 4 ]; then
  pass "flannel-rs Ready on $ready nodes"
else
  bad "flannel-rs Ready count ${ready:-0}, expected 4"
  kc get pods -n kube-flannel -o wide 2>/dev/null || true
fi

echo "=== 3. whoami pods Running and host-routable ==="
for node in node-1 node-2 node-3 node-4; do
  pod="whoami-${node}"
  ph=$(kc get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  ip=$(kc get pod "$pod" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
  if [ "$ph" = Running ] && [ -n "$ip" ] && curl -sf --max-time 5 "http://${ip}:80" >/dev/null 2>&1; then
    pass "$pod Running and reachable ($ip)"
  else
    bad "$pod not Running/reachable (phase=$ph ip=$ip)"
  fi
done

echo "=== 3b. each pod IP within its node podCIDR and globally distinct ==="
# The duplicate-pod-IP failure mode: flannel not honoring per-node podCIDR, so
# every node allocates from the same /24 and hands out identical IPs. The old
# cross-node probe passed anyway because every target resolved to node-1's pod.
# This check fails deterministically on that bug, independent of routing.
declare -A seen_ip
for node in node-1 node-2 node-3 node-4; do
  pod="whoami-${node}"
  ip=$(kc get pod "$pod" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
  cidr=$(kc get node "$node" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "")
  if [ -z "$ip" ] || [ -z "$cidr" ]; then
    bad "$pod missing IP or node podCIDR (ip='$ip' cidr='$cidr')"
    continue
  fi
  if ip_in_cidr "$ip" "$cidr"; then
    pass "$pod IP $ip within node podCIDR $cidr"
  else
    bad "$pod IP $ip NOT within node podCIDR $cidr — flannel IPAM ignoring per-node subnet"
  fi
  if [ -n "${seen_ip[$ip]:-}" ]; then
    bad "duplicate pod IP $ip on $pod and ${seen_ip[$ip]} — nodes sharing one subnet"
  else
    seen_ip[$ip]="$pod"
  fi
done

echo "=== 4. cross-node pod probes ==="
for node in node-1 node-2 node-3 node-4; do
  pod="curl-${node}"
  ok=0
  for _ in $(seq 1 60); do
    ph=$(kc get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$ph" = Succeeded ] && ok=1 && break
    [ "$ph" = Failed ] && break
    sleep 2
  done
  [ "$ok" = 1 ] && pass "$pod cross-node HTTP succeeded" || bad "$pod did not succeed"
done

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
            machined|containerd-rs|rusternetes|kubelet|flanneld|whoami|crun|runc|pause)
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

echo "=== 5. memory boot/readiness ==="
ensure_memprobe
print_memory_sample "boot/readiness" "boot"

echo "settling ${IDLE_SETTLE_SECS}s before idle memory sample"
sleep "$IDLE_SETTLE_SECS"
print_memory_sample "booted/idle" "idle"

echo "=== 6. host VMM RSS + OOM scan ==="
printf "| Node | Backend | VMM RSS MiB | Guest Cap MiB |\n"
printf "|------|---------|-------------|---------------|\n"
for node in node-1 node-2 node-3 node-4; do
  guest_cap="$MEM"
  [ "$node" = node-1 ] && guest_cap="$CONTROL_PLANE_MEM"
  backend="unknown"
  vmm_pid=""
  if [ -f "$OUT/$node/ch.pid" ]; then
    vmm_pid="$(cat "$OUT/$node/ch.pid")"
    if [ -n "$vmm_pid" ] && kill -0 "$vmm_pid" >/dev/null 2>&1; then
      backend="cloud-hypervisor"
    else
      vmm_pid=""
    fi
  fi
  if [ -z "$vmm_pid" ]; then
    vmm_pid=$(pgrep -af "qemu-system-x86_64 .*out/m2b/${node}/m2b.img" 2>/dev/null \
      | awk '{print $1}' \
      | head -1)
    [ -n "$vmm_pid" ] && backend="qemu"
  fi
  rss=$(printf '%s\n' "$vmm_pid" \
    | xargs -r ps -o rss= -p 2>/dev/null \
    | awk '{s+=$1} END{if(s) printf "%.1f", s/1024}')
  [ -n "$rss" ] || rss="unknown"
  printf "| %s | %s | %s | %s |\n" "$node" "$backend" "$rss" "$guest_cap"
  if [ -f "$OUT/$node/serial.log" ] && grep -qiE 'Out of memory|oom-kill|Kernel panic' "$OUT/$node/serial.log"; then
    bad "$node serial log contains OOM/panic"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "=== M2b SMOKE PASSED ==="
  exit 0
else
  echo "=== M2b SMOKE FAILED ===" >&2
  exit 1
fi

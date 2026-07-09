#!/usr/bin/env bash
# M2a smoke gate — the final M2a assertion.
#
# Run after the VM is up (scripts/m2a-up.sh) and bootstrapped
# (scripts/m2a-bootstrap.sh). Exits 0 + prints a 512 MiB memory report only if
# every assertion holds. Designed to be the CI gate (Task F1).
#
# Assertions:
#   1. node-1 Ready via the Kubernetes API.
#   2. machined reports its supervised services healthy (mTLS API, machinectl).
#   3. the CRI runtime (containerd-rs) reports ready (machined RuntimeStatus).
#   4. the whoami pod is Running and reachable over the selected CNI pod network.
#   5. no guest OOM in the serial log; report host VMM RSS + guest per-app memory.
#
# Env:
#   VMIP          VM api-server IP        (default: 10.88.0.2)
#   OUT           output dir              (default: <repo-root>/out)
#   MACHINED_RS   machined-rs checkout    (default: ~/PhpstormProjects/machined-rs)
#   CARGO_TARGET_DIR machined-rs target dir (default checked before MR/target)
#   MEM           expected VM RAM in MiB   (default: 512)
#   CNI_PLUGIN    flannel-rs (default). calico-rs can be added as another case.
#   BUSYBOX_IMAGE_SOURCE source image mirrored for the guest memprobe
#   IDLE_SETTLE_SECS seconds to wait before the booted/idle memory sample (default: 10)
#   MEMPROBE_STARTUP_TIMEOUT seconds to wait for the first guest memory sample (default: 120)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMIP="${VMIP:-10.88.0.2}"
OUT="${OUT:-$(cd "$SCRIPT_DIR/.." && pwd)/out}"
MR="${MACHINED_RS:-/home/jones/PhpstormProjects/machined-rs}"
MCTL=""
for candidate in \
  "${CARGO_TARGET_DIR:-}/release/machinectl" \
  "/tmp/machined-rs-build/release/machinectl" \
  "$MR/target/release/machinectl"; do
  if [ -x "$candidate" ]; then
    MCTL="$candidate"
    break
  fi
done
[ -n "$MCTL" ] || MCTL="$MR/target/release/machinectl"
BUNDLE="$OUT/pki/machinectl"
CNI_PLUGIN="${CNI_PLUGIN:-flannel-rs}"
MEM="${MEM:-512}"
BUSYBOX_IMAGE_SOURCE="${BUSYBOX_IMAGE_SOURCE:-busybox:1.36.1}"
MEMPROBE_IMAGE="10.88.0.1:5000/memprobe-busybox:1.36.1"
MEMPROBE_URL="http://${VMIP}:18080/memory.csv"
IDLE_SETTLE_SECS="${IDLE_SETTLE_SECS:-10}"
MEMPROBE_STARTUP_TIMEOUT="${MEMPROBE_STARTUP_TIMEOUT:-120}"
MEMPROBE_READY=0

fail=0
pass() { printf 'PASS: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
kc()   { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }
mctl() { "$MCTL" --endpoint "https://$VMIP:50000" --bundle "$BUNDLE" "$@"; }

ensure_registry_image() {
  local src="$1"
  local dst="$2"
  if command -v docker >/dev/null 2>&1; then
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx m2a-registry; then
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx m2a-registry; then
        docker start m2a-registry >/dev/null
      else
        docker run -d --restart unless-stopped --name m2a-registry -p 5000:5000 registry:2 >/dev/null
      fi
    fi
    docker image inspect "$src" >/dev/null 2>&1 || docker pull "$src" >/dev/null
    docker tag "$src" "localhost:5000/${dst}"
    docker push "localhost:5000/${dst}" >/dev/null
  else
    bad "docker is unavailable; cannot mirror memprobe image"
    return 1
  fi
}

ensure_memprobe() {
  [ "$MEMPROBE_READY" = 1 ] && return 0
  if curl -sf --max-time 2 "$MEMPROBE_URL" 2>/dev/null | awk -F, 'NR > 1 && $2 > 0 { found=1 } END { exit !found }'; then
    MEMPROBE_READY=1
    return 0
  fi
  ensure_registry_image "$BUSYBOX_IMAGE_SOURCE" "memprobe-busybox:1.36.1" || return 1
  kc delete pod m2a-memprobe --ignore-not-found --wait=false >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    [ -z "$(kc get pod m2a-memprobe -o name 2>/dev/null)" ] && break
    sleep 1
  done
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: m2a-memprobe
  namespace: default
data:
  collect.sh: |
    #!/bin/sh
    set -eu
    mkdir -p /www
    proc_root=/host/proc
    [ -d "\$proc_root/1" ] || proc_root=/proc
    while true; do
      {
        printf "application,rss_kib,processes\n"
        for d in "\$proc_root"/[0-9]*; do
          [ -r "\$d/status" ] || continue
          name=\$(awk '/^Name:/ {print \$2; exit}' "\$d/status")
          rss=\$(awk '/^VmRSS:/ {print \$2; exit}' "\$d/status")
          [ -n "\$name" ] || continue
          [ -n "\$rss" ] || rss=0
          case "\$name" in
            machined|containerd-rs|rusternetes|flanneld|whoami|crun|runc|pause)
              printf "%s %s\n" "\$name" "\$rss"
              ;;
          esac
        done | awk '
          { rss[\$1]+=\$2; count[\$1]++ }
          END {
            for (app in rss) {
              printf "%s,%d,%d\n", app, rss[app], count[app]
            }
          }' | sort
      } > /www/memory.csv.tmp
      mv /www/memory.csv.tmp /www/memory.csv
      sleep 2
    done
---
apiVersion: v1
kind: Pod
metadata:
  name: m2a-memprobe
  namespace: default
  labels:
    app: m2a-memprobe
spec:
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
      name: m2a-memprobe
  - name: host-proc
    hostPath:
      path: /proc
      type: Directory
EOF
  for _ in $(seq 1 "$MEMPROBE_STARTUP_TIMEOUT"); do
    # rusternetes can briefly report a stale or misleading pod phase here; the
    # smoke gate only needs the host-network sampler endpoint to return data.
    if curl -sf --max-time 2 "$MEMPROBE_URL" 2>/dev/null | awk -F, 'NR > 1 && $2 > 0 { found=1 } END { exit !found }'; then
      MEMPROBE_READY=1
      return 0
    fi
    sleep 1
  done
  bad "m2a-memprobe did not become Running"
  kc describe pod m2a-memprobe 2>/dev/null || true
  return 1
}

print_memory_sample() {
  local label="$1"
  local slug="$2"
  local csv="$OUT/m2a-memory-${slug}.csv"

  echo "=== guest per-application memory: $label ==="
  if ! ensure_memprobe; then
    bad "cannot collect guest memory sample: $label"
    return
  fi

  if curl -sf --max-time 5 "$MEMPROBE_URL" > "$csv" \
    && awk -F, 'NR > 1 && $2 > 0 { found=1 } END { exit !found }' "$csv"; then
    awk -F, '
      NR == 1 {
        printf "| Application | RSS MiB | Processes |\n"
        printf "|-------------|---------|-----------|\n"
        next
      }
      {
        printf "| %s | %.1f | %s |\n", $1, $2 / 1024, $3
        total += $2
      }
      END {
        printf "| TOTAL | %.1f |  |\n", total / 1024
      }
    ' "$csv"
    echo "memory csv: $csv"
  else
    bad "guest memory probe failed: $label"
  fi
}

case "$CNI_PLUGIN" in
  flannel-rs)
    CNI_NAME="flannel-rs"
    CNI_NAMESPACE="kube-flannel"
    CNI_POD_JSONPATH='{.items[0].metadata.name}'
    ;;
  calico-rs)
    bad "CNI_PLUGIN=calico-rs is recognized but no M2a calico-rs smoke selector is wired yet"
    CNI_NAME="calico-rs"
    CNI_NAMESPACE=""
    CNI_POD_JSONPATH=""
    ;;
  *)
    bad "unsupported CNI_PLUGIN '$CNI_PLUGIN' (supported: flannel-rs)"
    CNI_NAME="$CNI_PLUGIN"
    CNI_NAMESPACE=""
    CNI_POD_JSONPATH=""
    ;;
esac

echo "=== 1. node Ready ==="
if [ "$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; then
  pass "node-1 Ready"
else
  bad "node-1 not Ready"
  kc get node node-1 -o wide 2>/dev/null || true
fi

echo "=== 2. machined services healthy (mTLS API) ==="
if [ -x "$MCTL" ] && [ -d "$BUNDLE" ]; then
  out=$(mctl get ServiceStatus 2>&1 || echo "")
  echo "$out"
  if echo "$out" | grep -q 'rusternetes' && echo "$out" | grep -q 'healthy=true'; then
    pass "machined reports services healthy"
  else
    bad "machined ServiceStatus not healthy"
  fi
else
  bad "machinectl ($MCTL) or client bundle ($BUNDLE) missing"
fi

echo "=== 3. CRI is containerd-rs (RuntimeStatus) ==="
if [ -x "$MCTL" ] && [ -d "$BUNDLE" ]; then
  rout=$(mctl get RuntimeStatus 2>&1 || echo "")
  echo "$rout"
  echo "$rout" | grep -q 'ready=true' \
    && pass "containerd-rs RuntimeReady" || bad "runtime not ready"
else
  bad "cannot query RuntimeStatus (machinectl/bundle missing)"
fi

print_memory_sample "boot/readiness" "boot"

echo "=== 4. workload pod Running + reachable over $CNI_NAME ==="
pod_ip=""
for _ in $(seq 1 60); do
  ph=$(kc get pod whoami -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  pod_ip=$(kc get pod whoami -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
  [ "$ph" = Running ] && [ -n "$pod_ip" ] && break
  sleep 5
done
if [ "$(kc get pod whoami -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && [ -n "$pod_ip" ]; then
  # Verify actual pod-network data plane via the host route installed by
  # m2a-net.sh. Avoid kubectl exec/logs here; those are separate streaming APIs.
  if curl -sf --max-time 5 "http://${pod_ip}:80" 2>/dev/null | grep -q 'Hostname:'; then
    pass "whoami Running and serving over $CNI_NAME ($pod_ip)"
  else
    bad "whoami Running ($pod_ip) but not reachable over $CNI_NAME"
  fi
else
  bad "whoami pod not Running"
  kc get pod whoami -o wide 2>/dev/null || true
fi

echo "settling ${IDLE_SETTLE_SECS}s before booted/idle memory sample"
sleep "$IDLE_SETTLE_SECS"
print_memory_sample "booted/idle" "idle"

echo "=== 5. ${MEM} MiB memory report ==="
hostrss=$(pgrep -af 'qemu-system-x86_64 .*out/m2a.img' 2>/dev/null \
  | awk '{print $1}' \
  | xargs -r ps -o rss= -p 2>/dev/null \
  | awk '{s+=$1} END{if(s)print s/1024 " MiB (m2a qemu RSS)"}')
[ -z "$hostrss" ] && hostrss=$(ps -o rss= -C cloud-hypervisor 2>/dev/null | awk '{s+=$1} END{if(s)print s/1024 " MiB (ch RSS)"}')
echo "host VMM RSS: ${hostrss:-unknown}"
echo "guest cap: ${MEM} MiB (enforced by -m ${MEM} / --memory size=${MEM}M)"
if [ -f "$OUT/serial.log" ] && grep -qiE 'Out of memory|oom-kill' "$OUT/serial.log"; then
  bad "guest OOM in serial log"
else
  pass "no guest OOM"
fi

if [ "$fail" -eq 0 ]; then
  echo "=== M2a SMOKE PASSED ==="
  exit 0
else
  echo "=== M2a SMOKE FAILED ===" >&2
  exit 1
fi

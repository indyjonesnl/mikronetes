#!/usr/bin/env bash
# Services-parity smoke for the DinD all-Rust cluster.
set -uo pipefail
VMIP="${VMIP:-10.88.0.2}"
fail=0
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }
pass() { printf 'PASS: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
prefix() { case "$1" in node-2) echo 10.244.1.;; node-3) echo 10.244.2.;; *) echo "NO.SUCH.CIDR.";; esac; }

echo "=== 1. workers Ready on containerd-rs ==="
for n in node-2 node-3; do
  st=$(kc get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  rt=$(kc get node "$n" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null)
  { [ "$st" = True ] && case "$rt" in containerd-rs://*) true;; *) false;; esac; } \
    && pass "$n Ready ($rt)" || bad "$n not Ready on containerd-rs (status=$st runtime=$rt)"
done

echo "=== 2. whoami pods: 2, one per worker, distinct podCIDRs ==="
mapfile -t rows < <(kc get pods -l app=whoami -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.podIP}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null)
count=0; declare -A seen
for row in "${rows[@]}"; do
  set -- $row; node="$1"; ip="$2"; ph="$3"; [ -z "$node" ] && continue; count=$((count+1))
  [ "$ph" = Running ] || bad "$node whoami phase=$ph"
  case "$ip" in "$(prefix "$node")"*) pass "$node whoami $ip in podCIDR";; *) bad "$node whoami $ip not in $(prefix "$node")0/24";; esac
  [ -n "${seen[$ip]:-}" ] && bad "duplicate whoami IP $ip" || seen[$ip]="$node"
done
[ "$count" = 2 ] && pass "exactly 2 whoami pods" || bad "whoami pod count=$count (expected 2)"

echo "=== 3. Service load-balances across >=2 backends on distinct workers (probe pod) ==="
cip=$(kc get svc whoami -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
# Delete any prior probe pod and WAIT until it is actually gone, so a re-run
# against the same cluster cannot stale-read the previous run's Succeeded pod.
kc delete pod lb-probe --ignore-not-found >/dev/null 2>&1 || true
for _ in $(seq 1 30); do kc get pod lb-probe >/dev/null 2>&1 || break; sleep 1; done
applied=1
kc apply -f - >/dev/null <<YAML && applied=0
apiVersion: v1
kind: Pod
metadata: { name: lb-probe }
spec:
  nodeName: node-2
  restartPolicy: Never
  containers:
  - name: c
    image: 10.88.0.1:5000/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command:
    - sh
    - -c
    - |
      c=\$(for i in \$(seq 1 20); do wget -qO- --timeout=5 http://$cip:80 | grep -i hostname; done | sort -u | wc -l)
      echo "backends=\$c"; [ "\$c" -ge 2 ]
YAML
if [ "$applied" -ne 0 ]; then
  bad "LB probe pod apply failed"
else
  ph=""; for _ in $(seq 1 90); do ph=$(kc get pod lb-probe -o jsonpath='{.status.phase}' 2>/dev/null); { [ "$ph" = Succeeded ] || [ "$ph" = Failed ]; } && break; sleep 2; done
  ec=$(kc get pod lb-probe -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)
  if [ "${ec:-1}" = 0 ]; then
    pass "Service load-balanced across >=2 distinct backends"
  else
    kc logs lb-probe >&2 2>&1 || true
    bad "LB probe phase=$ph exitCode=${ec:-timeout}"
  fi
fi
kc delete pod lb-probe --wait=false >/dev/null 2>&1 || true

if [ "$fail" -eq 0 ]; then echo "=== DIND SMOKE PASSED ==="; exit 0; else echo "=== DIND SMOKE FAILED ===" >&2; exit 1; fi

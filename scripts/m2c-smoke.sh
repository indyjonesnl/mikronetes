#!/usr/bin/env bash
# M2c-0 smoke: kube-proxy ClusterIP load-balancing + DNS-by-name on the microVM.
#
# IMPORTANT: this gate never uses `kubectl exec` — containerd-rs exec/log
# streaming is not wired (streamproxy proxy_upgrade fails), so exec-based
# checks give false negatives. Every in-cluster assertion runs as a pod whose
# COMMAND performs the check and encodes the result in its exit code; the gate
# reads the pod phase + terminated exitCode.
set -uo pipefail
VMIP="${VMIP:-10.88.0.2}"
fail=0
pass() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

# Wait for a Never-restart pod to terminate; echo its container exit code
# (or "timeout"). No exec/logs — phase + terminated.exitCode only.
wait_probe() {
  local name="$1" ph ec
  for _ in $(seq 1 60); do
    ph=$(kc get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo)
    { [ "$ph" = Succeeded ] || [ "$ph" = Failed ]; } && break
    sleep 2
  done
  ec=$(kc get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo)
  echo "${ec:-timeout}"
}

echo "=== 1. all nodes Ready ==="
for node in node-1 node-2 node-3 node-4; do
  [ "$(kc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    && pass "$node Ready" || bad "$node not Ready"
done

echo "=== 2. kube-proxy programmed NAT rules on each node (serial evidence) ==="
# kube-proxy only logs "built N bytes of NAT rules" once Services exist, so this
# can lag bootstrap by a sync interval — poll rather than grep once.
for node in node-1 node-2 node-3 node-4; do
  ok=0
  for _ in $(seq 1 20); do
    # grep the file directly (no `sed |` pipe): under `set -o pipefail`, grep -q
    # closing the pipe early SIGPIPEs sed and the pipeline reports failure even
    # on a match. The target text carries no ANSI codes, so raw grep is fine.
    if grep -qaE 'built [0-9]+ bytes of NAT rules' "out/m2b/$node/serial.log" 2>/dev/null; then
      ok=1; break
    fi
    sleep 2
  done
  [ "$ok" = 1 ] && pass "$node kube-proxy applied NAT rules" || bad "$node kube-proxy did not report applying NAT rules"
done

echo "=== 3. system Services own their pinned ClusterIPs; whoami is separate ==="
kn=$(kc get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
kd=$(kc get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[ "$kn" = 10.96.0.1 ] && pass "kubernetes Service = 10.96.0.1" || bad "kubernetes Service = '$kn' (expected 10.96.0.1)"
[ "$kd" = 10.96.0.10 ] && pass "kube-dns Service = 10.96.0.10" || bad "kube-dns Service = '$kd' (expected 10.96.0.10)"
cip=$(kc get svc whoami -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
n=$(kc get endpointslice -l kubernetes.io/service-name=whoami -o jsonpath='{.items[*].endpoints[*].addresses[0]}' 2>/dev/null | wc -w)
{ [ -n "$cip" ] && [ "$cip" != 10.96.0.1 ] && [ "$n" -ge 2 ]; } \
  && pass "whoami ClusterIP=$cip endpoints=$n" || bad "whoami ClusterIP='$cip' endpoints=$n (want non-.1 IP, >=2 endpoints)"

echo "=== 4. rusternetes-dns Deployment Ready + kube-dns has endpoints ==="
r=$(kc get deploy rusternetes-dns -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
de=$(kc get endpointslice -n kube-system -l kubernetes.io/service-name=kube-dns -o jsonpath='{.items[*].endpoints[*].addresses[0]}' 2>/dev/null | wc -w)
{ [ "${r:-0}" = 1 ] && [ "${de:-0}" -ge 1 ]; } && pass "rusternetes-dns Ready, kube-dns endpoints=$de" || bad "rusternetes-dns readyReplicas=$r kube-dns endpoints=$de"

echo "=== 5. DNS-by-name + ClusterIP load-balancing (probe pod, no exec) ==="
# One pod on node-3: resolve the Service by name via cluster DNS (10.96.0.10),
# then wget the Service NAME 20x and require >=2 distinct backend hostnames.
# exit 11 = DNS failed; exit 12 = LB spread < 2; exit 0 = both good.
kc delete pod m2c-e2e --ignore-not-found --wait=false >/dev/null 2>&1 || true
sleep 1
kc apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: m2c-e2e }
spec:
  nodeName: node-3
  restartPolicy: Never
  containers:
  - name: c
    image: 10.88.0.1:5000/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command:
    - sh
    - -c
    - |
      # Match the ANSWER (the Address after the "Name:" line), not busybox's own
      # "Server/Address: 10.96.0.10:53" resolver lines which print regardless.
      addr=$(nslookup whoami.default.svc.cluster.local 2>/dev/null | awk 'x && $1=="Address:"{print $2; exit} /^Name:/{x=1}')
      echo "resolved=$addr"
      case "$addr" in 10.96.*) ;; *) exit 11;; esac
      c=$(for i in $(seq 1 20); do wget -qO- --timeout=5 http://whoami.default.svc.cluster.local:80 | grep Hostname; done | sort -u | wc -l)
      echo "backends=$c"
      [ "$c" -ge 2 ] || exit 12
YAML
ec=$(wait_probe m2c-e2e)
kc delete pod m2c-e2e --ignore-not-found --wait=false >/dev/null 2>&1 || true
case "$ec" in
  0)  pass "DNS-by-name resolved + Service load-balanced across >=2 backends" ;;
  11) bad "cluster DNS did not resolve whoami.default.svc.cluster.local" ;;
  12) bad "Service reached but load-balancing spread < 2 backends" ;;
  *)  bad "e2e probe did not complete (exitCode=$ec)" ;;
esac

echo "=== 6. no OOM / kernel panic in serial logs ==="
for node in node-1 node-2 node-3 node-4; do
  grep -qaiE 'Out of memory|oom-kill|Kernel panic' "out/m2b/$node/serial.log" 2>/dev/null \
    && bad "$node serial has OOM/panic" || pass "$node no OOM/panic"
done

if [ "$fail" -eq 0 ]; then echo "=== M2c-0 SMOKE PASSED ==="; exit 0; else echo "=== M2c-0 SMOKE FAILED ===" >&2; exit 1; fi

#!/usr/bin/env bash
# M2c-0 smoke: kube-proxy Service load-balancing + DNS resolution.
set -uo pipefail
VMIP="${VMIP:-10.88.0.2}"
fail=0
pass() { printf 'PASS: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

echo "=== 1. worker kube-proxy services running ==="
for node in node-2 node-3 node-4; do
  ip=$(case $node in node-2) echo 10.88.0.3;; node-3) echo 10.88.0.4;; node-4) echo 10.88.0.5;; esac)
  if grep -qaE 'kube-proxy|RUSTERNETES-SERVICES|Applied .*rules' "out/m2b/$node/serial.log" 2>/dev/null; then
    pass "$node kube-proxy active in serial log"
  else
    bad "$node kube-proxy not evidenced in serial log"
  fi
done

echo "=== 2. Service has endpoints ==="
cip=$(kc get svc whoami -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
n=$(kc get endpointslice -l kubernetes.io/service-name=whoami -o jsonpath='{.items[*].endpoints[*].addresses[0]}' 2>/dev/null | wc -w)
[ -n "$cip" ] && [ "$n" -ge 2 ] && pass "whoami ClusterIP=$cip endpoints=$n" || bad "whoami ClusterIP='$cip' endpoints=$n (expected >=2)"

echo "=== 3. run a client pod on node-2 for in-cluster checks ==="
kc delete pod m2c-client --ignore-not-found --wait=false >/dev/null 2>&1 || true
kc apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: m2c-client, labels: { app: m2c-client } }
spec:
  nodeName: node-2
  restartPolicy: Never
  containers:
  - name: c
    image: 10.88.0.1:5000/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command: ["sh","-c","sleep 3600"]
YAML
ok=0
for _ in $(seq 1 60); do
  [ "$(kc get pod m2c-client -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && ok=1 && break
  sleep 2
done
[ "$ok" = 1 ] && pass "client pod Running" || { bad "client pod not Running"; echo "=== M2c-0 SMOKE FAILED ==="; exit 1; }

echo "=== 4. DNS resolves the Service name to its ClusterIP ==="
resolved=$(kc exec m2c-client -- nslookup whoami.default.svc.cluster.local 2>/dev/null | awk '/^Address: /{a=$2} END{print a}')
[ "$resolved" = "$cip" ] && pass "DNS whoami.default.svc.cluster.local -> $resolved" || bad "DNS resolved '$resolved' != ClusterIP '$cip'"

echo "=== 5. Service load-balances across distinct backend pods ==="
seen=$(for _ in $(seq 1 20); do
  kc exec m2c-client -- wget -qO- --timeout=5 "http://$cip:80" 2>/dev/null | awk -F'[:=]' '/Hostname/{gsub(/ /,"",$2);print $2}'
done | sort -u)
count=$(printf '%s\n' "$seen" | grep -c . )
echo "distinct backends hit: $count"; printf '%s\n' "$seen"
[ "$count" -ge 2 ] && pass "load-balanced across $count backends" || bad "only $count backend(s) answered (kube-proxy DNAT not spreading)"

kc delete pod m2c-client --ignore-not-found --wait=false >/dev/null 2>&1 || true
if [ "$fail" -eq 0 ]; then echo "=== M2c-0 SMOKE PASSED ==="; exit 0; else echo "=== M2c-0 SMOKE FAILED ===" >&2; exit 1; fi

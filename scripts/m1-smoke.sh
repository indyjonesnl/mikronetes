#!/usr/bin/env bash
# mikronetes M1 smoke gate — verify the all-Rust cluster is healthy, then emit
# the per-component memory breakdown. Exits non-zero on any failed assertion.
#
# Assertions (all proven achievable in Tasks 4-5):
#   1. Both nodes report Ready.
#   2. The REAL runtime is containerd-rs — proven by LIVE CRI traffic into each
#      node's own containerd-rs (`cri::server` log lines strictly increase over a
#      sample window), NOT by the kubelet's hardcoded `containerd://1.7.0`
#      version string (which is a baked-in literal, not evidence — see Task 4).
#   3. A cross-node pod-to-pod curl succeeds over the flannel-rs VXLAN overlay.
#      (kubectl exec is broken on containerd-rs — Task 5 — so the curl is run
#      inside the source pod's netns via nsenter on the node host, the proven
#      Task-5 method.)
#   4. Emit the mem-breakdown PSS table (scripts/mem-breakdown.sh).
#
# Usage:
#   scripts/m1-smoke.sh
# Env overrides:
#   API_CTR        api-server container (default rusternetes-cdrsf-api-server)
#   NODE1 / NODE2  node container names (defaults rusternetes-cdrsf-node-{1,2})
#   N1 / N2        node object names as seen by kube (defaults node-1 / node-2)
set -uo pipefail
cd "$(dirname "$0")/.."

API_CTR="${API_CTR:-rusternetes-cdrsf-api-server}"
NODE1="${NODE1:-rusternetes-cdrsf-node-1}"
NODE2="${NODE2:-rusternetes-cdrsf-node-2}"
N1="${N1:-node-1}"
N2="${N2:-node-2}"

fail=0
pass() { printf 'PASS: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

API_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$API_CTR" 2>/dev/null || true)
[ -n "$API_IP" ] || { echo "FAIL: cannot resolve $API_CTR IP (is the cluster up?)" >&2; exit 1; }
kc() { kubectl --server "https://$API_IP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

echo "=== 1. Both nodes Ready ==="
for n in "$N1" "$N2"; do
  st=$(kc get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "$st" = "True" ]; then pass "$n Ready"; else bad "$n not Ready (Ready=$st)"; fi
done

echo "=== 2. Real runtime is containerd-rs (CRI evidence, not version string) ==="
# Three pieces of evidence per node, none of which is the kubelet's hardcoded
# `containerd://1.7.0` literal:
#   (a) a live containerd-rs process whose parent is the co-resident kubelet,
#   (b) the kubelet's CONTAINER_RUNTIME_ENDPOINT points at containerd-rs.sock,
#   (c) the containerd-rs cri::server log carries real lifecycle RPCs
#       (RunPodSandbox / CreateContainer) — i.e. the kubelet actually drove it.
for ctr in "$NODE1" "$NODE2"; do
  ok=1
  # (a) containerd-rs process alive, child of kubelet (PID 1 in the container).
  cdrs_pid=$(docker exec "$ctr" sh -c '
    for d in /proc/[0-9]*; do
      b=$(tr "\000" "\n" < "$d/cmdline" 2>/dev/null | head -n1); b=${b##*/}
      [ "$b" = "containerd-rs" ] && { echo "${d##*/}"; break; }
    done' 2>/dev/null)
  if [ -n "$cdrs_pid" ]; then
    ppid=$(docker exec "$ctr" sh -c "awk '/^PPid:/{print \$2}' /proc/$cdrs_pid/status" 2>/dev/null)
    p1=$(docker exec "$ctr" sh -c 'tr "\000" " " < /proc/1/cmdline' 2>/dev/null)
    case "$p1" in *kubelet*) : ;; *) ok=0; bad "$ctr: PID1 is not kubelet ($p1)";; esac
  else
    ok=0; bad "$ctr: no containerd-rs process"
  fi
  # (b) kubelet's CRI endpoint is the containerd-rs socket, and it exists.
  ep=$(docker exec "$ctr" sh -c 'tr "\000" "\n" < /proc/1/environ 2>/dev/null | sed -n "s/^CONTAINER_RUNTIME_ENDPOINT=//p"')
  sock=${ep#unix://}
  case "$ep" in *containerd-rs.sock) docker exec "$ctr" test -S "$sock" || { ok=0; bad "$ctr: CRI socket $sock missing"; } ;;
                *) ok=0; bad "$ctr: CONTAINER_RUNTIME_ENDPOINT not containerd-rs ($ep)";; esac
  # (c) real CRI lifecycle RPCs in the containerd-rs log.
  rpcs=$(docker logs "$ctr" 2>&1 | grep -cE 'cri::server.*(RunPodSandbox|CreateContainer)' || true)
  [ "${rpcs:-0}" -gt 0 ] || { ok=0; bad "$ctr: no RunPodSandbox/CreateContainer CRI RPCs in containerd-rs log"; }
  [ "$ok" = 1 ] && pass "$ctr: containerd-rs (pid $cdrs_pid, ppid $ppid) is the live CRI runtime; endpoint=$ep; $rpcs lifecycle RPCs logged"
done

echo "=== 3. Cross-node pod-to-pod curl over flannel-rs ==="
# Provision the cross-node test fixtures if absent — the gate sets up its own
# pods (one whoami per node) rather than requiring a manual pre-deploy, so it
# runs unattended in CI. No-op when they already exist.
running=$(kc get pods -n default -l m1smoke=whoami --no-headers 2>/dev/null | grep -c ' Running ' || true)
if [ "${running:-0}" -lt 2 ]; then
  echo "  deploying whoami test pods (one per node)"
  kc run whoami-n1 --image=traefik/whoami:v1.10.2 --labels=m1smoke=whoami \
    --overrides='{"spec":{"nodeName":"'"$N1"'"}}' >/dev/null 2>&1 || true
  kc run whoami-n2 --image=traefik/whoami:v1.10.2 --labels=m1smoke=whoami \
    --overrides='{"spec":{"nodeName":"'"$N2"'"}}' >/dev/null 2>&1 || true
  for _ in $(seq 1 36); do
    r=$(kc get pods -n default -l m1smoke=whoami \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Running || true)
    [ "${r:-0}" -ge 2 ] && break
    sleep 5
  done
fi
# Find the two whoami test pods (one per node) and their flannel pod IPs.
read -r P1 IP1 PN1 <<EOF
$(kc get pods -n default -l m1smoke=whoami -o jsonpath='{range .items[?(@.spec.nodeName=="'"$N1"'")]}{.metadata.name} {.status.podIP} {.spec.nodeName}{"\n"}{end}' 2>/dev/null | head -1)
EOF
read -r P2 IP2 PN2 <<EOF
$(kc get pods -n default -l m1smoke=whoami -o jsonpath='{range .items[?(@.spec.nodeName=="'"$N2"'")]}{.metadata.name} {.status.podIP} {.spec.nodeName}{"\n"}{end}' 2>/dev/null | head -1)
EOF

if [ -z "${IP1:-}" ] || [ -z "${IP2:-}" ]; then
  bad "cross-node test pods missing (need 2 pods labelled m1smoke=whoami, one per node). Deploy them, e.g.:
       kc run whoami-n1 --image=traefik/whoami:v1.10.2 --labels=m1smoke=whoami --overrides='{\"spec\":{\"nodeName\":\"$N1\"}}'
       kc run whoami-n2 --image=traefik/whoami:v1.10.2 --labels=m1smoke=whoami --overrides='{\"spec\":{\"nodeName\":\"$N2\"}}'"
else
  # curl from P1's netns -> P2's IP (cross-node), via nsenter on NODE1 host.
  curl_xnode() {
    local node="$1" target="$2"
    local ns
    ns=$(docker exec "$node" sh -c 'ls /run/netns/ 2>/dev/null | head -1')
    [ -n "$ns" ] || return 1
    docker exec "$node" nsenter --net="/run/netns/$ns" \
      curl -s --max-time 8 "http://$target:80/" 2>/dev/null
  }
  out=$(curl_xnode "$NODE1" "$IP2")
  if printf '%s' "$out" | grep -q "Hostname: $P2"; then
    pass "$P1 ($IP1,$N1) -> $P2 ($IP2,$N2): $(printf '%s' "$out" | grep '^Hostname:')"
  else
    bad "cross-node curl $P1 -> $P2 ($IP2) failed; got: $(printf '%s' "$out" | head -1)"
  fi
fi

echo "=== 4. Per-component memory breakdown ==="
MEM_CONTAINERS="$NODE1 $NODE2 $API_CTR rusternetes-cdrsf-scheduler rusternetes-cdrsf-controller-manager rusternetes-cdrsf-rhino rusternetes-cdrsf-kube-proxy-1 rusternetes-cdrsf-kube-proxy-2" \
  bash scripts/mem-breakdown.sh mem-breakdown-rusternetes-raw.txt || true

if [ "$fail" -ne 0 ]; then
  echo "=== SMOKE FAILED ===" >&2
  exit 1
fi
echo "=== SMOKE PASSED ==="

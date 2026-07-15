#!/usr/bin/env bash
# Bring up the kind-style all-Rust DinD cluster and bootstrap it to
# Services-parity: 2 workers Ready + flannel-rs + a whoami Deployment/Service.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VMIP="${VMIP:-10.88.0.2}"
REGISTRY="${REGISTRY:-10.88.0.1:5000}"
RUSTERNETES_SRC="${RUSTERNETES_SRC:-/home/jones/PhpstormProjects/rusternetes}"
COMPOSE="docker compose -f $REPO_ROOT/compose.dind.yml"
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }
say() { printf '\n==> %s\n' "$*"; }

say "compose up (registry + CP + 2 workers)"
$COMPOSE up -d

say "waiting for CP api-server"
for _ in $(seq 1 90); do kc get --raw /healthz >/dev/null 2>&1 && break; sleep 2; done
kc get --raw /healthz >/dev/null 2>&1 || { echo "api-server never healthy" >&2; exit 1; }

say "seeding local registry (arch-matched) at localhost:5000"
for _ in $(seq 1 30); do curl -sf http://localhost:5000/v2/ >/dev/null 2>&1 && break; sleep 1; done
seed() { # $1=src $2=dst
  docker pull ${POD_PLATFORM:+--platform "$POD_PLATFORM"} "$1"
  docker tag "$1" "localhost:5000/$2"
  docker push "localhost:5000/$2" >/dev/null
}
for pair in "traefik/whoami:v1.10.2 whoami:v1.10.2" \
            "busybox:1.36.1 busybox:1.36.1" \
            "registry.k8s.io/pause:3.10 pause:3.10" \
            "ghcr.io/indyjonesnl/flannel-rs:v0.1.3 flannel-rs:v0.1.3"; do
  set -- $pair; seed "$1" "$2"
done

say "bootstrap: kubernetes Service + RBAC + priorityclasses"
kc apply -f "$RUSTERNETES_SRC/bootstrap-cluster.yaml"

say "waiting for workers to register"
for n in node-2 node-3; do
  for _ in $(seq 1 90); do
    [ "$(kc get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break
    sleep 2
  done
done
for n in node-2 node-3; do
  [ "$(kc get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] || {
    echo "worker $n never Ready" >&2; kc get nodes -o wide >&2; exit 1; }
done

say "assigning per-node podCIDRs + InternalIP"
patch_node() { # $1=node $2=ip $3=cidr
  kc patch node "$1" --type=merge -p "{\"spec\":{\"podCIDR\":\"$3\",\"podCIDRs\":[\"$3\"]}}"
  kc patch node "$1" --subresource=status --type=merge \
    -p "{\"status\":{\"addresses\":[{\"type\":\"InternalIP\",\"address\":\"$2\"},{\"type\":\"Hostname\",\"address\":\"$1\"}]}}"
}
patch_node node-2 10.88.0.3 10.244.1.0/24
patch_node node-3 10.88.0.4 10.244.2.0/24

say "flannel-rs DaemonSet (host-gw; point at CP + local registry)"
sed -e "s#ghcr.io/indyjonesnl/flannel-rs:v0.1.3#$REGISTRY/flannel-rs:v0.1.3#" \
    -e 's#value: "127.0.0.1"#value: "10.88.0.2"#' \
    "$REPO_ROOT/deploy/m2a/flannel-rs.yaml" | kc apply -f -

say "whoami Deployment + Service"
kc apply -f "$REPO_ROOT/deploy/dind/whoami.yaml"

say "waiting for 2 whoami pods Running + endpoints"
for _ in $(seq 1 90); do
  [ "$(kc get pods -l app=whoami --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)" -ge 2 ] && break
  sleep 3
done
[ "$(kc get pods -l app=whoami --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)" -ge 2 ] || {
  echo "fewer than 2 whoami pods Running" >&2; kc get pods -l app=whoami -o wide >&2; exit 1; }

# The Service must have BOTH pod IPs as ready endpoints before the smoke probes
# LB, else a probe racing endpoint registration sees a single backend.
say "waiting for 2 ready endpoints on the whoami Service"
eps() { kc get endpointslices -l kubernetes.io/service-name=whoami \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' 2>/dev/null | sort -u | grep -c .; }
for _ in $(seq 1 60); do [ "$(eps)" -ge 2 ] && break; sleep 3; done
[ "$(eps)" -ge 2 ] || {
  echo "whoami Service has fewer than 2 ready endpoints" >&2
  kc get endpointslices -l kubernetes.io/service-name=whoami -o wide >&2; exit 1; }

kc get nodes,pods -A -o wide || true
say "dind cluster up"

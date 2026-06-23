#!/usr/bin/env bash
# mikronetes M1 — bring up the all-Rust cluster (repeatable wrapper for Tasks 1-5).
#
# Stack: rusternetes control plane (api-server / scheduler / controller-manager
# + rhino) + 2 node-cdrs nodes, each one container running the rusternetes
# kubelet driving containerd-rs (Rust CRI) over crun (OCI runtime), with
# flannel-rs as the CNI (VXLAN overlay).
#
# Sequence (all proven in Tasks 1-5, reports in mikronetes/.superpowers/sdd/):
#   1. build rusternetes-node-cdrs:m1 if the image is missing
#   2. docker compose -f <worktree>/compose.cdrs-flannel.yml up -d
#   3. ALLOCATE_NODE_CIDRS=1 CLUSTER_CIDR=10.244.0.0/16 bootstrap-cluster.sh
#   4. kubectl apply -f deploy/flannel/flannel-rs.yaml
#
# --------------------------------------------------------------------------
# kubectl ACCESS (no host port published; api-server runs --skip-auth + TLS):
#   The compose stack does NOT publish host 6443. Reach the api-server directly
#   at its container IP on the rusternetes-network bridge with an insecure,
#   any-token client (--skip-auth makes any token map to admin):
#
#     API_IP=$(docker inspect -f \
#       '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
#       rusternetes-cdrsf-api-server)
#     kubectl --server "https://$API_IP:6443" \
#             --insecure-skip-tls-verify --token dummy get nodes
#
#   This script builds exactly such a throwaway wrapper and feeds it to the
#   bootstrap script via $KUBECTL (bootstrap otherwise assumes an in-tree
#   target/release/kubectl on localhost:6443, which this no-published-port
#   stack doesn't provide).
# --------------------------------------------------------------------------
#
# Usage:
#   scripts/m1-up.sh [rusternetes-worktree]
# Env overrides:
#   RUSTERNETES_M1   worktree path (default /home/jones/PhpstormProjects/rusternetes-m1)
#   COMPOSE_FILE     compose file basename (default compose.cdrs-flannel.yml)
#   CLUSTER_CIDR     pod CIDR for node-IPAM (default 10.244.0.0/16)
#   NODE_IMAGE       node image tag (default rusternetes-node-cdrs:m1)
set -euo pipefail

RUSTERNETES_M1="${1:-${RUSTERNETES_M1:-/home/jones/PhpstormProjects/rusternetes-m1}}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.cdrs-flannel.yml}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.244.0.0/16}"
NODE_IMAGE="${NODE_IMAGE:-rusternetes-node-cdrs:m1}"
API_CTR="rusternetes-cdrsf-api-server"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$RUSTERNETES_M1" ]                      || die "worktree not found: $RUSTERNETES_M1"
[ -f "$RUSTERNETES_M1/$COMPOSE_FILE" ]         || die "compose file not found: $RUSTERNETES_M1/$COMPOSE_FILE"
[ -f "$RUSTERNETES_M1/deploy/flannel/flannel-rs.yaml" ] || die "flannel-rs.yaml not found in worktree"
command -v docker >/dev/null                  || die "docker not on PATH"
command -v kubectl >/dev/null                 || die "kubectl not on PATH"

cd "$RUSTERNETES_M1"

# Both node-1 and the kubelet share KUBELET_VOLUMES_PATH (rshared mount).
export KUBELET_VOLUMES_PATH="${KUBELET_VOLUMES_PATH:-$RUSTERNETES_M1/.rusternetes/volumes}"
mkdir -p "$KUBELET_VOLUMES_PATH"

# 1. Build the node-cdrs image if missing (Task 1 recipe, from repo root).
if ! docker image inspect "$NODE_IMAGE" >/dev/null 2>&1; then
  say "node image $NODE_IMAGE missing — building (deploy/node-cdrs/Dockerfile)"
  docker build -f deploy/node-cdrs/Dockerfile -t "$NODE_IMAGE" .
else
  say "node image $NODE_IMAGE present — skipping build"
fi

# 2. Reconcile the compose stack (idempotent; no destructive teardown).
say "docker compose -f $COMPOSE_FILE up -d"
docker compose -f "$COMPOSE_FILE" up -d

# Discover the api-server container IP for the kubectl wrapper.
say "waiting for $API_CTR to get an IP on rusternetes-network"
API_IP=""
for _ in $(seq 1 30); do
  API_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$API_CTR" 2>/dev/null || true)
  [ -n "$API_IP" ] && break
  sleep 2
done
[ -n "$API_IP" ] || die "could not resolve $API_CTR IP"
say "api-server reachable at https://$API_IP:6443"

# Throwaway kubectl wrapper: rewrite --server to the container IP + inject a
# dummy token (api-server runs --skip-auth). Bootstrap consumes it via $KUBECTL.
KCTL_WRAP="$(mktemp)"
cat > "$KCTL_WRAP" <<EOF
#!/usr/bin/env bash
exec kubectl --server "https://$API_IP:6443" --insecure-skip-tls-verify --token dummy "\$@"
EOF
chmod +x "$KCTL_WRAP"
trap 'rm -f "$KCTL_WRAP"' EXIT

# Wait for the api-server to actually answer before bootstrapping.
say "waiting for api-server to answer /readyz"
for _ in $(seq 1 30); do
  "$KCTL_WRAP" get --raw='/readyz' >/dev/null 2>&1 && break
  sleep 2
done

# 3. Bootstrap with node-IPAM (Task 4 recipe).
say "bootstrap-cluster.sh (ALLOCATE_NODE_CIDRS=1 CLUSTER_CIDR=$CLUSTER_CIDR)"
KUBECTL="$KCTL_WRAP" KUBECONFIG=/dev/null \
  ALLOCATE_NODE_CIDRS=1 CLUSTER_CIDR="$CLUSTER_CIDR" \
  bash scripts/bootstrap-cluster.sh docker

# 4. Apply flannel-rs (Task 5: the committed manifest already carries the
#    privileged + DirectoryOrCreate fixes).
say "kubectl apply -f deploy/flannel/flannel-rs.yaml"
"$KCTL_WRAP" apply -f deploy/flannel/flannel-rs.yaml

say "M1 cluster up. Verify + measure with: mikronetes/scripts/m1-smoke.sh"
say "kubectl: kubectl --server https://$API_IP:6443 --insecure-skip-tls-verify --token dummy get nodes -o wide"

#!/usr/bin/env bash
# M2c-0 bootstrap: on top of the M2b data plane, stand up the cluster system
# Services (kubernetes @10.96.0.1, kube-dns @10.96.0.10) + the native
# rusternetes-dns Deployment, then front the whoami pods with a ClusterIP
# Service — so kube-proxy load-balancing and DNS-by-name can be proven.
#
# Order matters: bootstrap-cluster.yaml must be applied BEFORE any workload
# Service, or whoami grabs 10.96.0.1 and the pinned `kubernetes` Service fails
# to allocate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMIP="${VMIP:-10.88.0.2}"
RUSTERNETES_SRC="${RUSTERNETES_SRC:-/home/jones/PhpstormProjects/rusternetes}"
RUSTERNETES_PARENT="$(dirname "$RUSTERNETES_SRC")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5000}"
REGISTRY_ENDPOINT="${REGISTRY_ENDPOINT:-10.88.0.1:${REGISTRY_HOST_PORT}}"
DNS_IMAGE_TAG="${DNS_IMAGE_TAG:-rusternetes-dns:m2c}"

say() { printf '\n==> %s\n' "$*"; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

# ---------------------------------------------------------------------------
# 1. M2b data plane: per-node podCIDRs, flannel host-gw, whoami PODS (no
#    Services yet), cross-node probes.
# ---------------------------------------------------------------------------
bash "$SCRIPT_DIR/m2b-bootstrap.sh"

# ---------------------------------------------------------------------------
# 2. rusternetes-dns image: build (musl, if missing) and mirror into the local
#    registry so containerd-rs can pull it. rusternetes/dns.Dockerfile is stale
#    (COPYs a removed netstack crate), so we build via the mikronetes musl
#    Dockerfile that COPYs crates wholesale.
# ---------------------------------------------------------------------------
say "ensuring rusternetes-dns image in the local registry"
if ! docker image inspect "$DNS_IMAGE_TAG" >/dev/null 2>&1; then
  docker build \
    -f "$REPO_ROOT/deploy/m2a/rusternetes-dns-musl.Dockerfile" \
    -t "$DNS_IMAGE_TAG" \
    "$RUSTERNETES_PARENT"
fi
docker tag "$DNS_IMAGE_TAG" "localhost:${REGISTRY_HOST_PORT}/rusternetes-dns:m2c"
docker push "localhost:${REGISTRY_HOST_PORT}/rusternetes-dns:m2c" >/dev/null

# ---------------------------------------------------------------------------
# 3. System Services + RBAC + namespaces (kubernetes @.1, kube-dns @.10).
#    MUST precede the whoami Service so .1 is reserved for `kubernetes`.
# ---------------------------------------------------------------------------
say "applying cluster bootstrap (kubernetes @10.96.0.1, kube-dns @10.96.0.10)"
kc apply -f "$RUSTERNETES_SRC/bootstrap-cluster.yaml"

# ---------------------------------------------------------------------------
# 4. Native DNS Deployment. The image is arg-free (ENTRYPOINT) -> in-cluster
#    config. Patch the manifest image ref to the local registry.
# ---------------------------------------------------------------------------
say "applying rusternetes-dns Deployment"
sed "s#image: rusternetes-dns:latest#image: ${REGISTRY_ENDPOINT}/rusternetes-dns:m2c#" \
  "$RUSTERNETES_SRC/bootstrap-dns.yaml" | kc apply -f -

say "waiting for rusternetes-dns Deployment Ready + kube-dns endpoints"
ok=0
for _ in $(seq 1 60); do
  r=$(kc get deploy rusternetes-dns -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  eps=$(kc get endpointslice -n kube-system -l kubernetes.io/service-name=kube-dns \
        -o jsonpath='{.items[*].endpoints[*].addresses[0]}' 2>/dev/null | wc -w)
  if [ "${r:-0}" = 1 ] && [ "${eps:-0}" -ge 1 ]; then ok=1; break; fi
  sleep 3
done
[ "$ok" = 1 ] || { kc get pods -n kube-system -o wide || true; echo "ERROR: rusternetes-dns not Ready" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. Taint node-1 (control-plane holds no workload pods) + front whoami.
# ---------------------------------------------------------------------------
say "tainting node-1 NoSchedule"
kc taint node node-1 node-role.kubernetes.io/control-plane=:NoSchedule --overwrite

say "creating ClusterIP Service 'whoami' over the m2b whoami pods"
kc apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: m2b-whoami
  ports:
  - name: http
    port: 80
    targetPort: 80
YAML

say "waiting for whoami ClusterIP + endpoints"
for _ in $(seq 1 30); do
  cip=$(kc get svc whoami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo)
  [ -n "$cip" ] && [ "$cip" != "None" ] && break
  sleep 2
done
say "whoami ClusterIP=$cip (must NOT be 10.96.0.1 — that is the kubernetes Service)"
kc get svc -A -o wide 2>/dev/null || true
say "m2c-0 bootstrap complete"

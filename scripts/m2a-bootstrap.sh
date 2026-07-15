#!/usr/bin/env bash
# M2a post-boot bootstrap: cluster resources + CNI DaemonSet + whoami test pod.
#
# Run after scripts/m2a-up.sh confirms node-1 Ready.
# Expected: CNI DS Ready ≥1 and whoami Running.
#
# Usage: bash scripts/m2a-bootstrap.sh
#
# Env overrides:
#   VMIP          VM api-server IP (default: 10.88.0.2)
#   RUSTERNETES_M1  path to rusternetes-m1 checkout (default: /home/jones/PhpstormProjects/rusternetes-m1)
#   CNI_PLUGIN    flannel-rs (default). calico-rs can be added as another case.
#   FLANNEL_IMAGE_SOURCE source image mirrored to 10.88.0.1:5000/flannel-rs:v0.1.3
#   WHOAMI_IMAGE_SOURCE  source image mirrored to 10.88.0.1:5000/whoami:v1.10.2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
M1="${RUSTERNETES_M1:-/home/jones/PhpstormProjects/rusternetes-m1}"
VMIP="${VMIP:-10.88.0.2}"
CNI_PLUGIN="${CNI_PLUGIN:-flannel-rs}"
FLANNEL_IMAGE_SOURCE="${FLANNEL_IMAGE_SOURCE:-ghcr.io/indyjonesnl/flannel-rs:v0.1.3}"
WHOAMI_IMAGE_SOURCE="${WHOAMI_IMAGE_SOURCE:-traefik/whoami:v1.10.2}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "$CNI_PLUGIN" in
    flannel-rs)
        CNI_NAME="flannel-rs"
        CNI_NAMESPACE="kube-flannel"
        CNI_DAEMONSET="kube-flannel-ds"
        CNI_MANIFEST="$REPO_ROOT/deploy/m2a/flannel-rs.yaml"
        CNI_POD_JSONPATH='{.items[0].metadata.name}'
        ;;
    calico-rs)
        die "CNI_PLUGIN=calico-rs is recognized but no M2a calico-rs manifest is wired yet"
        ;;
    *)
        die "unsupported CNI_PLUGIN '$CNI_PLUGIN' (supported: flannel-rs)"
        ;;
esac

kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

ensure_registry_image() {
    local src="$1"
    local dst="$2"
    docker image inspect "$src" >/dev/null 2>&1 || docker pull "$src"
    docker tag "$src" "localhost:5000/${dst}"
    docker push "localhost:5000/${dst}" >/dev/null
}

ensure_local_registry() {
    if ! docker ps --format '{{.Names}}' | grep -qx m2a-registry; then
        if docker ps -a --format '{{.Names}}' | grep -qx m2a-registry; then
            docker start m2a-registry >/dev/null
        else
            docker run -d --restart unless-stopped --name m2a-registry -p 5000:5000 registry:2 >/dev/null
        fi
    fi

    say "mirroring M2a images into local registry"
    ensure_registry_image "$FLANNEL_IMAGE_SOURCE" "flannel-rs:v0.1.3"
    ensure_registry_image "$WHOAMI_IMAGE_SOURCE" "whoami:v1.10.2"
}

ensure_local_registry

say "verifying node-1 Ready"
st=$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
[ "$st" = "True" ] || die "node-1 not Ready (got: '${st}'). Run scripts/m2a-up.sh first."

# Step 1 — Patch node-1's InternalIP to the VM's real address.
# The rusternetes kubelet detects InternalIP by resolving $HOSTNAME; in the VM
# that resolves to 127.0.0.1 (loopback). flannel-rs uses InternalIP as its
# public_ip for host-gw routing and VTEP registration — 127.0.0.1 is wrong.
# Patch it to the actual VM network IP before applying flannel.
say "patching node-1 InternalIP to $VMIP"
kc patch node node-1 --type=merge --patch "{
  \"status\": {
    \"addresses\": [
      {\"type\": \"InternalIP\", \"address\": \"$VMIP\"},
      {\"type\": \"Hostname\",   \"address\": \"node-1\"}
    ]
  }
}" 2>/dev/null || true
# Verify patch applied (the api-server may ignore status subresource patches
# without the /status suffix; try the subresource path if available).
kc patch node node-1 --subresource=status --type=merge --patch "{
  \"status\": {
    \"addresses\": [
      {\"type\": \"InternalIP\", \"address\": \"$VMIP\"},
      {\"type\": \"Hostname\",   \"address\": \"node-1\"}
    ]
  }
}" 2>/dev/null || true
ip_got=$(kc get node node-1 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
say "node-1 InternalIP after patch: '${ip_got}'"

# Step 2 — Cluster resources the all-in-one doesn't self-create.
# (kubernetes Service 10.96.0.1, kube-dns Service 10.96.0.10, PriorityClasses,
# RBAC for scheduler + controller-manager, flannel ServiceAccount + RBAC.)
# Idempotent: already-existing resources are a no-op.
say "applying cluster bootstrap resources"
if [ -f "$M1/bootstrap-cluster.yaml" ]; then
    kc apply -f "$M1/bootstrap-cluster.yaml" || true
else
    say "WARNING: $M1/bootstrap-cluster.yaml not found; skipping"
fi

# Step 2b — Patch node-1's podCIDR.
# rusternetes all-in-one has node_ipam=None (no IPAM allocator in single-node
# mode). flannel-rs requires spec.podCIDR to assign a subnet. Patch it to the
# first /24 of the flannel Network (10.244.0.0/16).
say "patching node-1 spec.podCIDR = 10.244.0.0/24"
kc patch node node-1 --type=merge --patch \
    '{"spec":{"podCIDR":"10.244.0.0/24","podCIDRs":["10.244.0.0/24"]}}' 2>/dev/null || true
cidr_got=$(kc get node node-1 -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "")
say "node-1 podCIDR after patch: '${cidr_got}'"

# Step 3 — flannel DaemonSet (M2a variant).
# Key differences from M1's flannel-rs.yaml:
#   - vxlan backend: proven for M2a single-node smoke. host-gw exists in
#     flannel-rs v0.1.3 but is not needed for this path.
#   - KUBERNETES_SERVICE_HOST=127.0.0.1 (not 10.88.0.2): rusternetes generates
#     a self-signed TLS cert with SANs [localhost, 127.0.0.1] only; the node IP
#     10.88.0.2 is not in the SANs and rustls would reject it. flannel runs with
#     hostNetwork=true so 127.0.0.1 is the node's loopback (reachable).
#   - CNI conflist + binaries pre-placed in initramfs (no initContainer needed)
#   - containerd-rs DirectoryOrCreate may be unavailable → run volume
#     pre-exists via rusternetes check_host_path_type + create_dir_all
say "applying $CNI_NAME DaemonSet (M2a variant)"
kc apply -f "$CNI_MANIFEST"

say "waiting for $CNI_NAME DS Ready (up to 5 min)"
ok=0
for _ in $(seq 1 60); do
    r=$(kc get ds -n "$CNI_NAMESPACE" "$CNI_DAEMONSET" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    [ "${r:-0}" -ge 1 ] && ok=1 && break
    sleep 5
done

if [ "$ok" != 1 ]; then
    say "$CNI_NAME not ready after 5 min; showing state for debugging:"
    kc describe ds -n "$CNI_NAMESPACE" "$CNI_DAEMONSET" 2>/dev/null || true
    kc get pods -n "$CNI_NAMESPACE" -o wide 2>/dev/null || true
    cni_pod=$(kc get pods -n "$CNI_NAMESPACE" -o jsonpath="$CNI_POD_JSONPATH" 2>/dev/null || echo "")
    if [ -n "$cni_pod" ]; then
        say "=== $CNI_NAME pod events ==="
        kc describe pod -n "$CNI_NAMESPACE" "$cni_pod" 2>/dev/null || true
        say "=== $CNI_NAME logs ==="
        kc logs -n "$CNI_NAMESPACE" "$cni_pod" 2>/dev/null || true
    fi
    die "$CNI_NAME DS not Ready; see above for diagnostics"
fi
say "$CNI_NAME DS Ready"

# Step 4 — the whoami test pod.
say "launching whoami test pod"
# M2a: use local registry mirror — no NAT in the VM, Docker Hub is unreachable.
# 10.88.0.1:5000/whoami:v1.10.2 is the host bridge registry (HTTP, in containerd-rs insecure list).
kc run whoami --image=10.88.0.1:5000/whoami:v1.10.2 --labels=m2a=whoami 2>/dev/null || true

say "waiting for whoami Running (up to 5 min)"
ok=0
for _ in $(seq 1 60); do
    ph=$(kc get pod whoami -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$ph" = "Running" ] && ok=1 && break
    sleep 5
done

if [ "$ok" != 1 ]; then
    say "whoami pod not Running; showing state:"
    kc describe pod whoami 2>/dev/null || true
    kc get pod whoami -o wide 2>/dev/null || true
    die "whoami pod never reached Running"
fi

say "whoami Running"
kc get pod whoami -o wide

# Step 5 — Verify pod reachability.
pod_ip=$(kc get pod whoami -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
say "whoami pod IP: ${pod_ip}"
if [ -n "$pod_ip" ]; then
    say "curl whoami from host (via VM tap bridge):"
    curl -sf --max-time 5 "http://${pod_ip}:80" 2>/dev/null \
        && say "curl OK" \
        || say "curl failed (pod IP may not be routable from host; check pod logs instead)"

    say "verifying whoami is reachable from host via pod CIDR route:"
    curl -sf --max-time 5 "http://${pod_ip}:80" >/dev/null \
        && say "host-to-pod curl OK" \
        || die "host-to-pod curl failed"
fi

say "bootstrap complete"
say "summary:"
kc get node node-1 -o wide
kc get pods --all-namespaces -o wide

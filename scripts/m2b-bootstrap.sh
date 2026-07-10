#!/usr/bin/env bash
# M2b post-boot bootstrap: node addresses, pod CIDRs, CNI, pinned smoke pods.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${OUT:-$REPO_ROOT/out/m2b}"
VMIP="${VMIP:-10.88.0.2}"
CNI_PLUGIN="${CNI_PLUGIN:-flannel-rs}"
FLANNEL_IMAGE_SOURCE="${FLANNEL_IMAGE_SOURCE:-ghcr.io/indyjonesnl/flannel-rs:v0.1.3}"
WHOAMI_IMAGE_SOURCE="${WHOAMI_IMAGE_SOURCE:-traefik/whoami:v1.10.2}"
BUSYBOX_IMAGE_SOURCE="${BUSYBOX_IMAGE_SOURCE:-busybox:1.36.1}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5000}"
REGISTRY_ENDPOINT="${REGISTRY_ENDPOINT:-10.88.0.1:${REGISTRY_HOST_PORT}}"
# Platform for the externally-sourced pod/CNI image mirror pulls (busybox,
# whoami, flannel-rs). Default linux/amd64 == today's host-arch pull; set
# POD_PLATFORM=linux/arm64 so the arm64 manifests land in the local registry.
POD_PLATFORM="${POD_PLATFORM:-linux/amd64}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

ensure_registry_image() {
  local src="$1"
  local dst="$2"
  docker image inspect "$src" >/dev/null 2>&1 || docker pull --platform "$POD_PLATFORM" "$src"
  docker tag "$src" "localhost:${REGISTRY_HOST_PORT}/${dst}"
  docker push "localhost:${REGISTRY_HOST_PORT}/${dst}" >/dev/null
}

ensure_local_registry() {
  if docker ps -a --format '{{.Names}}' | grep -qx m2a-registry; then
    if ! docker port m2a-registry 5000/tcp | grep -q ":${REGISTRY_HOST_PORT}$"; then
      docker rm -f m2a-registry >/dev/null
    fi
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx m2a-registry; then
    if docker ps -a --format '{{.Names}}' | grep -qx m2a-registry; then
      docker start m2a-registry >/dev/null
    else
      docker run -d --restart unless-stopped --name m2a-registry -p "${REGISTRY_HOST_PORT}:5000" registry:2 >/dev/null
    fi
  fi

  say "mirroring M2b images into local registry"
  ensure_registry_image "$FLANNEL_IMAGE_SOURCE" "flannel-rs:v0.1.3"
  ensure_registry_image "$WHOAMI_IMAGE_SOURCE" "whoami:v1.10.2"
  ensure_registry_image "$BUSYBOX_IMAGE_SOURCE" "busybox:1.36.1"
}

patch_node() {
  local node="$1"
  local ip="$2"
  local cidr="$3"

  say "patching $node InternalIP=$ip podCIDR=$cidr"
  kc patch node "$node" --type=merge --patch "{
    \"status\": {
      \"addresses\": [
        {\"type\": \"InternalIP\", \"address\": \"${ip}\"},
        {\"type\": \"Hostname\", \"address\": \"${node}\"}
      ]
    }
  }" >/dev/null 2>&1 || true
  kc patch node "$node" --subresource=status --type=merge --patch "{
    \"status\": {
      \"addresses\": [
        {\"type\": \"InternalIP\", \"address\": \"${ip}\"},
        {\"type\": \"Hostname\", \"address\": \"${node}\"}
      ]
    }
  }" >/dev/null 2>&1 || true
  kc patch node "$node" --type=merge --patch \
    "{\"spec\":{\"podCIDR\":\"${cidr}\",\"podCIDRs\":[\"${cidr}\"]}}" >/dev/null
}

ensure_local_registry

say "verifying all nodes are Ready"
for node in node-1 node-2 node-3 node-4; do
  st=$(kc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [ "$st" = True ] || die "$node not Ready (got '$st')"
done

patch_node node-1 10.88.0.2 10.244.0.0/24
patch_node node-2 10.88.0.3 10.244.1.0/24
patch_node node-3 10.88.0.4 10.244.2.0/24
patch_node node-4 10.88.0.5 10.244.3.0/24

say "applying bootstrap cluster resources"
if [ -f /home/jones/PhpstormProjects/rusternetes-m1/deploy/bootstrap-cluster.yaml ]; then
  kc apply -f /home/jones/PhpstormProjects/rusternetes-m1/deploy/bootstrap-cluster.yaml >/dev/null
fi

case "$CNI_PLUGIN" in
  flannel-rs)
    say "applying flannel-rs DaemonSet for M2b"
    tmp="$OUT/flannel-rs-m2b.yaml"
    mkdir -p "$OUT"
    sed \
      -e 's/value: "127.0.0.1"/value: "10.88.0.2"/' \
      -e "s#image: 10.88.0.1:5000/flannel-rs:v[0-9.]*#image: ${REGISTRY_ENDPOINT}/flannel-rs:v0.1.3#" \
      "$REPO_ROOT/deploy/m2a/flannel-rs.yaml" > "$tmp"
    kc apply -f "$tmp" >/dev/null
    ;;
  calico-rs)
    die "CNI_PLUGIN=calico-rs is recognized but no M2b calico-rs manifest is wired yet"
    ;;
  *)
    die "unsupported CNI_PLUGIN '$CNI_PLUGIN'"
    ;;
esac

say "waiting for CNI DaemonSet Ready on all four nodes"
ok=0
for _ in $(seq 1 90); do
  ready=$(kc get ds -n kube-flannel kube-flannel-ds -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
  [ "${ready:-0}" -ge 4 ] && ok=1 && break
  sleep 5
done
[ "$ok" = 1 ] || {
  kc get pods -n kube-flannel -o wide || true
  die "flannel-rs DaemonSet not Ready on all nodes"
}

say "creating one whoami pod per node"
for node in node-1 node-2 node-3 node-4; do
  pod="whoami-${node}"
  kc delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels:
    app: m2b-whoami
spec:
  nodeName: ${node}
  restartPolicy: Always
  containers:
  - name: whoami
    image: ${REGISTRY_ENDPOINT}/whoami:v1.10.2
    imagePullPolicy: IfNotPresent
YAML
done

say "waiting for whoami pods"
for pod in whoami-node-1 whoami-node-2 whoami-node-3 whoami-node-4; do
  ok=0
  for _ in $(seq 1 60); do
    ph=$(kc get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$ph" = Running ] && ok=1 && break
    sleep 5
  done
  [ "$ok" = 1 ] || die "$pod not Running"
done

say "creating cross-node pod-to-pod probes"
ip2=$(kc get pod whoami-node-2 -o jsonpath='{.status.podIP}')
ip3=$(kc get pod whoami-node-3 -o jsonpath='{.status.podIP}')
ip4=$(kc get pod whoami-node-4 -o jsonpath='{.status.podIP}')
for spec in "node-1:$ip2" "node-2:$ip3" "node-3:$ip4" "node-4:$ip2"; do
  node="${spec%%:*}"
  target="${spec#*:}"
  pod="curl-${node}"
  kc delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels:
    app: m2b-curl
spec:
  nodeName: ${node}
  restartPolicy: Never
  containers:
  - name: curl
    image: ${REGISTRY_ENDPOINT}/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "wget -qO- --timeout=10 http://${target}:80 | grep -q Hostname:"]
YAML
done

say "bootstrap complete"
kc get nodes -o wide
kc get pods -o wide

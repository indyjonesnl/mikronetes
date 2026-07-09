#!/usr/bin/env bash
# Build four M2b node images with per-node /boot/config.yaml payloads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MR="${MACHINED_RS:-/home/jones/PhpstormProjects/machined-rs}"
OUT="${OUT:-$REPO_ROOT/out/m2b}"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/machined-rs-build}"
export CARGO_TARGET_DIR

mkdir -p "$OUT/boot"

echo "==> generating M2b configs"
OUT="$OUT" bash "$SCRIPT_DIR/m2b-generate-configs.sh"

echo "==> building machined-imager + machinectl (host)"
( cd "$MR" && cargo build --release -p machined-imager -p machinectl )
IMAGER="$CARGO_TARGET_DIR/release/machined-imager"

echo "==> building musl-static machined"
( cd "$MR" && make dist-x86_64 )
MACHINED="$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/release/machined"
[ -f "$MACHINED" ] || { echo "ERROR: musl machined not found at $MACHINED" >&2; exit 1; }

PKI_DIR="$OUT/pki"
if [[ -f "$PKI_DIR/ca.pem" && -f "$PKI_DIR/ca.key" && \
      -f "$PKI_DIR/server.pem" && -f "$PKI_DIR/server.key" ]]; then
  echo "==> PKI already present"
else
  echo "==> generating shared M2b machined PKI"
  "$IMAGER" gen-pki --out "$PKI_DIR"
fi

# M2b overlays provide containerd-rs, crun, and CNI plugins on /boot.
# Filter the generic machined runtime artifacts out of the imager manifest.
MICROVM_MANIFEST="$OUT/artifacts-microvm.toml"
sed '/{ name = "\(containerd\|runc\|cni-plugins\)"/d' \
  "$MR/crates/imager/artifacts.toml" > "$MICROVM_MANIFEST"

ROLE_OVERLAYS="$OUT/role-overlays"
CONTROL_OVERLAY="$ROLE_OVERLAYS/control-plane"
WORKER_OVERLAY="$ROLE_OVERLAYS/worker"

echo "==> assembling shared control-plane overlay"
CONFIG_PATH="$OUT/configs/node-1.yaml" OUT="$CONTROL_OVERLAY" \
  bash "$SCRIPT_DIR/m2a-build-overlay.sh"

echo "==> assembling shared worker overlay"
CONFIG_PATH="$OUT/configs/node-2.yaml" \
  KUBECONFIG_PATH="$OUT/configs/kubelet.kubeconfig" \
  REQUIRE_KUBELET=1 \
  OUT="$WORKER_OVERLAY" \
  bash "$SCRIPT_DIR/m2a-build-overlay.sh"
[ -x "$WORKER_OVERLAY/bin/kubelet" ] || {
  echo "ERROR: $WORKER_OVERLAY/bin/kubelet missing; rebuild mikronetes-kubelet:m2b with updated Dockerfile" >&2
  exit 1
}

prepare_node_overlay() {
  local node="$1"
  local overlay="$2"
  local config="$3"
  local template

  if [ "$node" = node-1 ]; then
    template="$CONTROL_OVERLAY"
  else
    template="$WORKER_OVERLAY"
  fi

  rm -rf "$overlay"
  mkdir -p "$overlay"
  cp -a "$template/." "$overlay/"
  cp "$config" "$overlay/config.yaml"
  if [ "$node" != node-1 ]; then
    cp "$OUT/configs/kubelet.kubeconfig" "$overlay/kubelet.kubeconfig"
  fi
}

build_node() {
  local node="$1"
  local node_dir="$OUT/$node"
  local overlay="$node_dir/overlay"
  local config="$OUT/configs/${node}.yaml"
  mkdir -p "$node_dir"

  echo "==> preparing overlay for $node"
  prepare_node_overlay "$node" "$overlay" "$config"

  echo "==> building image for $node"
  "$IMAGER" build \
    --arch x86_64 \
    --image-id "m2b-${node}" \
    --machined "$MACHINED" \
    --config "$config" \
    --overlay "$overlay" \
    --pki-dir "$PKI_DIR" \
    --emit-boot "$OUT/boot" \
    --out "$node_dir/m2b.img" \
    --manifest "$MICROVM_MANIFEST" \
    --cache "$OUT/imager-cache"
}

for node in node-1 node-2 node-3 node-4; do
  build_node "$node"
done

echo ""
echo "built M2b images:"
ls -lh "$OUT"/node-*/m2b.img "$OUT/boot/vmlinuz" "$OUT/boot/initramfs.img"

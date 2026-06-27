#!/usr/bin/env bash
# Assembles out/overlay/ — the payload tree baked onto /boot by machined's imager
# via the --overlay flag. Overlay contains the full Rust stack binaries, CNI plugins,
# bootstrap CNI conflist, and containerd-rs config. Consumed by Task D2's image build.
#
# Usage: bash scripts/m2a-build-overlay.sh
#
# Env overrides:
#   RUSTERNETES_M1  — path to the rusternetes-m1 worktree (default: /home/jones/PhpstormProjects/rusternetes-m1)
#   RUSTERNETES_SRC — path to the canonical rusternetes checkout (default: /home/jones/PhpstormProjects/rusternetes)
#   OUT             — output overlay dir (default: <repo-root>/out/overlay)
#   IMAGE_TAG       — unused (no GHCR all-in-one image exists); kept for compat
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

M1="${RUSTERNETES_M1:-/home/jones/PhpstormProjects/rusternetes-m1}"
# Canonical rusternetes checkout (NOT rusternetes-m1). Dockerfile.all-in-one
# requires the PARENT dir as build context so rusternetes/rhino is accessible.
RUSTERNETES_SRC="${RUSTERNETES_SRC:-/home/jones/PhpstormProjects/rusternetes}"
RUSTERNETES_PARENT="$(dirname "$RUSTERNETES_SRC")"

OUT="${OUT:-$REPO_ROOT/out/overlay}"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/cni/bin" "$OUT/cni/conf" "$OUT/pki"

# ---------------------------------------------------------------------------
# rusternetes all-in-one — musl-static binary from Dockerfile.all-in-one.
#
# There is NO GHCR all-in-one image; /app/rusternetes is produced ONLY by
# Dockerfile.all-in-one. Build context is the PARENT of rusternetes/ so the
# rhino crate path (../../rhino from crates/storage) resolves correctly.
# Cache the image; skip rebuild when it already exists (multi-minute compile).
# ---------------------------------------------------------------------------
AIO_IMAGE="mikronetes-aio:m2a"
# deploy/m2a/Dockerfile.all-in-one-musl is a mikronetes-local variant of
# rusternetes/Dockerfile.all-in-one that:
#   - Uses rust:1.95-alpine (musl toolchain) so the output is musl-statically
#     linked — required for the Alpine/musl initramfs.
#   - Fixes upstream bug: adds test_support to the dummy stub block
#     (missing from rusternetes/Dockerfile.all-in-one; causes "no targets
#     specified in the manifest" at cargo build time).
# Build context is the PARENT of rusternetes/ (same as upstream) so
# rusternetes/rhino/ is accessible from the Dockerfile's COPY instructions.
AIO_DOCKERFILE="$REPO_ROOT/deploy/m2a/Dockerfile.all-in-one-musl"
if docker image inspect "$AIO_IMAGE" >/dev/null 2>&1; then
    echo "==> all-in-one image $AIO_IMAGE already present — skipping build"
else
    echo "==> building musl-static all-in-one"
    echo "    dockerfile: $AIO_DOCKERFILE"
    echo "    build context: $RUSTERNETES_PARENT"
    docker build \
        -f "$AIO_DOCKERFILE" \
        -t "$AIO_IMAGE" \
        "$RUSTERNETES_PARENT"
fi
cid=$(docker create "$AIO_IMAGE")
docker cp "$cid:/app/rusternetes" "$OUT/bin/rusternetes"
docker rm "$cid" >/dev/null

# ---------------------------------------------------------------------------
# containerd-rs — pre-built musl-static binary from the M1 node-cdrs image.
# ---------------------------------------------------------------------------
echo "==> copying containerd-rs from $M1/deploy/node-cdrs/bin/containerd-rs"
install -m0755 "$M1/deploy/node-cdrs/bin/containerd-rs" "$OUT/bin/containerd-rs"

# ---------------------------------------------------------------------------
# crun (static) + runc symlink (containerd-rs execs "runc" by default).
# Cache: skip download if already at target checksum path.
# ---------------------------------------------------------------------------
CRUN_URL="https://github.com/containers/crun/releases/download/1.28/crun-1.28-linux-amd64"
if [[ ! -x "$OUT/bin/crun" ]]; then
    echo "==> downloading crun 1.28"
    curl -fsSL -o "$OUT/bin/crun" "$CRUN_URL"
    chmod +x "$OUT/bin/crun"
fi
ln -sf crun "$OUT/bin/runc"

# ---------------------------------------------------------------------------
# CNI plugins v1.9.1 (bridge, host-local, loopback, portmap) + flannel CNI v1.9.1-flannel1.
# ---------------------------------------------------------------------------
echo "==> downloading CNI plugins v1.9.1 + flannel CNI v1.9.1-flannel1"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

CNI_URL="https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-amd64-v1.9.1.tgz"
curl -fsSL "$CNI_URL" | tar -xz -C "$tmp"
install -m0755 "$tmp/bridge"     "$OUT/cni/bin/bridge"
install -m0755 "$tmp/host-local" "$OUT/cni/bin/host-local"
install -m0755 "$tmp/loopback"   "$OUT/cni/bin/loopback"
install -m0755 "$tmp/portmap"    "$OUT/cni/bin/portmap"

FLANNEL_URL="https://github.com/flannel-io/cni-plugin/releases/download/v1.9.1-flannel1/cni-plugin-flannel-linux-amd64-v1.9.1.tgz"
curl -fsSL "$FLANNEL_URL" | tar -xz -C "$tmp"
# The archive extracts to flannel-amd64 (not cni-plugin).
install -m0755 "$tmp/flannel-amd64" "$OUT/cni/bin/flannel"

# ---------------------------------------------------------------------------
# Bootstrap CNI conflist — baked at /boot/cni/conf so boot-time sandboxes
# (including the flannel DaemonSet pod itself) succeed before flannel installs
# its own conflist. containerd-rs v0.1.3 invokes CNI for EVERY RunPodSandbox
# including hostNetwork=true; without a conflist at cni_conf_dir, all fail.
# ---------------------------------------------------------------------------
cat > "$OUT/cni/conf/10-bootstrap-bridge.conflist" <<'JSON'
{ "cniVersion": "0.3.1", "name": "bootstrap", "plugins": [
  { "type": "bridge", "bridge": "cni0", "isGateway": true, "ipMasq": true,
    "ipam": { "type": "host-local", "subnet": "10.244.0.0/24",
              "routes": [ { "dst": "0.0.0.0/0" } ] } } ] }
JSON

# ---------------------------------------------------------------------------
# Machine config + containerd-rs config (from deploy/m2a).
# config.yaml is written by Task D1; skip that copy until D1 is done.
# config-containerd-rs.toml is created in this task, copy it now.
# ---------------------------------------------------------------------------
cp "$REPO_ROOT/deploy/m2a/config.yaml" "$OUT/config.yaml"
cp "$REPO_ROOT/deploy/m2a/config-containerd-rs.toml" "$OUT/config-containerd-rs.toml"

echo ""
echo "overlay assembled at $OUT"
find "$OUT" \( -type f -o -type l \) | sort

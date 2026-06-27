#!/usr/bin/env bash
# Builds the bootable M2a node image:
#   1. Assembles out/overlay/ (binaries + config) via m2a-build-overlay.sh.
#   2. Builds the host tools (machined-imager, machinectl) + the musl machined
#      (PID 1 in the Alpine/musl initramfs) via `make dist-x86_64`.
#   3. Generates node PKI (gen-pki).
#   4. Runs `machined-imager build` to produce:
#        out/m2a.img         — sparse GPT disk w/ FAT /boot carrying the overlay
#        out/boot/vmlinuz    — bzImage for direct QEMU -kernel boot
#        out/boot/initramfs.img
#
# Env overrides:
#   MACHINED_RS — path to the machined-rs checkout (default: /home/jones/PhpstormProjects/machined-rs)
#   OUT         — output root dir (default: <repo-root>/out)
#   CARGO_TARGET_DIR — cargo target dir for machined-rs builds; set to a
#                      jones-owned dir if the default target/ is root-owned
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MR="${MACHINED_RS:-/home/jones/PhpstormProjects/machined-rs}"
OUT="${OUT:-$REPO_ROOT/out}"
mkdir -p "$OUT/boot"

# Use a jones-owned target dir when the machined-rs target/ has root-owned
# artifacts (happens after a prior sudo/docker build).  The imager cache is
# kept inside OUT so it survives across runs without sudo.
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/machined-rs-build}"
export CARGO_TARGET_DIR

# ---------------------------------------------------------------------------
# 1. Overlay (binaries + config); idempotent (skips the Docker build when the
#    image is already present).
# ---------------------------------------------------------------------------
echo "==> assembling overlay"
OUT="$OUT/overlay" bash "$SCRIPT_DIR/m2a-build-overlay.sh"

# ---------------------------------------------------------------------------
# 2a. Host-side tools: machined-imager + machinectl (normal glibc build).
# ---------------------------------------------------------------------------
echo "==> building machined-imager + machinectl (host)"
( cd "$MR" && cargo build --release -p machined-imager -p machinectl )
IMAGER="$CARGO_TARGET_DIR/release/machined-imager"

# ---------------------------------------------------------------------------
# 2b. musl-static machined — runs as PID 1 in the Alpine/musl initramfs; a
#     plain glibc binary will NOT boot there.  `make dist-x86_64` handles the
#     musl toolchain detection / gcc fallback automatically.
# ---------------------------------------------------------------------------
echo "==> building musl-static machined (make dist-x86_64)"
( cd "$MR" && make dist-x86_64 )
MACHINED="$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/release/machined"
[ -f "$MACHINED" ] || { echo "ERROR: musl machined not found at $MACHINED"; exit 1; }
echo "    musl machined: $(file "$MACHINED")"

# ---------------------------------------------------------------------------
# 3. PKI (idempotent: skip if all four files already exist).
# ---------------------------------------------------------------------------
PKI_DIR="$OUT/pki"
if [[ -f "$PKI_DIR/ca.pem" && -f "$PKI_DIR/ca.key" && \
      -f "$PKI_DIR/server.pem" && -f "$PKI_DIR/server.key" ]]; then
    echo "==> PKI already present — skipping gen-pki"
else
    echo "==> generating node PKI"
    "$IMAGER" gen-pki --out "$PKI_DIR"
fi

# ---------------------------------------------------------------------------
# 4. Build the image.  --overlay bakes the Rust stack onto FAT /boot;
#    --emit-boot copies vmlinuz + initramfs.img for QEMU direct-kernel boot.
# ---------------------------------------------------------------------------
echo "==> building image (this fetches the kernel via the artifact cache)"
"$IMAGER" build \
    --arch x86_64 \
    --image-id m2a \
    --machined "$MACHINED" \
    --config "$REPO_ROOT/deploy/m2a/config.yaml" \
    --overlay "$OUT/overlay" \
    --pki-dir "$PKI_DIR" \
    --emit-boot "$OUT/boot" \
    --out "$OUT/m2a.img" \
    --manifest "$MR/crates/imager/artifacts.toml" \
    --cache "$OUT/imager-cache"

echo ""
echo "built: $OUT/m2a.img  $OUT/boot/vmlinuz  $OUT/boot/initramfs.img"
ls -lh "$OUT/m2a.img" "$OUT/boot/vmlinuz" "$OUT/boot/initramfs.img"
file "$OUT/boot/vmlinuz"

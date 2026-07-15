#!/usr/bin/env bash
# Assembles out/overlay/ — the payload tree baked onto /boot by machined's imager
# via the --overlay flag. Overlay contains the full Rust stack binaries, CNI plugins,
# bootstrap CNI conflist, and containerd-rs config. Consumed by Task D2's image build.
#
# Usage: bash scripts/m2a-build-overlay.sh
#
# Env overrides:
#   RUSTERNETES_SRC — path to the canonical rusternetes checkout (default: /home/jones/PhpstormProjects/rusternetes)
#   OUT             — output overlay dir (default: <repo-root>/out/overlay)
#   IMAGE_TAG       — unused (no GHCR all-in-one image exists); kept for compat
#   CONFIG_PATH     — machine config copied to /boot/config.yaml
#   KUBECONFIG_PATH — optional kubelet kubeconfig copied to /boot/kubelet.kubeconfig
#   REQUIRE_KUBELET — when 1, copy/build standalone kubelet for worker overlays
#   REQUIRE_KUBEPROXY — when 1, copy/build standalone kube-proxy for worker overlays
#   REBUILD_AIO     — when 1, rebuild mikronetes-aio:m2a even if the image tag exists
#   REBUILD_KUBELET — when 1, rebuild mikronetes-kubelet:m2b even if the image tag exists
#   REBUILD_KUBEPROXY — when 1, rebuild mikronetes-kube-proxy:m2c even if the image tag exists
#   CONTAINERD_RS_VERSION — GitHub release tag to install (default: v0.3.0)
#   CONTAINERD_RS_ARCH    — release arch override: amd64 or arm64 (default: host arch)
#   CONTAINERD_RS_BIN     — local containerd-rs binary override, skips release download
#   CONTAINERD_RS_CACHE   — release artifact cache dir (default: <repo-root>/out/cache/containerd-rs)
#   CONTAINERD_RS_INSECURE_REGISTRIES — optional legacy comma-separated HTTP registry fallback for old containerd-rs builds
#   CA_CERT_BUNDLE        — CA bundle copied for containerd-rs TLS client initialization
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Canonical rusternetes checkout (NOT rusternetes-m1). all-in-one.Dockerfile
# requires the PARENT dir as build context so rusternetes/rhino is accessible.
RUSTERNETES_SRC="${RUSTERNETES_SRC:-/home/jones/PhpstormProjects/rusternetes}"
RUSTERNETES_PARENT="$(dirname "$RUSTERNETES_SRC")"

OUT="${OUT:-$REPO_ROOT/out/overlay}"
CONFIG_PATH="${CONFIG_PATH:-$REPO_ROOT/deploy/m2a/config.yaml}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-}"
REQUIRE_KUBELET="${REQUIRE_KUBELET:-0}"
REQUIRE_KUBEPROXY="${REQUIRE_KUBEPROXY:-0}"
REBUILD_AIO="${REBUILD_AIO:-0}"
REBUILD_KUBELET="${REBUILD_KUBELET:-0}"
REBUILD_KUBEPROXY="${REBUILD_KUBEPROXY:-0}"
CONTAINERD_RS_VERSION="${CONTAINERD_RS_VERSION:-v0.3.0}"
CONTAINERD_RS_ARCH="${CONTAINERD_RS_ARCH:-}"
CONTAINERD_RS_BIN="${CONTAINERD_RS_BIN:-}"
CONTAINERD_RS_CACHE="${CONTAINERD_RS_CACHE:-$REPO_ROOT/out/cache/containerd-rs}"
CONTAINERD_RS_INSECURE_REGISTRIES="${CONTAINERD_RS_INSECURE_REGISTRIES:-}"
CA_CERT_BUNDLE="${CA_CERT_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
# Arch of the native CNI plugin + flannel-shim ELF binaries (amd64|arm64).
# Threaded from m2b-build-images.sh (ARCH); default amd64 == today.
CNI_ARCH="${CNI_ARCH:-amd64}"
# Target platform for the musl overlay image cross-builds (docker buildx).
# Default linux/amd64 == today's implicit host-arch build on an amd64 host
# (rust:1.95-alpine / alpine:3.21 are multi-arch); set PLATFORM=linux/arm64 to
# cross-build the arm64 overlay images under the arm64 binfmt emulation.
PLATFORM="${PLATFORM:-linux/amd64}"
# When cross-building arm64 overlay images, tag them :m2d-arm64 so they do not
# clobber the amd64 :m2a/:m2b/:m2c tags. Empty for amd64 -> keep existing tags.
if [ "$PLATFORM" = "linux/arm64" ]; then
    OVERLAY_IMAGE_TAG="m2d-arm64"
else
    OVERLAY_IMAGE_TAG=""
fi
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/certs.d" "$OUT/cni/bin" "$OUT/cni/conf" "$OUT/pki/k8s" "$OUT/ssl/certs"

containerd_rs_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64 | arm64) echo "arm64" ;;
        *)
            echo "unsupported containerd-rs host arch: $(uname -m)" >&2
            echo "set CONTAINERD_RS_ARCH=amd64 or CONTAINERD_RS_ARCH=arm64" >&2
            exit 1
            ;;
    esac
}

install_containerd_rs() {
    if [ -n "$CONTAINERD_RS_BIN" ]; then
        echo "==> copying containerd-rs from $CONTAINERD_RS_BIN"
        install -m0755 "$CONTAINERD_RS_BIN" "$OUT/bin/containerd-rs"
        return
    fi

    local arch="${CONTAINERD_RS_ARCH:-$(containerd_rs_arch)}"
    local artifact="containerd-rs_${CONTAINERD_RS_VERSION}_linux_${arch}.tar.gz"
    local checksums="containerd-rs_${CONTAINERD_RS_VERSION}_checksums.txt"
    local base_url="https://github.com/indyjonesnl/containerd-rs/releases/download/${CONTAINERD_RS_VERSION}"
    local cache_dir="$CONTAINERD_RS_CACHE/$CONTAINERD_RS_VERSION/$arch"
    local extract_dir

    mkdir -p "$cache_dir"
    if [ ! -f "$cache_dir/$artifact" ]; then
        echo "==> downloading containerd-rs $CONTAINERD_RS_VERSION ($arch)"
        curl -fsSL -o "$cache_dir/$artifact" "$base_url/$artifact"
    else
        echo "==> using cached containerd-rs $CONTAINERD_RS_VERSION ($arch)"
    fi

    if [ ! -f "$cache_dir/$checksums" ]; then
        curl -fsSL -o "$cache_dir/$checksums" "$base_url/$checksums"
    fi

    (cd "$cache_dir" && grep -E "[[:space:]]${artifact}$" "$checksums" | sha256sum -c -)
    extract_dir="$(mktemp -d)"
    tar -xzf "$cache_dir/$artifact" -C "$extract_dir"
    install -m0755 "$extract_dir/containerd-rs" "$OUT/bin/containerd-rs"
    rm -rf "$extract_dir"
}

install_containerd_rs_wrapper() {
    # The wrapper is a native ELF exec'd by machined as the containerd service,
    # so it MUST match the node arch. Default to musl-gcc (amd64); for arm64
    # cross-compile a static aarch64 binary (static glibc runs on the musl
    # image — no dynamic loader, no NSS in this shim). CC override still wins.
    local cc="${CC:-}"
    if [ -z "$cc" ]; then
        if [ "$CNI_ARCH" = arm64 ]; then cc="aarch64-linux-gnu-gcc"; else cc="musl-gcc"; fi
    fi
    local src="$OUT/containerd-rs-mikronetes.c"

    if ! command -v "$cc" >/dev/null 2>&1; then
        echo "ERROR: $cc not found; install musl-tools (amd64) / gcc-aarch64-linux-gnu (arm64) or set CC to a static-capable compiler" >&2
        exit 1
    fi

    echo "==> building static containerd-rs env wrapper"
    cat > "$src" <<C
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    if ("${CONTAINERD_RS_INSECURE_REGISTRIES}"[0] != '\\0') {
        setenv("CONTAINERD_RS_INSECURE_REGISTRIES", "${CONTAINERD_RS_INSECURE_REGISTRIES}", 1);
    }
    setenv("SSL_CERT_FILE", "/boot/ssl/certs/ca-certificates.crt", 1);
    setenv("SSL_CERT_DIR", "/boot/ssl/certs", 1);
    argv[0] = "/boot/bin/containerd-rs";
    execv("/boot/bin/containerd-rs", argv);
    fprintf(stderr, "containerd-rs-mikronetes: execv failed: %d\\n", errno);
    return 127;
}
C
    "$cc" -static -Os -s -o "$OUT/bin/containerd-rs-mikronetes" "$src"
    rm -f "$src"
}

# ---------------------------------------------------------------------------
# rusternetes all-in-one — musl-static binary from all-in-one.Dockerfile.
#
# There is NO GHCR all-in-one image; /app/rusternetes is produced ONLY by
# all-in-one.Dockerfile. Build context is the PARENT of rusternetes/ so the
# rhino crate path (../../rhino from crates/storage) resolves correctly.
# Cache the image; skip rebuild when it already exists (multi-minute compile).
# ---------------------------------------------------------------------------
AIO_IMAGE="mikronetes-aio:${OVERLAY_IMAGE_TAG:-m2a}"
# deploy/m2a/all-in-one-musl.Dockerfile is a mikronetes-local variant of
# rusternetes/all-in-one.Dockerfile that:
#   - Uses rust:1.95-alpine (musl toolchain) so the output is musl-statically
#     linked — required for the Alpine/musl initramfs.
#   - Fixes upstream bug: adds test_support to the dummy stub block
#     (missing from rusternetes/all-in-one.Dockerfile; causes "no targets
#     specified in the manifest" at cargo build time).
# Build context is the PARENT of rusternetes/ (same as upstream) so
# rusternetes/rhino/ is accessible from the Dockerfile's COPY instructions.
AIO_DOCKERFILE="$REPO_ROOT/deploy/m2a/all-in-one-musl.Dockerfile"
if [ "$REBUILD_AIO" != 1 ] && docker image inspect "$AIO_IMAGE" >/dev/null 2>&1; then
    echo "==> all-in-one image $AIO_IMAGE already present — skipping build"
else
    echo "==> building musl-static all-in-one"
    echo "    dockerfile: $AIO_DOCKERFILE"
    echo "    build context: $RUSTERNETES_PARENT"
    docker build \
        --platform "$PLATFORM" \
        -f "$AIO_DOCKERFILE" \
        -t "$AIO_IMAGE" \
        "$RUSTERNETES_PARENT"
fi
cid=$(docker create --platform "$PLATFORM" "$AIO_IMAGE")
docker cp "$cid:/app/rusternetes" "$OUT/bin/rusternetes"
docker rm "$cid" >/dev/null
chmod 0755 "$OUT/bin/rusternetes"

if [ "$REQUIRE_KUBELET" = 1 ]; then
    KUBELET_IMAGE="mikronetes-kubelet:${OVERLAY_IMAGE_TAG:-m2b}"
    if [ "$REBUILD_KUBELET" != 1 ] && docker image inspect "$KUBELET_IMAGE" >/dev/null 2>&1; then
        echo "==> kubelet image $KUBELET_IMAGE already present — skipping build"
    else
        echo "==> building musl-static standalone kubelet"
        docker build \
            --platform "$PLATFORM" \
            -f "$REPO_ROOT/deploy/m2a/kubelet-musl.Dockerfile" \
            -t "$KUBELET_IMAGE" \
            "$RUSTERNETES_PARENT"
    fi
    kid=$(docker create --platform "$PLATFORM" "$KUBELET_IMAGE")
    docker cp "$kid:/app/kubelet" "$OUT/bin/kubelet"
    docker rm "$kid" >/dev/null
    chmod 0755 "$OUT/bin/kubelet"
fi

if [ "$REQUIRE_KUBEPROXY" = 1 ]; then
    KUBEPROXY_IMAGE="mikronetes-kube-proxy:${OVERLAY_IMAGE_TAG:-m2c}"
    if [ "$REBUILD_KUBEPROXY" != 1 ] && docker image inspect "$KUBEPROXY_IMAGE" >/dev/null 2>&1; then
        echo "==> kube-proxy image $KUBEPROXY_IMAGE already present — skipping build"
    else
        echo "==> building musl-static standalone kube-proxy"
        docker build \
            --platform "$PLATFORM" \
            -f "$REPO_ROOT/deploy/m2a/kube-proxy-musl.Dockerfile" \
            -t "$KUBEPROXY_IMAGE" \
            "$RUSTERNETES_PARENT"
    fi
    kpid=$(docker create --platform "$PLATFORM" "$KUBEPROXY_IMAGE")
    docker cp "$kpid:/app/kube-proxy" "$OUT/bin/kube-proxy"
    docker rm "$kpid" >/dev/null
    chmod 0755 "$OUT/bin/kube-proxy"
fi

# ---------------------------------------------------------------------------
# containerd-rs — versioned musl-static release artifact.
# ---------------------------------------------------------------------------
install_containerd_rs
[ -f "$CA_CERT_BUNDLE" ] || {
    echo "ERROR: CA_CERT_BUNDLE not found: $CA_CERT_BUNDLE" >&2
    exit 1
}
install -m0644 "$CA_CERT_BUNDLE" "$OUT/ssl/certs/ca-certificates.crt"
install_containerd_rs_wrapper

for registry in 10.88.0.1:5000 10.88.0.1:5001; do
    safe="${registry/:/_}_"
    mkdir -p "$OUT/certs.d/$safe"
    cat > "$OUT/certs.d/$safe/hosts.toml" <<TOML
server = "http://${registry}"

[host."http://${registry}"]
capabilities = ["pull", "resolve"]
TOML
done

# ---------------------------------------------------------------------------
# crun (static OCI runtime). containerd-rs is configured to use crun directly.
# Cache: skip download if already at target checksum path.
# ---------------------------------------------------------------------------
CRUN_ARCH="${CRUN_ARCH:-amd64}"   # amd64 | arm64
CRUN_URL="https://github.com/containers/crun/releases/download/1.28/crun-1.28-linux-${CRUN_ARCH}"
if [[ ! -x "$OUT/bin/crun" ]]; then
    echo "==> downloading crun 1.28"
    curl -fsSL -o "$OUT/bin/crun" "$CRUN_URL"
    chmod +x "$OUT/bin/crun"
fi

# ---------------------------------------------------------------------------
# CNI plugins v1.9.1 (bridge, host-local, loopback, portmap) + flannel CNI v1.9.1-flannel1.
# ---------------------------------------------------------------------------
echo "==> downloading CNI plugins v1.9.1 ($CNI_ARCH) + flannel CNI v1.9.1-flannel1 ($CNI_ARCH)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The CNI plugin + flannel-shim binaries are NATIVE ELF, exec'd directly by
# containerd-rs on every pod sandbox setup (not container images -> guest binfmt
# does not apply). They MUST match the node arch or every pod ADD/DEL
# exec-format-errors. CNI_ARCH is threaded from m2b-build-images.sh (ARCH).
CNI_URL="https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-${CNI_ARCH}-v1.9.1.tgz"
curl -fsSL "$CNI_URL" | tar -xz -C "$tmp"
install -m0755 "$tmp/bridge"     "$OUT/cni/bin/bridge"
install -m0755 "$tmp/host-local" "$OUT/cni/bin/host-local"
install -m0755 "$tmp/loopback"   "$OUT/cni/bin/loopback"
install -m0755 "$tmp/portmap"    "$OUT/cni/bin/portmap"

FLANNEL_URL="https://github.com/flannel-io/cni-plugin/releases/download/v1.9.1-flannel1/cni-plugin-flannel-linux-${CNI_ARCH}-v1.9.1.tgz"
curl -fsSL "$FLANNEL_URL" | tar -xz -C "$tmp"
# The archive extracts to flannel-<arch> (not cni-plugin).
install -m0755 "$tmp/flannel-${CNI_ARCH}" "$OUT/cni/bin/flannel"

# ---------------------------------------------------------------------------
# Flannel CNI conflist — baked at /boot/cni/conf as the single active CNI.
#
# flannel-rs does NOT install a conflist itself (no upstream install-cni
# initContainer); it only writes /run/flannel/subnet.env. So the flannel
# conflist must be pre-placed here. The flannel plugin reads subnet.env and
# delegates to bridge+host-local with THIS node's per-node subnet, so each
# node hands out pod IPs from its own podCIDR (10.244.<n>.0/24).
#
# A static host-local bridge was baked here previously with a hardcoded
# subnet 10.244.0.0/24 — identical on every node — which made all nodes hand
# out 10.244.0.x and left the flannel chain unused. Replaced by the flannel
# chain below (matches the kube-flannel-cfg ConfigMap's cni-conf.json).
#
# No chicken/egg: the flannel DaemonSet pod is hostNetwork=true (skips CNI
# IPAM), and on ADD the flannel plugin returns try-again (code 11) if
# subnet.env is not written yet, so kubelet simply retries the sandbox.
# ---------------------------------------------------------------------------
cat > "$OUT/cni/conf/10-flannel.conflist" <<'JSON'
{ "name": "cbr0", "cniVersion": "0.3.1", "plugins": [
  { "type": "flannel", "delegate": { "hairpinMode": true, "isDefaultGateway": true } },
  { "type": "portmap", "capabilities": { "portMappings": true } } ] }
JSON

# ---------------------------------------------------------------------------
# Kubernetes PKI for rusternetes: CA + server cert/key baked onto
# /boot/pki/k8s/ (subdirectory avoids collision with machined's own node PKI
# files — ca.pem, ca.key, server.pem, server.key — placed at /boot/pki/ by
# machined-imager's --pki-dir step which runs AFTER the overlay).
#
# rusternetes reads --tls-cert-file /boot/pki/k8s/server.crt and
# --tls-key-file /boot/pki/k8s/server.key (set in config.yaml).
# resolve_ca_cert_pem() finds /boot/pki/k8s/ca.crt as a sibling of the cert
# file and embeds it in every SA token secret instead of falling back to the
# leaf serving cert — this is required so in-cluster clients (flannel-rs) can
# verify the API server's TLS cert.
#
# SANs: localhost + 127.0.0.1 (flannel hostNetwork loopback), 10.88.0.2 (VM
# NIC), 10.96.0.1 (kubernetes Service ClusterIP), kubernetes DNS aliases.
# ---------------------------------------------------------------------------
PKI="$OUT/pki/k8s"
if [[ -f "$PKI/ca.crt" && -f "$PKI/server.crt" && -f "$PKI/server.key" ]]; then
    echo "==> overlay PKI already present — skipping cert generation"
else
    echo "==> generating overlay PKI (CA + server cert)"
    openssl genrsa -out "$PKI/ca.key" 2048 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$PKI/ca.key" -out "$PKI/ca.crt" \
        -subj "/CN=rusternetes-ca/O=mikronetes" 2>/dev/null
    openssl genrsa -out "$PKI/server.key" 2048 2>/dev/null
    openssl req -new -key "$PKI/server.key" -out "$PKI/server.csr" \
        -subj "/CN=rusternetes-api/O=mikronetes" 2>/dev/null
    cat > "$PKI/server.ext" <<'EXT'
[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
DNS.1 = localhost
DNS.2 = kubernetes
DNS.3 = kubernetes.default
DNS.4 = kubernetes.default.svc
DNS.5 = kubernetes.default.svc.cluster.local
DNS.6 = node-1
IP.1 = 127.0.0.1
IP.2 = 10.88.0.2
IP.3 = 10.96.0.1
EXT
    openssl x509 -req -days 3650 -in "$PKI/server.csr" \
        -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial \
        -out "$PKI/server.crt" -extensions v3_req -extfile "$PKI/server.ext" 2>/dev/null
    # Append CA to server cert for a full chain (rusternetes TlsConfig::from_pem_files
    # parses all PEM blocks; sending the full chain is good practice).
    cat "$PKI/ca.crt" >> "$PKI/server.crt"
    rm -f "$PKI/ca.key" "$PKI/server.csr" "$PKI/server.ext" "$PKI/ca.srl"
    chmod 600 "$PKI/server.key"
    echo "    CA:     $(openssl x509 -noout -subject -in "$PKI/ca.crt")"
    echo "    server: $(openssl x509 -noout -subject -issuer -in <(openssl x509 -in "$PKI/server.crt"))"
fi

# ---------------------------------------------------------------------------
# Machine config + containerd-rs config (from deploy/m2a).
# config.yaml is written by Task D1; skip that copy until D1 is done.
# config-containerd-rs.toml is created in this task, copy it now.
# ---------------------------------------------------------------------------
cp "$CONFIG_PATH" "$OUT/config.yaml"
cp "$REPO_ROOT/deploy/m2a/config-containerd-rs.toml" "$OUT/config-containerd-rs.toml"
if [ -n "$KUBECONFIG_PATH" ]; then
    cp "$KUBECONFIG_PATH" "$OUT/kubelet.kubeconfig"
fi

echo ""
echo "overlay assembled at $OUT"
find "$OUT" \( -type f -o -type l \) | sort

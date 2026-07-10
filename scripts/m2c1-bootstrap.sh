#!/usr/bin/env bash
# M2c-1 bootstrap: M2c-0 (system Services + DNS) + a PHP DaemonSet workload.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VMIP="${VMIP:-10.88.0.2}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5000}"
PHP_IMAGE_TAG="${PHP_IMAGE_TAG:-mikronetes-php:m2c}"
# Cross-build platform for the in-repo php-alpine image. Default linux/amd64
# reproduces today's host-arch build; set PLATFORM=linux/arm64 for the arm64
# variant so the PHP DaemonSet runs on aarch64 nodes.
PLATFORM="${PLATFORM:-linux/amd64}"
say() { printf '\n==> %s\n' "$*"; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

# M2c-0: system Services (kubernetes @.1, kube-dns @.10) + rusternetes-dns + whoami.
bash "$SCRIPT_DIR/m2c-bootstrap.sh"

# Minimal alpine PHP image (build if missing) mirrored into the local registry.
# Custom + tiny on purpose: the official php images (Debian ~500MB / cli-alpine)
# either trip containerd-rs's unpacker or fill the worker's small disk (ENOSPC).
say "ensuring $PHP_IMAGE_TAG in the local registry"
# Arch-aware guard: rebuild if the cached image arch differs from wanted, else
# an amd64-cached :m2c image would be mirrored into an arm64 cluster.
if [ "$(docker image inspect "$PHP_IMAGE_TAG" --format '{{.Architecture}}' 2>/dev/null || true)" != "${PLATFORM#linux/}" ]; then
  docker build --platform "$PLATFORM" -f "$REPO_ROOT/deploy/m2c/php-alpine.Dockerfile" -t "$PHP_IMAGE_TAG" "$REPO_ROOT"
fi
docker tag "$PHP_IMAGE_TAG" "localhost:${REGISTRY_HOST_PORT}/mikronetes-php:m2c"
docker push "localhost:${REGISTRY_HOST_PORT}/mikronetes-php:m2c" >/dev/null

say "applying PHP DaemonSet + web Service"
kc apply -f "$REPO_ROOT/deploy/m2c/php-daemonset.yaml"

say "waiting for 3 php-web pods Running (one per worker)"
ok=0
for _ in $(seq 1 $((60 * ${WAIT_SCALE:-1}))); do
  n=$(kc get pods -l app=php-web --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  [ "${n:-0}" -ge 3 ] && ok=1 && break
  sleep 5
done
[ "$ok" = 1 ] || { kc get pods -l app=php-web -o wide || true; echo "ERROR: php-web not at 3 Running" >&2; exit 1; }
say "waiting for web Service ClusterIP + endpoints"
for _ in $(seq 1 $((30 * ${WAIT_SCALE:-1}))); do
  cip=$(kc get svc web -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo)
  [ -n "$cip" ] && [ "$cip" != None ] && break
  sleep 2
done
say "web ClusterIP=$cip"
kc get pods -l app=php-web -o wide || true
say "m2c-1 bootstrap complete"

#!/usr/bin/env bash
# M2c-1 bootstrap: M2c-0 (system Services + DNS) + a PHP DaemonSet workload.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VMIP="${VMIP:-10.88.0.2}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5000}"
PHP_IMAGE_SOURCE="${PHP_IMAGE_SOURCE:-php:8.4-apache}"
say() { printf '\n==> %s\n' "$*"; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

# M2c-0: system Services (kubernetes @.1, kube-dns @.10) + rusternetes-dns + whoami.
bash "$SCRIPT_DIR/m2c-bootstrap.sh"

say "mirroring $PHP_IMAGE_SOURCE into the local registry"
docker image inspect "$PHP_IMAGE_SOURCE" >/dev/null 2>&1 || docker pull "$PHP_IMAGE_SOURCE"
docker tag "$PHP_IMAGE_SOURCE" "localhost:${REGISTRY_HOST_PORT}/php:8.4-apache"
docker push "localhost:${REGISTRY_HOST_PORT}/php:8.4-apache" >/dev/null

say "applying PHP DaemonSet + web Service"
kc apply -f "$REPO_ROOT/deploy/m2c/php-daemonset.yaml"

say "waiting for 3 php-web pods Running (one per worker)"
ok=0
for _ in $(seq 1 60); do
  n=$(kc get pods -l app=php-web --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  [ "${n:-0}" -ge 3 ] && ok=1 && break
  sleep 5
done
[ "$ok" = 1 ] || { kc get pods -l app=php-web -o wide || true; echo "ERROR: php-web not at 3 Running" >&2; exit 1; }
say "waiting for web Service ClusterIP + endpoints"
for _ in $(seq 1 30); do
  cip=$(kc get svc web -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo)
  [ -n "$cip" ] && [ "$cip" != None ] && break
  sleep 2
done
say "web ClusterIP=$cip"
kc get pods -l app=php-web -o wide || true
say "m2c-1 bootstrap complete"

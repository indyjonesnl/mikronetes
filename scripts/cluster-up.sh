#!/usr/bin/env bash
# Bring up the two-node PoC cluster, handling the worker join token.
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="docker compose"
TIMEOUT="${TIMEOUT:-180}"

echo "==> Starting controller + 2 workers (512 MB cap each)..."
$COMPOSE up -d controller worker1 worker2

echo "==> Waiting for the controller API to become ready (timeout ${TIMEOUT}s)..."
deadline=$((SECONDS + TIMEOUT))
until $COMPOSE exec -T controller k0s status >/dev/null 2>&1 \
   && $COMPOSE exec -T controller k0s kubectl get --raw='/readyz' >/dev/null 2>&1; do
  if [ $SECONDS -ge $deadline ]; then
    echo "!! Controller did not become ready in ${TIMEOUT}s" >&2
    $COMPOSE logs --tail=40 controller >&2 || true
    exit 1
  fi
  sleep 3
done
echo "==> Controller is ready."

echo "==> Creating worker join token..."
# Written into the shared volume; both worker containers are already polling for
# it. A k0s worker token is reusable until expiry, so one token joins both.
$COMPOSE exec -T controller sh -c \
  'k0s token create --role=worker --expiry=1h > /shared/worker.token'
echo "==> Token issued; both workers will join."

echo "==> Cluster bootstrapping. Check with: scripts/smoke-test.sh"

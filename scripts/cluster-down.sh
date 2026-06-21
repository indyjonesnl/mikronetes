#!/usr/bin/env bash
# Tear down the PoC cluster and its volumes.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down -v --remove-orphans
echo "==> Cluster removed."

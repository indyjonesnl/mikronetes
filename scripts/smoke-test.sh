#!/usr/bin/env bash
# The PR gate. Brings up the 1 control-plane + 2 worker cluster (512 MB/node):
#   1. both worker nodes reach Ready
#   2. a Hello World pod schedules on a worker and serves HTTP
#   3. no container was OOM-killed
# Exits non-zero on any failure. This must stay green as mikronetes replaces k0s.
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="docker compose"
KUBECTL="$COMPOSE exec -T controller k0s kubectl"
TIMEOUT="${TIMEOUT:-240}"

fail() { echo "!! $*" >&2; exit 1; }

# 1. Bring the cluster up.
scripts/cluster-up.sh

echo "==> Waiting for 2 worker nodes to be Ready (timeout ${TIMEOUT}s)..."
deadline=$((SECONDS + TIMEOUT))
until [ "$($KUBECTL get nodes --no-headers 2>/dev/null | grep -c ' Ready ')" = "2" ]; do
  [ $SECONDS -ge $deadline ] && { $KUBECTL get nodes >&2 || true; fail "2 worker nodes not Ready in time"; }
  sleep 5
done
$KUBECTL get nodes
echo "==> Both worker nodes Ready."

# 2. Deploy a Hello World pod, pin it to a worker, expose it.
echo "==> Deploying Hello World (traefik/whoami) on a worker..."
WORKER_NODE="$($KUBECTL get nodes --no-headers -o custom-columns=N:.metadata.name | head -1)"
$KUBECTL apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: { name: hello }
spec:
  replicas: 1
  selector: { matchLabels: { app: hello } }
  template:
    metadata: { labels: { app: hello } }
    spec:
      nodeSelector: { kubernetes.io/hostname: ${WORKER_NODE} }
      containers:
        - name: whoami
          image: traefik/whoami:v1.10.2
          ports: [ { containerPort: 80 } ]
          resources: { requests: { memory: 8Mi, cpu: 10m }, limits: { memory: 32Mi } }
YAML

echo "==> Waiting for the pod to be Ready..."
$KUBECTL wait --for=condition=Available deploy/hello --timeout="${TIMEOUT}s" \
  || { $KUBECTL describe deploy/hello >&2; $KUBECTL get pods -o wide >&2; fail "hello deployment never became Available"; }

# Confirm it actually landed on the worker, not the controller.
POD_NODE="$($KUBECTL get pods -l app=hello -o jsonpath='{.items[0].spec.nodeName}')"
echo "==> hello pod scheduled on: ${POD_NODE}"
[ "$POD_NODE" = "$WORKER_NODE" ] || fail "pod landed on $POD_NODE, expected worker $WORKER_NODE"

# 3. Expose it as a NodePort and hit it over real service networking.
# We curl the worker container's IP from the host: host -> NodePort -> kube-proxy
# -> pod. No exec/attach/konnectivity tunneling, so nothing flaky to race.
echo "==> Exposing hello as a NodePort and curling it..."
$KUBECTL expose deploy/hello --type=NodePort --port=80 >/dev/null
NODEPORT="$($KUBECTL get svc hello -o jsonpath='{.spec.ports[0].nodePort}')"
WORKER_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mikronetes-worker1)"
echo "==> http://${WORKER_IP}:${NODEPORT}/ (worker1 NodePort)"

deadline=$((SECONDS + 60))
until curl -sS --max-time 5 "http://${WORKER_IP}:${NODEPORT}/" 2>/dev/null | grep -qi "Hostname"; do
  [ $SECONDS -ge $deadline ] && fail "HTTP request to the hello NodePort never returned the expected response"
  sleep 3
done
echo "==> Hello World pod served HTTP. ✅"

# 4. Assert no container was OOM-killed and report peak memory.
for c in mikronetes-controller mikronetes-worker1 mikronetes-worker2; do
  oom="$(docker inspect -f '{{.State.OOMKilled}}' "$c" 2>/dev/null || echo unknown)"
  [ "$oom" = "true" ] && fail "$c was OOM-killed (did not fit in 512 MB)"
done
echo "==> Memory usage (cap 512 MiB/node):"
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' \
  mikronetes-controller mikronetes-worker1 mikronetes-worker2

echo
echo "===================================================="
echo " PoC PASSED: 1 control-plane + 2 workers on 512 MB/node, pod served traffic."
echo "===================================================="

#!/usr/bin/env bash
# M2c-0 bootstrap: run m2b bootstrap, taint node-1, front the whoami pods with
# a ClusterIP Service so kube-proxy load-balancing + DNS can be proven.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMIP="${VMIP:-10.88.0.2}"
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

say() { printf '\n==> %s\n' "$*"; }

bash "$SCRIPT_DIR/m2b-bootstrap.sh"

say "tainting node-1 NoSchedule (control-plane holds no workload pods)"
kc taint node node-1 node-role.kubernetes.io/control-plane=:NoSchedule --overwrite

say "creating ClusterIP Service 'whoami' over the m2b whoami pods"
kc apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: m2b-whoami
  ports:
  - name: http
    port: 80
    targetPort: 80
YAML

say "waiting for the Service to get a ClusterIP and endpoints"
for _ in $(seq 1 30); do
  cip=$(kc get svc whoami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo)
  [ -n "$cip" ] && [ "$cip" != "None" ] && break
  sleep 2
done
say "whoami ClusterIP=$cip"
kc get endpointslice -l kubernetes.io/service-name=whoami -o wide || true
say "m2c-0 bootstrap complete"

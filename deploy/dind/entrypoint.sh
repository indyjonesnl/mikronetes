#!/usr/bin/env bash
# Node entrypoint: role dispatch for the kind-style all-Rust node.
#   ROLE=control-plane -> api-server + scheduler + controller-manager (SQLite)
#   ROLE=worker        -> containerd-rs + kubelet + kube-proxy
set -uo pipefail
ROLE="${ROLE:?ROLE must be control-plane or worker}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
CP="${CP_ENDPOINT:-https://10.88.0.2:6443}"
PKI=/etc/rusternetes/pki
KCFG=/etc/rusternetes/kubeconfig
REGISTRY="${REGISTRY:-10.88.0.1:5000}"
mkdir -p /var/log/rusternetes /var/lib/rusternetes
# containerd-rs / crun want a machine-id; the slim base has none.
[ -s /etc/machine-id ] || { dd if=/dev/urandom bs=16 count=1 status=none | md5sum | cut -d' ' -f1 > /etc/machine-id; }

wait_for() { # $1=desc $2=cmd
  for _ in $(seq 1 90); do eval "$2" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "TIMEOUT waiting for $1" >&2; return 1
}

start_containerd_rs() {
  mkdir -p /var/lib/containerd-rs /run/containerd-rs /etc/cni/net.d
  # containerd-rs has no local-image load path — allow HTTP pulls from the
  # local registry (mechanism proven in scripts/k0s-diff).
  export CONTAINERD_RS_INSECURE_REGISTRIES="$REGISTRY"
  containerd-rs --config /etc/containerd-rs/config.toml \
    >/var/log/rusternetes/containerd-rs.log 2>&1 &
  wait_for "containerd-rs socket" '[ -S /run/containerd-rs.sock ]' || exit 1
}

case "$ROLE" in
  control-plane)
    api-server --bind-address 0.0.0.0:6443 --tls \
      --tls-cert-file "$PKI/server.crt" --tls-key-file "$PKI/server.key" \
      --skip-auth --storage-backend sqlite \
      --data-dir /var/lib/rusternetes/state.db --log-level info \
      >/var/log/rusternetes/api-server.log 2>&1 &
    wait_for "api-server healthz" 'curl -sk https://127.0.0.1:6443/healthz' || exit 1
    scheduler --api-server-url "$CP" --kubeconfig "$KCFG" --interval 1 \
      --insecure-skip-tls-verify >/var/log/rusternetes/scheduler.log 2>&1 &
    controller-manager --api-server-url "$CP" --kubeconfig "$KCFG" --sync-interval 5 \
      --insecure-skip-tls-verify >/var/log/rusternetes/controller-manager.log 2>&1 &
    ;;
  worker)
    start_containerd_rs
    export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd-rs.sock
    export CONTAINERD_STREAM_HOST=127.0.0.1
    kubelet --node-name "$NODE_NAME" --kubeconfig "$KCFG" --api-server-url "$CP" \
      --insecure-skip-tls-verify --root-dir /var/lib/rusternetes/kubelet \
      --volume-dir /var/lib/rusternetes/volumes --cluster-dns 10.96.0.10 \
      --eviction-hard "" >/var/log/rusternetes/kubelet.log 2>&1 &
    # --cluster-cidr is the SERVICE (ClusterIP) CIDR, not the pod CIDR — it
    # scopes kube-proxy's POSTROUTING MASQUERADE for DNAT'd service traffic. It
    # MUST be the service range (10.96.0.0/12) so cross-node ClusterIP traffic
    # is masqueraded to the node IP; with the pod CIDR here the masq rule keys
    # on ctorigdst 10.244/16, never matches a ClusterIP, and cross-node Service
    # LB breaks (remote backend's reply can't return). Default is 10.96.0.0/12.
    kube-proxy --node-name "$NODE_NAME" --kubeconfig "$KCFG" --api-server-url "$CP" \
      --insecure-skip-tls-verify --cluster-cidr 10.96.0.0/12 \
      >/var/log/rusternetes/kube-proxy.log 2>&1 &
    ;;
  *) echo "unknown ROLE=$ROLE" >&2; exit 2 ;;
esac

exec tail -F /var/log/rusternetes/*.log

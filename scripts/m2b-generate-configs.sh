#!/usr/bin/env bash
# Generate M2b per-node machined configs for a 1 control-plane + 3 worker cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${OUT:-$REPO_ROOT/out/m2b}"
CONFIG_DIR="$OUT/configs"
M2B_API_PROBE="${M2B_API_PROBE:-0}"

mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_DIR/kubelet.kubeconfig" <<'YAML'
apiVersion: v1
kind: Config
clusters:
- name: m2b
  cluster:
    server: https://10.88.0.2:6443
    insecure-skip-tls-verify: true
contexts:
- name: m2b
  context:
    cluster: m2b
    user: m2b-worker
current-context: m2b
users:
- name: m2b-worker
  user:
    token: dummy
YAML

write_control_plane() {
  cat > "$CONFIG_DIR/node-1.yaml" <<'YAML'
machine:
  hostname: node-1
  network:
    interfaces:
      - name: eth0
        addresses: ["10.88.0.2/24"]
        routes:
          - via: 10.88.0.1
    nameservers: [10.88.0.1]
  install:
    disk: /dev/vda
    wipe: false
  runtime:
    disabled: false
    binary: /boot/bin/containerd-rs-mikronetes
    socket: /run/containerd-rs.sock
    config_path: /boot/config-containerd-rs.toml
  services:
    - id: rusternetes
      command:
        - /boot/bin/rusternetes
        - --storage-backend
        - sqlite
        - --data-dir
        - /var/lib/rusternetes/db
        - --tls
        - --tls-cert-file
        - /boot/pki/k8s/server.crt
        - --tls-key-file
        - /boot/pki/k8s/server.key
        - --bind-address
        - 0.0.0.0:6443
        - --node-name
        - node-1
        - --skip-auth
        - --disable-proxy
        - --disable-dns
        - --volume-dir
        - /var/lib/rusternetes/volumes
      depends_on: [containerd]
      restart: always
      env:
        - { key: RUST_LOG, value: info }
        - { key: RUST_MIN_STACK, value: "8388608" }
        - { key: PATH, value: "/boot/bin:/usr/bin:/bin" }
        - { key: CONTAINER_RUNTIME_ENDPOINT, value: "unix:///run/containerd-rs.sock" }
YAML
}

write_worker() {
  local node="$1"
  local ip="$2"
  cat > "$CONFIG_DIR/${node}.yaml" <<YAML
machine:
  hostname: ${node}
  network:
    interfaces:
      - name: eth0
        addresses: ["${ip}/24"]
        routes:
          - via: 10.88.0.1
    nameservers: [10.88.0.1]
  install:
    disk: /dev/vda
    wipe: false
  runtime:
    disabled: false
    binary: /boot/bin/containerd-rs-mikronetes
    socket: /run/containerd-rs.sock
    config_path: /boot/config-containerd-rs.toml
  services:
YAML
  if [ "$M2B_API_PROBE" = 1 ]; then
    cat >> "$CONFIG_DIR/${node}.yaml" <<'YAML'
    - id: api-probe
      command:
        - /bin/sh
        - -c
        - |
          for i in 1 2 3 4 5; do
            echo "api-probe attempt ${i}: GET https://10.88.0.2:6443/api"
            wget --no-check-certificate -S -O - https://10.88.0.2:6443/api 2>&1 | head -80 || true
            echo "api-probe attempt ${i}: POST minimal node"
            wget --no-check-certificate -S -O - \
              --header 'Content-Type: application/json' \
              --post-data '{"apiVersion":"v1","kind":"Node","metadata":{"name":"api-probe-node"},"spec":{},"status":{}}' \
              https://10.88.0.2:6443/api/v1/nodes 2>&1 | head -80 || true
            sleep 5
          done
      restart: never
YAML
  fi
  cat >> "$CONFIG_DIR/${node}.yaml" <<YAML
    - id: kubelet
      command:
        - /boot/bin/kubelet
        - --node-name
        - ${node}
        - --kubeconfig
        - /boot/kubelet.kubeconfig
        - --api-server-url
        - https://10.88.0.2:6443
        - --insecure-skip-tls-verify
        - --root-dir
        - /var/lib/rusternetes/kubelet
        - --volume-dir
        - /var/lib/rusternetes/volumes
        - --cluster-dns
        - 10.96.0.10
        - --eviction-hard
        - ""
      depends_on: [containerd]
      restart: always
      env:
        - { key: RUST_LOG, value: info }
        - { key: PATH, value: "/boot/bin:/usr/bin:/bin" }
        - { key: CONTAINER_RUNTIME_ENDPOINT, value: "unix:///run/containerd-rs.sock" }
YAML
}

write_control_plane
write_worker node-2 10.88.0.3
write_worker node-3 10.88.0.4
write_worker node-4 10.88.0.5

echo "generated M2b configs in $CONFIG_DIR"
ls -1 "$CONFIG_DIR"

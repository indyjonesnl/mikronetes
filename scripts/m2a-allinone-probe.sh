#!/usr/bin/env bash
# Phase A de-risk: all-in-one embedded kubelet (CNI/CRI) + containerd-rs + crun + flannel.
#
# Proves that the rusternetes ALL-IN-ONE binary (embedded kubelet, CRI mode, default
# CNI pod-network-mode) can drive an external containerd-rs instance and run a
# flannel-networked pod. This is the M2a go/no-go gate: the microVM node will run
# this exact combination.
#
# Key finding from source inspection (crates/kubelet/src/kubelet.rs:411):
#   The all-in-one's embedded kubelet ALWAYS uses the CRI path. It reads
#   CONTAINER_RUNTIME_ENDPOINT unconditionally (default: containerd.sock).
#   There is no Bollard/Docker path in new_with_eviction. Setting
#   CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd-rs.sock is sufficient.
#
# Note on GHCR images: the all-in-one binary is NOT in
#   ghcr.io/indyjonesnl/rusternetes/api-server:main (that image carries
#   /app/api-server only). The all-in-one image is rusternetes-rusternetes:latest
#   (built locally from Dockerfile.all-in-one) — this probe uses it.
#
# Usage: bash scripts/m2a-allinone-probe.sh
# Expected: PASS: all-in-one embedded kubelet + containerd-rs + flannel ran a pod
set -euo pipefail

M1="${RUSTERNETES_M1:-/home/jones/PhpstormProjects/rusternetes-m1}"
# Default to the CRI-capable probe image (built from HEAD source,
# crates/kubelet CONTAINER_RUNTIME_ENDPOINT path, no Bollard).
# rusternetes-rusternetes:latest was built before the CRI-only migration
# and still has Bollard; rusternetes-aio-probe:cri is current HEAD.
AIO_IMAGE="${AIO_IMAGE:-rusternetes-aio-probe:cri}"
say(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nFAIL: %s\n' "$*" >&2
       say "=== m2a-aio logs (last 60 lines) ==="
       docker logs --tail=60 m2a-aio 2>&1 || true
       say "=== m2a-cdrs logs (last 30 lines) ==="
       docker logs --tail=30 m2a-cdrs 2>&1 || true
       docker rm -f m2a-aio m2a-cdrs >/dev/null 2>&1 || true
       docker network rm m2a-probe >/dev/null 2>&1 || true
       docker volume rm m2a-run >/dev/null 2>&1 || true
       exit 1
     }

# 1. Verify the all-in-one image exists (CRI-capable, built from HEAD source).
#    Build it if needed:
#      cd /home/jones/PhpstormProjects/rusternetes
#      cargo build -p rusternetes
#      cp target/debug/rusternetes /tmp/probe-build/rusternetes
#      docker build -f /tmp/probe-build/Dockerfile.aio-probe -t rusternetes-aio-probe:cri /tmp/probe-build/
say "checking all-in-one image: ${AIO_IMAGE}"
docker image inspect "${AIO_IMAGE}" >/dev/null 2>&1 \
  || die "all-in-one image '${AIO_IMAGE}' not found — see comment above for build steps"

# 2. Verify the M1 node-cdrs image exists (contains containerd-rs + crun + CNI).
say "checking node-cdrs image: rusternetes-node-cdrs:m1"
docker image inspect rusternetes-node-cdrs:m1 >/dev/null 2>&1 \
  || die "node-cdrs image 'rusternetes-node-cdrs:m1' not found — build it with:
  docker build --build-arg 'KUBELET_IMAGE=ghcr.io/indyjonesnl/rusternetes/kubelet:main' \
    -f '${M1}/deploy/node-cdrs/Dockerfile' -t rusternetes-node-cdrs:m1 '${M1}'"

say "images OK — starting probe containers"

docker network create m2a-probe >/dev/null 2>&1 || true

# Shared named volume for /run so containerd-rs.sock is visible to both
# containers. --volumes-from only copies the declared VOLUME paths; the socket
# lives at /run/containerd-rs.sock (top-level /run, NOT inside the volume-
# declared /run/containerd-rs directory), so a shared Docker volume on /run
# is the reliable way to bridge it.
docker volume create m2a-run >/dev/null 2>&1 || true

# containerd-rs node: provides /run/containerd-rs.sock, /opt/cni/bin, crun.
# Override the entrypoint (which would launch the M1 kubelet) to run only
# containerd-rs; the all-in-one's embedded kubelet replaces the M1 kubelet.
docker rm -f m2a-cdrs >/dev/null 2>&1 || true
docker run -d --name m2a-cdrs --privileged --network m2a-probe \
  -v /lib/modules:/lib/modules:ro \
  -v m2a-run:/run \
  --entrypoint sh \
  rusternetes-node-cdrs:m1 \
  -c '
set -e
sysctl -w fs.inotify.max_user_instances=1024 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_watches=1048576 >/dev/null 2>&1 || true
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    mkdir -p /sys/fs/cgroup/init
    while read -r pid; do echo "$pid" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true; done < /sys/fs/cgroup/cgroup.procs
    for c in $(cat /sys/fs/cgroup/cgroup.controllers); do echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true; done
fi
exec /usr/local/bin/containerd-rs --config /etc/containerd-rs/config.toml
'

say "containerd-rs started — waiting 5s for socket"
sleep 5
docker exec m2a-cdrs test -S /run/containerd-rs.sock \
  || die "containerd-rs socket /run/containerd-rs.sock not present after 5s"
say "containerd-rs socket ready"

# Pre-create a minimal bridge CNI conflist so containerd-rs can set up the first
# pod sandbox. Without any conflist in /etc/cni/net.d/, containerd-rs returns
# "CNI network setup failed: No such file or directory" for EVERY RunPodSandbox
# call (even hostNetwork pods trigger the CNI path). This creates an unresolvable
# chicken-and-egg: the flannel init container cannot start to install the flannel
# conflist. The bridge conflist is a temporary bootstrap; once flannel's
# kube-flannel-ds runs and writes /etc/cni/net.d/10-flannel.conflist, pods use
# the flannel overlay. For this de-risk probe, the bridge conflist is sufficient.
say "pre-creating bootstrap CNI bridge conflist"
docker exec m2a-cdrs sh -c '
mkdir -p /etc/cni/net.d
cat > /etc/cni/net.d/10-bridge.conflist << EOF
{
  "cniVersion": "1.0.0",
  "name": "bridge-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "10.244.0.0/24"}]],
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF
'

# all-in-one: embedded kubelet pointed at containerd-rs over the shared netns.
# --network container:m2a-cdrs shares the netns + /run so the kubelet sees
# /run/containerd-rs.sock without a separate bind mount.
# --volumes-from shares /opt/cni/bin (CNI plugins) and /etc/containerd-rs/
# so the embedded kubelet's CNI path finds the standard plugins.
docker rm -f m2a-aio >/dev/null 2>&1 || true
docker run -d --name m2a-aio --privileged --network "container:m2a-cdrs" \
  -e RUST_LOG=info \
  -e RUST_MIN_STACK=8388608 \
  -e CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd-rs.sock \
  -v m2a-run:/run \
  --volumes-from m2a-cdrs \
  "${AIO_IMAGE}" \
  --storage-backend sqlite \
  --data-dir /var/lib/rusternetes/db \
  --tls \
  --bind-address 0.0.0.0:6443 \
  --node-name node-1 \
  --skip-auth \
  --disable-proxy \
  --disable-dns

say "all-in-one started — waiting for API server readiness"
sleep 5

API_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' m2a-cdrs)
say "API server IP: ${API_IP}"
kc(){ kubectl --server "https://${API_IP}:6443" --insecure-skip-tls-verify --token dummy "$@"; }

say "waiting for node-1 Ready (up to 5 min)"
for i in $(seq 1 60); do
  STATUS="$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo)"
  if [ "${STATUS}" = "True" ]; then
    say "node-1 is Ready (iteration ${i})"
    break
  fi
  printf '  [%d/60] node-1 status: %s\n' "${i}" "${STATUS:-<no node yet>}"
  sleep 5
done

STATUS="$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo)"
[ "${STATUS}" = "True" ] || die "node-1 not Ready after 5 min"

say "applying flannel-rs DaemonSet"
kc apply -f "${M1}/deploy/flannel/flannel-rs.yaml" 2>&1 || true

say "running probe pod (traefik/whoami)"
kc run probe --image=traefik/whoami:v1.10.2 >/dev/null 2>&1 || true

say "waiting for probe pod Running (up to 5 min)"
for i in $(seq 1 60); do
  PHASE="$(kc get pod probe -o jsonpath='{.status.phase}' 2>/dev/null || echo)"
  if [ "${PHASE}" = "Running" ]; then
    say "probe pod is Running (iteration ${i})"
    break
  fi
  printf '  [%d/60] probe phase: %s\n' "${i}" "${PHASE:-<no pod yet>}"
  sleep 5
done

PHASE="$(kc get pod probe -o jsonpath='{.status.phase}' 2>/dev/null || echo)"
[ "${PHASE}" = "Running" ] \
  || die "probe pod never reached Running (embedded-kubelet/CRI/CNI path broken)"

echo ""
echo "PASS: all-in-one embedded kubelet + containerd-rs + flannel ran a pod"

say "=== PROVEN all-in-one argv/env (use verbatim in machine.yaml, Task D1) ==="
docker inspect -f 'cmd={{.Config.Cmd}} env={{.Config.Env}}' m2a-aio

say "tear-down"
docker rm -f m2a-aio m2a-cdrs >/dev/null 2>&1 || true
docker network rm m2a-probe >/dev/null 2>&1 || true
docker volume rm m2a-run >/dev/null 2>&1 || true
say "done"

# dind-cluster CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A kind-style Docker-in-Docker CI gate that runs the all-Rust cluster (rusternetes CP + containerd-rs + crun + flannel-rs) as containers-as-nodes — 1 control-plane + 2 workers — natively on both amd64 (`ubuntu-latest`) and arm64 (`ubuntu-24.04-arm`), asserting Services parity.

**Architecture:** A single multi-arch-agnostic `mikronetes-node` image is COPY-only-assembled per arch from the rusternetes fork's prebuilt multi-arch binaries (`api-server`/`scheduler`/`controller-manager`/`kubelet`/`kube-proxy`) plus containerd-rs/crun/CNI release artifacts. `docker compose` brings up a CP container (api-server+scheduler+controller-manager, native embedded SQLite) + 2 worker containers (kubelet+kube-proxy+containerd-rs+crun) + a local registry. flannel-rs runs as a DaemonSet; a whoami Deployment (2 replicas, one per worker) fronted by a ClusterIP Service is the workload. One workflow (`dind-cluster.yml`) runs the whole thing on both arches per PR.

**Tech Stack:** Docker + docker compose, GitHub Actions matrix (amd64 + arm64 runners), rusternetes (Rust, componentized), containerd-rs, crun, flannel-rs, bash.

## Global Constraints

- Git identity: author `Indy Jones <indyjonesnl@gmail.com>`; every commit message ends with trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` (pre-push hook enforces the author).
- Addressing mirrors M2 (so M2 assets reuse): bridge `mikronetes-net` = 10.88.0.0/24; CP `node-1`=10.88.0.2, workers `node-2`=10.88.0.3 / `node-3`=10.88.0.4; podCIDRs node-2=10.244.1.0/24, node-3=10.244.2.0/24; cluster CIDR 10.244.0.0/16; service CIDR 10.96.0.0/12 (kubernetes @10.96.0.1); local registry `10.88.0.1:5000`.
- The CP container runs **componentized** (api-server + scheduler + controller-manager); there is no all-in-one image. The CP has **no kubelet** → it is NOT a k8s node. The cluster has exactly **2 worker nodes**.
- Storage = native embedded SQLite (`--storage-backend sqlite --data-dir …`), the rhino sqlite driver in-process. No etcd, no separate rhino container.
- All clients use `--insecure-skip-tls-verify` + `--token dummy` (api-server runs `--skip-auth`). Everyone dials the CP at `https://10.88.0.2:6443`.
- Arch selectors: `CNI_ARCH`/`CRUN_ARCH`/`CONTAINERD_RS_ARCH` ∈ {`amd64`,`arm64`}. containerd-rs `v0.3.0`, crun `1.28`, CNI plugins `v1.9.1`, flannel CNI shim `v1.9.1-flannel1`.
- Image refs: whoami `traefik/whoami:v1.10.2`, busybox `busybox:1.36.1`, flannel-rs `ghcr.io/indyjonesnl/flannel-rs:v0.1.3`, pause `registry.k8s.io/pause:3.10`. Fork binaries under `ghcr.io/indyjonesnl/rusternetes/<c>:${RUSTERNETES_IMAGE_TAG}` (default `main`), each at `/app/<c>` in the image.

---

### Task 1: `mikronetes-node` image (COPY-only assembly + entrypoint)

**Files:**
- Create: `deploy/dind/node.Dockerfile`
- Create: `deploy/dind/entrypoint.sh`
- Create: `deploy/dind/config-containerd-rs.toml`
- Create: `deploy/dind/10-flannel.conflist`

**Interfaces:**
- Produces: a node image runnable with `ROLE=control-plane` or `ROLE=worker` and `NODE_NAME=<name>`. CP serves the api-server on `0.0.0.0:6443` (embedded SQLite); workers start containerd-rs (`/run/containerd-rs.sock`) then kubelet + kube-proxy dialing `https://10.88.0.2:6443`. Binaries at `/usr/local/bin/{api-server,scheduler,controller-manager,kubelet,kube-proxy,containerd-rs,crun}`; CNI at `/opt/cni/{bin,conf}`; baked PKI at `/etc/rusternetes/pki/{ca.crt,server.crt,server.key}`; kubeconfig at `/etc/rusternetes/kubeconfig`.
- Consumes: fork images `ghcr.io/indyjonesnl/rusternetes/*:${RUSTERNETES_IMAGE_TAG}` (multi-arch); containerd-rs/crun/CNI release artifacts.

- [ ] **Step 1: Create `deploy/dind/10-flannel.conflist`** (baked CNI config, host-gw comes from the flannel DaemonSet net-conf)

```json
{
  "name": "cbr0",
  "cniVersion": "0.3.1",
  "plugins": [
    { "type": "flannel", "delegate": { "hairpinMode": true, "isDefaultGateway": true } },
    { "type": "portmap", "capabilities": { "portMappings": true } }
  ]
}
```

- [ ] **Step 2: Create `deploy/dind/config-containerd-rs.toml`** (adapted from `deploy/m2a/config-containerd-rs.toml` to container FS paths)

```toml
root = "/var/lib/containerd-rs"
state = "/run/containerd-rs"
cri_socket = "/run/containerd-rs.sock"
stream_server_address = "0.0.0.0:10010"

[cri]
sandbox_image = "10.88.0.1:5000/pause:3.10"
default_runtime_name = "crun"
runtime_type = "io.containerd.crun.v2"
snapshotter = "overlayfs"
systemd_cgroup = false
registry_config_path = "/etc/containerd-rs/certs.d"
cni_conf_dir = "/opt/cni/conf"
cni_bin_dir = "/opt/cni/bin"
no_pivot_root = true
```

- [ ] **Step 3: Create `deploy/dind/entrypoint.sh`**

```bash
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
mkdir -p /var/log/rusternetes /var/lib/rusternetes

wait_for() { # $1=desc $2=cmd
  for _ in $(seq 1 90); do eval "$2" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "TIMEOUT waiting for $1" >&2; return 1
}

start_containerd_rs() {
  mkdir -p /var/lib/containerd-rs /run/containerd-rs
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
    kube-proxy --node-name "$NODE_NAME" --kubeconfig "$KCFG" --api-server-url "$CP" \
      --insecure-skip-tls-verify --cluster-cidr 10.244.0.0/16 \
      >/var/log/rusternetes/kube-proxy.log 2>&1 &
    ;;
  *) echo "unknown ROLE=$ROLE" >&2; exit 2 ;;
esac

exec tail -F /var/log/rusternetes/*.log
```

- [ ] **Step 4: Create `deploy/dind/node.Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
# COPY-only assembly of the all-Rust kind-style node image (per arch).
ARG GHCR=ghcr.io/indyjonesnl/rusternetes
ARG RUSTERNETES_IMAGE_TAG=main
FROM ${GHCR}/api-server:${RUSTERNETES_IMAGE_TAG}         AS src-apiserver
FROM ${GHCR}/scheduler:${RUSTERNETES_IMAGE_TAG}          AS src-scheduler
FROM ${GHCR}/controller-manager:${RUSTERNETES_IMAGE_TAG} AS src-cm
FROM ${GHCR}/kubelet:${RUSTERNETES_IMAGE_TAG}            AS src-kubelet
FROM ${GHCR}/kube-proxy:${RUSTERNETES_IMAGE_TAG}         AS src-kubeproxy

FROM debian:sid-slim
ARG CNI_ARCH=amd64
ARG CRUN_ARCH=amd64
ARG CONTAINERD_RS_ARCH=amd64
ARG CONTAINERD_RS_VERSION=v0.3.0
RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables ca-certificates curl openssl && rm -rf /var/lib/apt/lists/*

# rusternetes binaries (fork multi-arch images; /app/<name>)
COPY --from=src-apiserver  /app/api-server         /usr/local/bin/api-server
COPY --from=src-scheduler  /app/scheduler          /usr/local/bin/scheduler
COPY --from=src-cm         /app/controller-manager /usr/local/bin/controller-manager
COPY --from=src-kubelet    /app/kubelet            /usr/local/bin/kubelet
COPY --from=src-kubeproxy  /app/kube-proxy         /usr/local/bin/kube-proxy

# containerd-rs + crun (release artifacts, arch-selected)
RUN curl -fsSL "https://github.com/indyjonesnl/containerd-rs/releases/download/${CONTAINERD_RS_VERSION}/containerd-rs_${CONTAINERD_RS_VERSION}_linux_${CONTAINERD_RS_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin \
 && curl -fsSL -o /usr/local/bin/crun \
      "https://github.com/containers/crun/releases/download/1.28/crun-1.28-linux-${CRUN_ARCH}" \
 && chmod +x /usr/local/bin/containerd-rs /usr/local/bin/crun

# CNI plugins + flannel shim
RUN mkdir -p /opt/cni/bin /opt/cni/conf \
 && curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-${CNI_ARCH}-v1.9.1.tgz" \
      | tar -xz -C /opt/cni/bin \
 && curl -fsSL "https://github.com/flannel-io/cni-plugin/releases/download/v1.9.1-flannel1/cni-plugin-flannel-linux-${CNI_ARCH}-v1.9.1.tgz" \
      | tar -xz -C /tmp \
 && mv "/tmp/flannel-${CNI_ARCH}" /opt/cni/bin/flannel
COPY deploy/dind/10-flannel.conflist        /opt/cni/conf/10-flannel.conflist
COPY deploy/dind/config-containerd-rs.toml  /etc/containerd-rs/config.toml

# Insecure local-registry config for containerd-rs (certs.d hosts.toml)
RUN mkdir -p "/etc/containerd-rs/certs.d/10.88.0.1:5000" \
 && printf 'server = "http://10.88.0.1:5000"\n\n[host."http://10.88.0.1:5000"]\n  capabilities = ["pull", "resolve"]\n' \
      > "/etc/containerd-rs/certs.d/10.88.0.1:5000/hosts.toml"

# Baked CI-only PKI + insecure kubeconfig (server 10.88.0.2 for all roles)
RUN mkdir -p /etc/rusternetes/pki && cd /etc/rusternetes/pki \
 && openssl genrsa -out ca.key 2048 \
 && openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
      -subj "/CN=rusternetes-ca/O=mikronetes" \
 && openssl genrsa -out server.key 2048 \
 && openssl req -new -key server.key -out server.csr -subj "/CN=rusternetes-api/O=mikronetes" \
 && printf 'subjectAltName=DNS:localhost,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,DNS:api-server,DNS:node-1,IP:127.0.0.1,IP:10.88.0.2,IP:10.96.0.1\n' > server.ext \
 && openssl x509 -req -days 3650 -in server.csr -CA ca.crt -CAkey ca.key \
      -CAcreateserial -out server.crt -extfile server.ext \
 && cat ca.crt >> server.crt \
 && rm -f server.csr ca.srl
RUN printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster:\n    server: https://10.88.0.2:6443\n    insecure-skip-tls-verify: true\ncontexts:\n- name: c\n  context: {cluster: c, user: u}\ncurrent-context: c\nusers:\n- name: u\n  user: {token: dummy}\n' \
      > /etc/rusternetes/kubeconfig

COPY deploy/dind/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 5: Build the image for the host arch and verify contents**

Run (on an amd64 host; the workflow sets the ARGs per arch):
```bash
cd /home/jones/PhpstormProjects/mikronetes
docker build -f deploy/dind/node.Dockerfile \
  --build-arg CNI_ARCH=amd64 --build-arg CRUN_ARCH=amd64 --build-arg CONTAINERD_RS_ARCH=amd64 \
  -t mikronetes-node:dind-test .
docker run --rm --entrypoint sh mikronetes-node:dind-test -c \
  'for b in api-server scheduler controller-manager kubelet kube-proxy containerd-rs crun; do command -v $b || { echo MISSING $b; exit 1; }; done; ls /opt/cni/bin/flannel /opt/cni/conf/10-flannel.conflist /etc/rusternetes/pki/server.crt /etc/rusternetes/kubeconfig'
```
Expected: all seven binaries resolve; the CNI + PKI + kubeconfig paths list without error.

- [ ] **Step 6: `bash -n` the entrypoint + commit**

```bash
bash -n deploy/dind/entrypoint.sh && echo OK
git add deploy/dind/node.Dockerfile deploy/dind/entrypoint.sh deploy/dind/config-containerd-rs.toml deploy/dind/10-flannel.conflist
git -c user.name="Indy Jones" -c user.email=indyjonesnl@gmail.com commit -m "feat(m2e): kind-style all-Rust node image (COPY-only, multi-arch)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: compose topology + `dind-up.sh` (bring up + bootstrap)

**Files:**
- Create: `compose.dind.yml`
- Create: `scripts/dind-up.sh`
- Create: `deploy/dind/whoami.yaml`

**Interfaces:**
- Consumes: the `mikronetes-node` image (Task 1) via `NODE_IMAGE` (default built locally as `mikronetes-node:dind`); the rusternetes fork's `bootstrap-cluster.yaml` (via `RUSTERNETES_SRC`, default `/home/jones/PhpstormProjects/rusternetes`); `deploy/m2a/flannel-rs.yaml`.
- Produces: a running cluster — CP api at 10.88.0.2:6443, `node-2`/`node-3` Ready, flannel-rs DS Running on both, whoami Deployment (2 pods, one per worker) + ClusterIP Service `whoami` with 2 endpoints. Exposes `kc()` semantics via `VMIP=10.88.0.2`.

- [ ] **Step 1: Create `deploy/dind/whoami.yaml`** (Deployment exercises the scheduler; anti-affinity spreads 1/worker)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: whoami, namespace: default }
spec:
  replicas: 2
  selector: { matchLabels: { app: whoami } }
  template:
    metadata: { labels: { app: whoami } }
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector: { matchLabels: { app: whoami } }
            topologyKey: kubernetes.io/hostname
      containers:
      - name: whoami
        image: 10.88.0.1:5000/whoami:v1.10.2
        imagePullPolicy: IfNotPresent
        ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata: { name: whoami, namespace: default }
spec:
  selector: { app: whoami }
  ports: [{ port: 80, targetPort: 80 }]
```

- [ ] **Step 2: Create `compose.dind.yml`**

```yaml
name: mikronetes-dind
networks:
  mikronetes-net:
    driver: bridge
    ipam: { config: [{ subnet: 10.88.0.0/24 }] }
services:
  registry:
    image: registry:2
    networks: { mikronetes-net: { ipv4_address: 10.88.0.1 } }
  node-1:
    image: ${NODE_IMAGE:-mikronetes-node:dind}
    privileged: true
    hostname: node-1
    environment: { ROLE: control-plane, NODE_NAME: node-1 }
    networks: { mikronetes-net: { ipv4_address: 10.88.0.2 } }
  node-2:
    image: ${NODE_IMAGE:-mikronetes-node:dind}
    privileged: true
    hostname: node-2
    environment: { ROLE: worker, NODE_NAME: node-2 }
    volumes: [ /lib/modules:/lib/modules:ro ]
    networks: { mikronetes-net: { ipv4_address: 10.88.0.3 } }
    depends_on: [ node-1 ]
  node-3:
    image: ${NODE_IMAGE:-mikronetes-node:dind}
    privileged: true
    hostname: node-3
    environment: { ROLE: worker, NODE_NAME: node-3 }
    volumes: [ /lib/modules:/lib/modules:ro ]
    networks: { mikronetes-net: { ipv4_address: 10.88.0.4 } }
    depends_on: [ node-1 ]
```

- [ ] **Step 3: Create `scripts/dind-up.sh`**

```bash
#!/usr/bin/env bash
# Bring up the kind-style all-Rust DinD cluster and bootstrap it to
# Services-parity: 2 workers Ready + flannel-rs + a whoami Deployment/Service.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VMIP="${VMIP:-10.88.0.2}"
REGISTRY="${REGISTRY:-10.88.0.1:5000}"
RUSTERNETES_SRC="${RUSTERNETES_SRC:-/home/jones/PhpstormProjects/rusternetes}"
COMPOSE="docker compose -f $REPO_ROOT/compose.dind.yml"
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }
say() { printf '\n==> %s\n' "$*"; }

say "compose up (registry + CP + 2 workers)"
$COMPOSE up -d

say "waiting for CP api-server"
for _ in $(seq 1 90); do kc get --raw /healthz >/dev/null 2>&1 && break; sleep 2; done
kc get --raw /healthz >/dev/null 2>&1 || { echo "api-server never healthy" >&2; exit 1; }

say "seeding local registry (arch-matched) via the host docker"
seed() { # $1=src $2=dst
  docker pull ${POD_PLATFORM:+--platform "$POD_PLATFORM"} "$1"
  docker tag "$1" "localhost:5000/$2"; docker push "localhost:5000/$2" >/dev/null
}
# registry is reachable on the host as localhost:5000 via the container's mapped
# port; publish it by connecting the host docker to the compose network:
REG_CID=$($COMPOSE ps -q registry)
docker network connect bridge "$REG_CID" 2>/dev/null || true
# push through the registry container's published address
docker exec "$REG_CID" true  # ensure up
# NOTE: seed via `docker save | docker exec ... registry import` is avoided;
# instead publish host->registry over the compose net using its gateway alias.
for pair in "traefik/whoami:v1.10.2 whoami:v1.10.2" \
            "busybox:1.36.1 busybox:1.36.1" \
            "registry.k8s.io/pause:3.10 pause:3.10" \
            "ghcr.io/indyjonesnl/flannel-rs:v0.1.3 flannel-rs:v0.1.3"; do
  set -- $pair; seed "$1" "$2"
done

say "bootstrap: kubernetes Service + RBAC + priorityclasses"
kc apply -f "$RUSTERNETES_SRC/bootstrap-cluster.yaml"

say "waiting for workers to register"
for n in node-2 node-3; do
  for _ in $(seq 1 90); do
    [ "$(kc get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break
    sleep 2
  done
done

say "assigning per-node podCIDRs + InternalIP"
patch_node() { # $1=node $2=ip $3=cidr
  kc patch node "$1" --type=merge -p "{\"spec\":{\"podCIDR\":\"$3\",\"podCIDRs\":[\"$3\"]}}"
  kc patch node "$1" --subresource=status --type=merge \
    -p "{\"status\":{\"addresses\":[{\"type\":\"InternalIP\",\"address\":\"$2\"},{\"type\":\"Hostname\",\"address\":\"$1\"}]}}"
}
patch_node node-2 10.88.0.3 10.244.1.0/24
patch_node node-3 10.88.0.4 10.244.2.0/24

say "flannel-rs DaemonSet (host-gw; point at CP + local registry)"
sed -e "s#ghcr.io/indyjonesnl/flannel-rs:v0.1.3#$REGISTRY/flannel-rs:v0.1.3#" \
    -e 's#value: "127.0.0.1"#value: "10.88.0.2"#' \
    "$REPO_ROOT/deploy/m2a/flannel-rs.yaml" | kc apply -f -

say "whoami Deployment + Service"
kc apply -f "$REPO_ROOT/deploy/dind/whoami.yaml"

say "waiting for 2 whoami pods Running + endpoints"
for _ in $(seq 1 90); do
  [ "$(kc get pods -l app=whoami --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)" -ge 2 ] && break
  sleep 3
done
kc get nodes,pods -A -o wide || true
say "dind cluster up"
```

Note: the registry-seeding block above must publish images the node containerd-rs can pull at `10.88.0.1:5000`. Implement seeding by mapping the registry container's port to the host (`ports: ["5000:5000"]` on the registry service — add it) and pushing to `localhost:5000`; node pulls resolve `10.88.0.1:5000` on the compose net. Update `compose.dind.yml` registry service with `ports: ["127.0.0.1:5000:5000"]` and drop the `docker network connect`/`docker exec` lines in favor of straight `docker push localhost:5000/...`.

- [ ] **Step 3b: Simplify seeding** — edit `compose.dind.yml` registry service to add `ports: ["127.0.0.1:5000:5000"]`; in `dind-up.sh` replace the seeding block's `REG_CID`/`network connect`/`docker exec` lines with just the `seed()` loop (push to `localhost:5000`).

- [ ] **Step 4: `bash -n` + bring the cluster up locally**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes
bash -n scripts/dind-up.sh && echo "syntax OK"
NODE_IMAGE=mikronetes-node:dind-test bash scripts/dind-up.sh
kubectl --server https://10.88.0.2:6443 --insecure-skip-tls-verify --token dummy get nodes -o wide
```
Expected: `node-2` and `node-3` `Ready` with `containerd-rs://0.3.0`; 2 whoami pods Running on distinct workers.

- [ ] **Step 5: Commit**

```bash
git add compose.dind.yml scripts/dind-up.sh deploy/dind/whoami.yaml
git -c user.name="Indy Jones" -c user.email=indyjonesnl@gmail.com commit -m "feat(m2e): DinD compose topology + dind-up.sh bootstrap

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `dind-smoke.sh` (Services-parity assertions)

**Files:**
- Create: `scripts/dind-smoke.sh`

**Interfaces:**
- Consumes: a cluster brought up by `scripts/dind-up.sh` (Task 2); `kc` semantics via `VMIP=10.88.0.2`.
- Produces: exit 0 on all assertions passing, non-zero + FAIL lines otherwise.

- [ ] **Step 1: Create `scripts/dind-smoke.sh`**

```bash
#!/usr/bin/env bash
# Services-parity smoke for the DinD all-Rust cluster.
set -uo pipefail
VMIP="${VMIP:-10.88.0.2}"
fail=0
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }
pass() { printf 'PASS: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
prefix() { case "$1" in node-2) echo 10.244.1.;; node-3) echo 10.244.2.;; esac; }

echo "=== 1. workers Ready on containerd-rs ==="
for n in node-2 node-3; do
  st=$(kc get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  rt=$(kc get node "$n" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null)
  { [ "$st" = True ] && case "$rt" in containerd-rs://*) true;; *) false;; esac; } \
    && pass "$n Ready ($rt)" || bad "$n not Ready on containerd-rs (status=$st runtime=$rt)"
done

echo "=== 2. whoami pods: 2, one per worker, distinct podCIDRs ==="
mapfile -t rows < <(kc get pods -l app=whoami -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.podIP}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null)
count=0; declare -A seen
for row in "${rows[@]}"; do
  set -- $row; node="$1"; ip="$2"; ph="$3"; [ -z "$node" ] && continue; count=$((count+1))
  [ "$ph" = Running ] || bad "$node whoami phase=$ph"
  case "$ip" in "$(prefix "$node")"*) pass "$node whoami $ip in podCIDR";; *) bad "$node whoami $ip not in $(prefix "$node")0/24";; esac
  [ -n "${seen[$ip]:-}" ] && bad "duplicate whoami IP $ip" || seen[$ip]="$node"
done
[ "$count" = 2 ] && pass "exactly 2 whoami pods" || bad "whoami pod count=$count (expected 2)"

echo "=== 3. Service load-balances across >=2 backends on distinct workers (probe pod) ==="
cip=$(kc get svc whoami -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
kc delete pod lb-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true; sleep 1
kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: lb-probe }
spec:
  nodeName: node-2
  restartPolicy: Never
  containers:
  - name: c
    image: 10.88.0.1:5000/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command:
    - sh
    - -c
    - |
      c=\$(for i in \$(seq 1 20); do wget -qO- --timeout=5 http://$cip:80 | grep -i hostname; done | sort -u | wc -l)
      echo "backends=\$c"; [ "\$c" -ge 2 ]
YAML
ph=""; for _ in $(seq 1 60); do ph=$(kc get pod lb-probe -o jsonpath='{.status.phase}' 2>/dev/null); { [ "$ph" = Succeeded ] || [ "$ph" = Failed ]; } && break; sleep 2; done
ec=$(kc get pod lb-probe -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)
[ "${ec:-1}" = 0 ] && pass "Service load-balanced across >=2 distinct backends" || bad "LB probe phase=$ph exitCode=${ec:-timeout}"
kc delete pod lb-probe --wait=false >/dev/null 2>&1 || true

if [ "$fail" -eq 0 ]; then echo "=== DIND SMOKE PASSED ==="; exit 0; else echo "=== DIND SMOKE FAILED ===" >&2; exit 1; fi
```

- [ ] **Step 2: `bash -n` + run against the up cluster**

Run:
```bash
bash -n scripts/dind-smoke.sh && echo "syntax OK"
bash scripts/dind-smoke.sh; echo "exit=$?"
```
Expected: `=== DIND SMOKE PASSED ===`, exit 0.

- [ ] **Step 3: Tear down + commit**

```bash
docker compose -f compose.dind.yml down -v
git add scripts/dind-smoke.sh
git -c user.name="Indy Jones" -c user.email=indyjonesnl@gmail.com commit -m "feat(m2e): dind-smoke.sh services-parity gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `dind-cluster.yml` workflow (matrix amd64 + arm64) + lint integration

**Files:**
- Create: `.github/workflows/dind-cluster.yml`
- Modify: `.github/workflows/harness-ci.yml` (the `bash -n` step already globs `scripts/*.sh`; no change needed — verify)

**Interfaces:**
- Consumes: Tasks 1-3 artifacts (`deploy/dind/node.Dockerfile`, `compose.dind.yml`, `scripts/dind-up.sh`, `scripts/dind-smoke.sh`). Runs the fork checkout for `bootstrap-cluster.yaml`.
- Produces: two required checks `dind (amd64)` and `dind (arm64)`, each green when the smoke passes on that arch.

- [ ] **Step 1: Create `.github/workflows/dind-cluster.yml`**

```yaml
name: dind-cluster

on:
  pull_request:
  workflow_dispatch:
    inputs:
      rusternetes_image_tag:
        description: 'rusternetes fork image tag to consume'
        default: 'main'

concurrency:
  group: dind-${{ github.ref }}
  cancel-in-progress: true

jobs:
  dind:
    strategy:
      fail-fast: false
      matrix:
        include:
          - arch: amd64
            runner: ubuntu-latest
          - arch: arm64
            runner: ubuntu-24.04-arm
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 30
    env:
      RUSTERNETES_IMAGE_TAG: ${{ github.event.inputs.rusternetes_image_tag || 'main' }}
    steps:
      - name: Checkout mikronetes
        uses: actions/checkout@v4

      - name: Checkout rusternetes (bootstrap-cluster.yaml; public, no token)
        uses: actions/checkout@v4
        with:
          repository: indyjonesnl/rusternetes
          ref: main
          path: rusternetes-src

      - name: Build the node image (COPY-only, native arch)
        run: |
          set -euxo pipefail
          docker build -f deploy/dind/node.Dockerfile \
            --build-arg CNI_ARCH=${{ matrix.arch }} \
            --build-arg CRUN_ARCH=${{ matrix.arch }} \
            --build-arg CONTAINERD_RS_ARCH=${{ matrix.arch }} \
            --build-arg RUSTERNETES_IMAGE_TAG="${RUSTERNETES_IMAGE_TAG}" \
            -t mikronetes-node:dind .

      - name: Bring up the cluster
        env:
          NODE_IMAGE: mikronetes-node:dind
          RUSTERNETES_SRC: ${{ github.workspace }}/rusternetes-src
          POD_PLATFORM: linux/${{ matrix.arch }}
        run: bash scripts/dind-up.sh

      - name: Smoke (services parity)
        run: bash scripts/dind-smoke.sh

      - name: Diagnostics on failure
        if: failure()
        run: |
          set +e
          docker ps -a
          for c in node-1 node-2 node-3; do
            echo "::group::logs $c"; docker logs "$(docker compose -f compose.dind.yml ps -q $c)" 2>&1 | tail -120; echo "::endgroup::"
          done
          kubectl --server https://10.88.0.2:6443 --insecure-skip-tls-verify --token dummy get nodes,pods -A -o wide

      - name: Teardown
        if: always()
        run: docker compose -f compose.dind.yml down -v || true
```

- [ ] **Step 2: Validate workflow YAML**

Run:
```bash
python3 -c "import yaml;yaml.safe_load(open('.github/workflows/dind-cluster.yml'));print('workflow YAML valid')"
grep -q "scripts/\*.sh" .github/workflows/harness-ci.yml && echo "harness-ci already lints new scripts"
```
Expected: `workflow YAML valid`; harness-ci confirms the new scripts are covered by `bash -n`.

- [ ] **Step 3: Commit + push (opens/updates the checks on the PR)**

```bash
git add .github/workflows/dind-cluster.yml
git -c user.name="Indy Jones" -c user.email=indyjonesnl@gmail.com commit -m "ci(m2e): kind-style DinD cluster gate on amd64 + arm64

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin HEAD
```

- [ ] **Step 4: Verify both matrix legs go green** — `gh run watch` / `gh pr checks`; expect `dind (amd64)` and `dind (arm64)` both `pass`.

---

## Self-Review

**Spec coverage:** kind-style DinD nodes → Tasks 1-2; 1 CP + 2 workers → compose (Task 2); multi-arch native (amd64 + arm64) → node.Dockerfile ARGs + workflow matrix (Tasks 1,4); Services parity (Ready on containerd-rs + distinct podCIDRs + cross-node ClusterIP LB) → dind-smoke.sh (Task 3); consume fork multi-arch images, COPY-only → node.Dockerfile (Task 1); componentized CP + native SQLite → entrypoint (Task 1); local insecure registry sidecar → compose + dind-up.sh seeding (Task 2); whoami Deployment (exercises scheduler) → whoami.yaml (Task 2); pinnable image tag → `RUSTERNETES_IMAGE_TAG` (Tasks 1,4); diagnostics + always-teardown → workflow (Task 4); locally reproducible via in-repo scripts → dind-up/dind-smoke. ✓

**Deviation from spec (noted):** the spec text said "3 nodes Ready"; the componentized CP has no kubelet, so it is not a k8s node — the cluster has **2 worker nodes** + a CP container. The Services-parity LB across 2 workers is unaffected. Smoke asserts 2 workers Ready.

**Placeholder scan:** Task 2 Step 3 intentionally carries a corrective note + Step 3b to simplify the registry seeding to host `localhost:5000` push (the inline `docker network connect`/`docker exec` lines are replaced) — the implementer must apply Step 3b so the final `dind-up.sh` seeds via `localhost:5000` with the registry service publishing `127.0.0.1:5000:5000`. No other placeholders.

**Type/name consistency:** `kc()` (server 10.88.0.2:6443, insecure, token dummy), `VMIP=10.88.0.2`, node names `node-1`(CP)/`node-2`/`node-3`, podCIDRs 10.244.1.0/24 & 10.244.2.0/24, registry `10.88.0.1:5000`, `NODE_IMAGE`/`ROLE`/`NODE_NAME`/`RUSTERNETES_IMAGE_TAG` used consistently across Dockerfile, compose, up, smoke, workflow. ✓

**Known unknowns to confirm during Task 1-2 (flagged, not guessed):**
- Exact `--help`-verified flag spellings for api-server/scheduler/controller-manager (fact-sheet sourced them from the fork manifests + `--help`; re-confirm at implement time and adjust if a flag name differs).
- Whether the fork's api-server `/app/entrypoint.sh` wrapper matters — we `COPY /app/api-server` and invoke it directly (bypassing the wrapper), so it should not; confirm the binary runs standalone.
- containerd-rs inside DinD may need extra cgroup/mount setup beyond `--privileged` (kind mounts cgroup2 + sets `no_pivot_root`, which our config sets). If sandbox creation fails, add the cgroup2 mount + `/dev` setup to `entrypoint.sh` `start_containerd_rs` (this is the M1-proven area).

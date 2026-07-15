# M2c-0 — Services Work on the MicroVM (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove a ClusterIP Service load-balances real cross-node traffic and DNS resolves the Service name, on the four-node 512 MiB Cloud-Hypervisor cluster, by enabling the all-in-one's embedded kube-proxy+DNS on node-1 and a standalone kube-proxy on each worker — which requires getting iptables userspace and the netfilter module closure into the guest image.

**Architecture:** Extends the M2b harness. node-1 runs the `rusternetes` all-in-one with embedded kube-proxy+DNS enabled; workers run a standalone `kube-proxy` machined service in API mode. The guest image gains iptables userspace (pinned Alpine apks) and the netfilter kernel modules. A ClusterIP Service fronts the existing `whoami` pods; a client pod proves DNS + load-balancing.

**Tech Stack:** Rust (rusternetes, machined-rs imager), Alpine v3.21 apks, musl-static binaries, Cloud-Hypervisor, iptables-nft, flannel host-gw.

## Global Constraints

- Every node caps at **512 MiB**; boot must not OOM.
- Git identity: **Indy Jones <indyjonesnl@gmail.com>**. End commit messages with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Guest binaries are **musl-static**; the guest runtime is **containerd-rs**, never Docker.
- CNI is **flannel host-gw**, per-node podCIDRs `10.244.0/1/2/3.0/24` (unchanged from M2b).
- Cluster CIDR passed to kube-proxy/all-in-one is **`10.244.0.0/16`**; cluster-dns ClusterIP is **`10.96.0.10`**.
- Pinned external artifacts use **Alpine v3.21 main/x86_64**; every apk needs a verified `sha256` (never guess a sha — derive it, Task 2).
- Repos: mikronetes `/home/jones/PhpstormProjects/mikronetes`, machined-rs `/home/jones/PhpstormProjects/machined-rs`, rusternetes `/home/jones/PhpstormProjects/rusternetes`.
- Work on branch `experiment/m2a` (current).

---

### Task 1: Add the netfilter module closure to the guest image

**Files:**
- Modify: `machined-rs/crates/imager/src/modules.rs` (the `VIRT_MODULES` array, ~line 71-91)

**Interfaces:**
- Produces: the guest boots with `nft_compat` + the `xt_*`/`nft_*` modules loaded, so `iptables-nft` / `iptables-restore` can program NAT rules. Consumed by Tasks 5, 8.

Already present in `VIRT_MODULES`: `virtio_blk, virtio_net, ext4, vfat, nls_cp437, nls_iso8859_1, nls_utf8, overlay, veth, bridge, br_netfilter, nf_tables, nf_nat, nf_conntrack`. kube-proxy's iptables-nft backend additionally needs the compat shim and the match/target modules its rules reference.

- [ ] **Step 1: Add the candidate module names**

Edit `machined-rs/crates/imager/src/modules.rs`, appending to `VIRT_MODULES` after `"nf_conntrack",`:

```rust
    // netfilter: iptables-nft compat shim + nat chain, for kube-proxy Services
    "nft_compat",
    "nft_chain_nat",
    "nf_nat",
    "nf_defrag_ipv4",
    "nf_reject_ipv4",
    // xt match/target modules kube-proxy's NAT rules use
    "xt_comment",
    "xt_mark",
    "xt_conntrack",
    "xt_statistic",
    "xt_nat",
    "xt_tcpudp",
    "xt_addrtype",
    "xt_multiport",
```

(`nf_nat` is already listed above; leaving the duplicate is harmless — `resolve_closure` dedupes — but you may drop the second line.)

- [ ] **Step 2: Rebuild the image to resolve the module closure**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && bash scripts/m2b-build-images.sh 2>&1 | tee /tmp/m2c0-build.log
```
Expected: either a clean build, or an abort of the form `module <name> not found in modules.dep`.

- [ ] **Step 3: Drop any module the kernel doesn't ship as a discrete `.ko`**

For each `module <name> not found in modules.dep` error, remove that exact name from the array (it means the custom kernel built that symbol into another module or `=y`, so it needs no explicit load). Re-run Step 2 until the build succeeds. Do **not** rename to guesses — only remove names the build rejects.

If the build rejects a module that is genuinely required (e.g. `nft_compat`), the custom kernel `.config` lacks it: stop and flag it — enabling it requires rebuilding the kernel via `machined-rs/scripts/build-kexec-kernel.sh` and re-pinning the release sha in `artifacts.toml` (a separate, larger task). Note it and continue with whatever the build accepts.

- [ ] **Step 4: Verify the modules landed in `modules.load`**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && \
  zcat out/m2b/boot/initramfs.img 2>/dev/null | cpio -t 2>/dev/null | grep -E 'nft_compat|xt_nat|nft_chain_nat' || \
  { mkdir -p /tmp/m2c0-ir && cd /tmp/m2c0-ir && zcat /home/jones/PhpstormProjects/mikronetes/out/m2b/boot/initramfs.img | cpio -idmv 2>/dev/null; grep -E 'nft_compat|xt_' etc/machined/modules.load; }
```
Expected: the accepted netfilter module paths appear in `etc/machined/modules.load`.

- [ ] **Step 5: Commit**

```bash
cd /home/jones/PhpstormProjects/machined-rs
git add crates/imager/src/modules.rs
git commit -m "feat(imager): add netfilter module closure for kube-proxy iptables-nft

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add iptables userspace to the guest rootfs

**Files:**
- Modify: `machined-rs/crates/imager/artifacts.toml` (the `x86_64 = [ ... ]` artifact list)

**Interfaces:**
- Produces: `/usr/sbin/iptables-nft`, `iptables-restore`, and the `libnftnl`/`libmnl` shared libs in the guest rootfs. Consumed by kube-proxy (Tasks 3-5, 8).

kube-proxy execs `/usr/sbin/iptables-nft` and `iptables-restore`. The minimal rootfs has neither. Add pinned Alpine apks following the existing e2fsprogs closure pattern. NEEDED-lib closure for Alpine `iptables`: `libnftnl.so.11` (apk `libnftnl`, which NEEDs `libmnl.so.0` = apk `libmnl`) and `libc.musl` (already present).

- [ ] **Step 1: Derive the exact versions + sha256 for the three apks**

Never guess a sha. Fetch the current v3.21 versions and hashes from the mirror:
```bash
cd /tmp
for pkg in iptables libnftnl libmnl; do
  base="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/x86_64"
  file=$(curl -fsSL "$base/" | grep -oE "${pkg}-[0-9][^\"]*\.apk" | grep -vE "${pkg}-(dev|doc|openrc|legacy)-" | sort -V | tail -1)
  url="$base/$file"
  sha=$(curl -fsSL "$url" | sha256sum | awk '{print $1}')
  echo "{ name = \"$pkg\", url = \"$url\", sha256 = \"$sha\", kind = \"apk\" },"
done
```
Expected: three ready-to-paste TOML lines with real URLs + shas. (Alpine `iptables` provides both the nft and legacy variants; no separate `iptables-nft` package.)

- [ ] **Step 2: Add the three apk entries**

Paste the three lines from Step 1 into the `x86_64 = [` list in `machined-rs/crates/imager/artifacts.toml`, immediately after the `libuuid` entry (keeping the apks grouped). Add a comment above them:
```toml
  # iptables userspace (iptables-nft + iptables-restore) for kube-proxy Services.
  # NEEDED closure: iptables -> libnftnl -> libmnl (+ musl, already present).
```

- [ ] **Step 3: Rebuild the image**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && bash scripts/m2b-build-images.sh 2>&1 | tee /tmp/m2c0-build2.log
```
Expected: clean build (the fetcher validates each sha; a mismatch aborts with a pin error).

- [ ] **Step 4: Verify iptables is in the initramfs rootfs**

Run:
```bash
cd /tmp && rm -rf m2c0-ir2 && mkdir m2c0-ir2 && cd m2c0-ir2 && \
  zcat /home/jones/PhpstormProjects/mikronetes/out/m2b/boot/initramfs.img | cpio -idmv 2>/dev/null; \
  ls -l usr/sbin/iptables* sbin/iptables* 2>/dev/null; \
  ls -l lib/libnftnl* lib/libmnl* usr/lib/libnftnl* usr/lib/libmnl* 2>/dev/null
```
Expected: an `iptables-nft` (or `xtables-nft-multi` with `iptables-nft` symlink) binary and the `libnftnl`/`libmnl` `.so` files are present.

- [ ] **Step 5: Commit**

```bash
cd /home/jones/PhpstormProjects/machined-rs
git add crates/imager/artifacts.toml
git commit -m "feat(imager): add iptables userspace apks (iptables/libnftnl/libmnl)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Build a musl-static kube-proxy binary and stage it into the worker overlay

**Files:**
- Create: `mikronetes/deploy/m2a/kube-proxy-musl.Dockerfile`
- Modify: `mikronetes/scripts/m2a-build-overlay.sh` (add a `REQUIRE_KUBEPROXY` build+stage block, mirroring the existing `REQUIRE_KUBELET` block ~lines 161-176)

**Interfaces:**
- Consumes: the rusternetes source at `RUSTERNETES_PARENT` (already used by the kubelet/aio Dockerfiles).
- Produces: `<worker-overlay>/bin/kube-proxy`, staged at `/boot/bin/kube-proxy` in the guest. Consumed by Task 4.

- [ ] **Step 1: Create the kube-proxy musl Dockerfile**

Create `mikronetes/deploy/m2a/kube-proxy-musl.Dockerfile`, copying `deploy/m2a/kubelet-musl.Dockerfile` verbatim but changing the package/binary and output. Contents:

```dockerfile
# syntax=docker/dockerfile:1
# musl-static rusternetes-kube-proxy for the mikronetes microVM worker overlay.
# Mirrors kubelet-musl.Dockerfile. Build context = PARENT of rusternetes/.
FROM rust:1.95-alpine AS build
RUN apk add --no-cache protobuf protobuf-dev cmake build-base perl sccache
ENV RUSTC_WRAPPER=sccache CARGO_INCREMENTAL=0 LIBZ_SYS_STATIC=1
WORKDIR /src
COPY rusternetes /src/rusternetes
WORKDIR /src/rusternetes
RUN cargo build --profile release-fast --features sqlite -p rusternetes-kube-proxy \
 && cp target/release-fast/kube-proxy /kube-proxy
FROM scratch AS out
COPY --from=build /kube-proxy /kube-proxy
```

(If the kubelet Dockerfile pins its context/COPY differently, match it exactly — read `deploy/m2a/kubelet-musl.Dockerfile` first and mirror its `COPY` layout so the rusternetes/rhino paths resolve.)

- [ ] **Step 2: Add the build+stage block to the overlay script**

In `mikronetes/scripts/m2a-build-overlay.sh`, immediately after the `REQUIRE_KUBELET` block (the `if [ "$REQUIRE_KUBELET" = 1 ]; then ... fi` around lines 161-176), add:

```bash
if [ "${REQUIRE_KUBEPROXY:-0}" = 1 ]; then
    KUBEPROXY_IMAGE="mikronetes-kube-proxy:m2c"
    if [ "${REBUILD_KUBEPROXY:-0}" != 1 ] && docker image inspect "$KUBEPROXY_IMAGE" >/dev/null 2>&1; then
        echo "==> kube-proxy image $KUBEPROXY_IMAGE already present — skipping build"
    else
        echo "==> building musl-static standalone kube-proxy"
        docker build \
            -f "$REPO_ROOT/deploy/m2a/kube-proxy-musl.Dockerfile" \
            -t "$KUBEPROXY_IMAGE" \
            "$RUSTERNETES_PARENT"
    fi
    kpid=$(docker create "$KUBEPROXY_IMAGE")
    docker cp "$kpid:/kube-proxy" "$OUT/bin/kube-proxy"
    docker rm "$kpid" >/dev/null
    chmod 0755 "$OUT/bin/kube-proxy"
fi
```

- [ ] **Step 3: Wire the flag through the worker overlay build**

In `mikronetes/scripts/m2b-build-images.sh`, in the `assembling shared worker overlay` invocation (the block around lines 49-54 that sets `REQUIRE_KUBELET=1`), add `REQUIRE_KUBEPROXY=1 \` to the env prefix so the worker overlay stages kube-proxy. Then add an assertion mirroring the kubelet one:

```bash
[ -x "$WORKER_OVERLAY/bin/kube-proxy" ] || {
  echo "ERROR: $WORKER_OVERLAY/bin/kube-proxy missing; rebuild mikronetes-kube-proxy:m2c" >&2
  exit 1
}
```

- [ ] **Step 4: Build and verify the binary is staged**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && bash scripts/m2b-build-images.sh 2>&1 | tail -20
file out/m2b/role-overlays/worker/bin/kube-proxy
```
Expected: `kube-proxy` exists and is an ELF static/musl executable.

- [ ] **Step 5: Commit**

```bash
cd /home/jones/PhpstormProjects/mikronetes
git add deploy/m2a/kube-proxy-musl.Dockerfile scripts/m2a-build-overlay.sh scripts/m2b-build-images.sh
git commit -m "feat(m2c): build musl kube-proxy + stage into worker overlay

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Add the kube-proxy service to worker configs

**Files:**
- Modify: `mikronetes/scripts/m2b-generate-configs.sh` (the worker `config.yaml` generation)

**Interfaces:**
- Consumes: `/boot/bin/kube-proxy` (Task 3), `/boot/kubelet.kubeconfig` (already staged for workers).
- Produces: each worker runs `kube-proxy` in API mode as a machined service. Consumed by Tasks 7, 8.

- [ ] **Step 1: Read the current worker service block**

Run:
```bash
grep -n "kubelet\|services:\|command:\|- id:" /home/jones/PhpstormProjects/mikronetes/scripts/m2b-generate-configs.sh | head -40
```
Note the exact YAML shape used for the worker `kubelet` `ServiceConfig` entry (indentation, `id`, `command`, `restart`, `depends_on`).

- [ ] **Step 2: Append a kube-proxy service entry to each worker config**

In the worker-config heredoc in `m2b-generate-configs.sh`, add a second service entry after the `kubelet` one, matching the file's existing indentation and using the node name variable already in scope (shown here as `${node}`):

```yaml
    - id: kube-proxy
      command:
        - /boot/bin/kube-proxy
        - --node-name
        - ${node}
        - --kubeconfig
        - /boot/kubelet.kubeconfig
        - --api-server-url
        - https://10.88.0.2:6443
        - --insecure-skip-tls-verify
        - "true"
        - --cluster-cidr
        - 10.244.0.0/16
      restart: on_failure
```

(Match the surrounding YAML exactly — `deny_unknown_fields` in machined's config parser rejects any stray key. `command` is `Vec<String>`; keep `"true"` quoted so it parses as a string arg.)

- [ ] **Step 3: Regenerate configs and verify**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && OUT=out/m2b bash scripts/m2b-generate-configs.sh
grep -A14 'id: kube-proxy' out/m2b/configs/node-2.yaml
```
Expected: the kube-proxy service block appears in `node-2.yaml` (and node-3/node-4), with `--node-name node-2` etc. Confirm `node-1.yaml` has **no** kube-proxy service (it uses the embedded one).

- [ ] **Step 4: Commit**

```bash
cd /home/jones/PhpstormProjects/mikronetes
git add scripts/m2b-generate-configs.sh
git commit -m "feat(m2c): run standalone kube-proxy as a machined service on workers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Enable embedded kube-proxy + DNS on node-1

**Files:**
- Modify: `mikronetes/scripts/m2b-generate-configs.sh` (the node-1 `rusternetes` service command)

**Interfaces:**
- Produces: node-1's all-in-one serves DNS on `0.0.0.0:53` and programs Service iptables locally. Consumed by Tasks 7, 8.

- [ ] **Step 1: Locate the node-1 rusternetes args**

Run:
```bash
grep -n "disable-proxy\|disable-dns\|rusternetes\|cluster-cidr\|cluster-dns\|data-dir" /home/jones/PhpstormProjects/mikronetes/scripts/m2b-generate-configs.sh
```
Expected: the node-1 command currently includes `--disable-proxy` and `--disable-dns`.

- [ ] **Step 2: Enable proxy + DNS and set cluster-cidr**

In the node-1 `rusternetes` `command` list in `m2b-generate-configs.sh`:
- Remove the `--disable-proxy` line.
- Remove the `--disable-dns` line.
- Add (matching the list's indentation):
  ```yaml
        - --cluster-cidr
        - 10.244.0.0/16
  ```
Leave `--storage-backend sqlite` and `--data-dir /var/lib/rusternetes/db` as they are for M2c-0 (persistent-DB relocation is an M2c-1 task). `--cluster-dns` already defaults to `10.96.0.10`.

- [ ] **Step 3: Regenerate and verify**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && OUT=out/m2b bash scripts/m2b-generate-configs.sh
grep -E 'disable-proxy|disable-dns|cluster-cidr' out/m2b/configs/node-1.yaml || echo "no disable flags (good)"
grep -A2 'cluster-cidr' out/m2b/configs/node-1.yaml
```
Expected: no `--disable-proxy` / `--disable-dns`; `--cluster-cidr 10.244.0.0/16` present.

- [ ] **Step 4: Commit**

```bash
cd /home/jones/PhpstormProjects/mikronetes
git add scripts/m2b-generate-configs.sh
git commit -m "feat(m2c): enable embedded kube-proxy + DNS on node-1 all-in-one

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: m2c-bootstrap.sh — taint node-1 and apply a ClusterIP Service

**Files:**
- Create: `mikronetes/scripts/m2c-bootstrap.sh`

**Interfaces:**
- Consumes: a running, bootstrapped M2b cluster (reuses `m2b-bootstrap.sh` for podCIDRs + flannel + whoami pods).
- Produces: node-1 tainted `NoSchedule`; a ClusterIP Service `whoami` (namespace `default`) selecting `app=m2b-whoami` (the label the m2b whoami pods already carry). Consumed by Task 7.

- [ ] **Step 1: Write the bootstrap script**

Create `mikronetes/scripts/m2c-bootstrap.sh`:

```bash
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
```

- [ ] **Step 2: Make it executable and syntax-check**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && chmod +x scripts/m2c-bootstrap.sh && bash -n scripts/m2c-bootstrap.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Commit**

```bash
cd /home/jones/PhpstormProjects/mikronetes
git add scripts/m2c-bootstrap.sh
git commit -m "feat(m2c): bootstrap — taint node-1, apply whoami ClusterIP Service

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: m2c-smoke.sh — assert DNS resolution and Service load-balancing

**Files:**
- Create: `mikronetes/scripts/m2c-smoke.sh`

**Interfaces:**
- Consumes: a cluster bootstrapped by `m2c-bootstrap.sh` (whoami pods + Service + kube-proxy on all nodes).
- Produces: pass/fail gate. This is the M2c-0 success criterion.

The whoami pods return an HTTP body containing a `Hostname:` line and their pod IP. A client `busybox` pod on a worker resolves the Service via DNS and curls the ClusterIP repeatedly; the gate asserts multiple distinct backend pods answer.

- [ ] **Step 1: Write the smoke gate (test-first — it will fail until the cluster is up in Task 8)**

Create `mikronetes/scripts/m2c-smoke.sh`:

```bash
#!/usr/bin/env bash
# M2c-0 smoke: kube-proxy Service load-balancing + DNS resolution.
set -uo pipefail
VMIP="${VMIP:-10.88.0.2}"
fail=0
pass() { printf 'PASS: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

echo "=== 1. worker kube-proxy services running ==="
for node in node-2 node-3 node-4; do
  ip=$(case $node in node-2) echo 10.88.0.3;; node-3) echo 10.88.0.4;; node-4) echo 10.88.0.5;; esac)
  if grep -qaE 'kube-proxy|RUSTERNETES-SERVICES|Applied .*rules' "out/m2b/$node/serial.log" 2>/dev/null; then
    pass "$node kube-proxy active in serial log"
  else
    bad "$node kube-proxy not evidenced in serial log"
  fi
done

echo "=== 2. Service has endpoints ==="
cip=$(kc get svc whoami -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
n=$(kc get endpointslice -l kubernetes.io/service-name=whoami -o jsonpath='{.items[*].endpoints[*].addresses[0]}' 2>/dev/null | wc -w)
[ -n "$cip" ] && [ "$n" -ge 2 ] && pass "whoami ClusterIP=$cip endpoints=$n" || bad "whoami ClusterIP='$cip' endpoints=$n (expected >=2)"

echo "=== 3. run a client pod on node-2 for in-cluster checks ==="
kc delete pod m2c-client --ignore-not-found --wait=false >/dev/null 2>&1 || true
kc apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: m2c-client, labels: { app: m2c-client } }
spec:
  nodeName: node-2
  restartPolicy: Never
  containers:
  - name: c
    image: 10.88.0.1:5000/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command: ["sh","-c","sleep 3600"]
YAML
ok=0
for _ in $(seq 1 60); do
  [ "$(kc get pod m2c-client -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && ok=1 && break
  sleep 2
done
[ "$ok" = 1 ] && pass "client pod Running" || { bad "client pod not Running"; echo "=== M2c-0 SMOKE FAILED ==="; exit 1; }

echo "=== 4. DNS resolves the Service name to its ClusterIP ==="
resolved=$(kc exec m2c-client -- nslookup whoami.default.svc.cluster.local 2>/dev/null | awk '/^Address: /{a=$2} END{print a}')
[ "$resolved" = "$cip" ] && pass "DNS whoami.default.svc.cluster.local -> $resolved" || bad "DNS resolved '$resolved' != ClusterIP '$cip'"

echo "=== 5. Service load-balances across distinct backend pods ==="
seen=$(for _ in $(seq 1 20); do
  kc exec m2c-client -- wget -qO- --timeout=5 "http://$cip:80" 2>/dev/null | awk -F'[:=]' '/Hostname/{gsub(/ /,"",$2);print $2}'
done | sort -u)
count=$(printf '%s\n' "$seen" | grep -c . )
echo "distinct backends hit: $count"; printf '%s\n' "$seen"
[ "$count" -ge 2 ] && pass "load-balanced across $count backends" || bad "only $count backend(s) answered (kube-proxy DNAT not spreading)"

kc delete pod m2c-client --ignore-not-found --wait=false >/dev/null 2>&1 || true
if [ "$fail" -eq 0 ]; then echo "=== M2c-0 SMOKE PASSED ==="; exit 0; else echo "=== M2c-0 SMOKE FAILED ===" >&2; exit 1; fi
```

- [ ] **Step 2: Make executable + syntax-check**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && chmod +x scripts/m2c-smoke.sh && bash -n scripts/m2c-smoke.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Commit**

```bash
cd /home/jones/PhpstormProjects/mikronetes
git add scripts/m2c-smoke.sh
git commit -m "test(m2c): smoke — DNS resolution + Service load-balancing gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Integration — build, boot, bootstrap, smoke

**Files:** none (runs the harness end-to-end)

**Interfaces:**
- Consumes: all prior tasks. This is the M2c-0 acceptance run.

- [ ] **Step 1: Rebuild images (picks up modules + iptables + kube-proxy) and boot fresh**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes
bash scripts/m2b-down.sh || true
bash scripts/m2b-build-images.sh 2>&1 | tail -15
bash scripts/m2b-up-ch.sh 2>&1 | tail -30
```
Expected: all four nodes reach `Ready` (as in M2b).

- [ ] **Step 2: Bootstrap M2c-0**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && bash scripts/m2c-bootstrap.sh 2>&1 | tail -30
```
Expected: node-1 tainted; `whoami` Service gets a ClusterIP; EndpointSlice lists the whoami pod IPs.

- [ ] **Step 3: Verify kube-proxy actually programmed iptables (diagnostic)**

Run:
```bash
kc() { kubectl --server "https://10.88.0.2:6443" --insecure-skip-tls-verify --token dummy "$@"; }
for n in node-2 node-3 node-4; do echo "== $n =="; grep -aiE 'kube-proxy|iptables|RUSTERNETES-SERVICES|Could not fetch rule set' out/m2b/$n/serial.log | tail -5; done
```
Expected: kube-proxy applying rules; **no** `Could not fetch rule set generation id` (that would mean Task 1/2 modules/userspace are still incomplete — return to those tasks).

- [ ] **Step 4: Run the smoke gate**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && bash scripts/m2c-smoke.sh 2>&1 | tee /tmp/m2c0-smoke.log
```
Expected: `=== M2c-0 SMOKE PASSED ===`, including DNS resolving `whoami.default.svc.cluster.local` to the ClusterIP and ≥2 distinct backends answering.

- [ ] **Step 5: If load-balancing or DNS fails, debug via the mechanism, not guesses**

If step 4 fails at LB or DNS: pull the failing node's kube-proxy evidence and the all-in-one DNS logs:
```bash
kc logs -n kube-flannel <any-flannel-pod>  # sanity: pod networking still up
grep -aiE 'dns|:53|kube-proxy|iptables|nft' out/m2b/node-1/serial.log | tail -30
```
Common causes, each tied to a prior task: missing xt module (Task 1), missing iptables binary (Task 2), worker kube-proxy not started (Task 4 config), embedded proxy/DNS still disabled (Task 5). Fix at the root task and re-run from Step 1.

- [ ] **Step 6: Commit the acceptance evidence (optional log capture)**

No code change; the milestone is proven by the passing smoke. If you keep a run log, commit it under `docs/` — otherwise stop here. M2c-0 is complete when `m2c-smoke.sh` exits 0.

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-07-09-...-design.md`, M2c-0 scope):
- iptables userspace in rootfs → Task 2. ✓
- netfilter module closure → Task 1. ✓
- embedded kube-proxy+DNS on node-1 → Task 5. ✓
- standalone kube-proxy on workers → Tasks 3 (build) + 4 (config). ✓
- ClusterIP Service + endpoints → Task 6. ✓
- DNS resolution + load-balancing gate → Task 7, run in Task 8. ✓
- kube-proxy running assertion + memory note → Task 7 (memory table extension deferred to M2c-1, where the PHP process is added; M2c-0 reuses M2b's whoami/memprobe unchanged). ✓

**Placeholder scan:** the only deliberately-derived-at-runtime values are the Alpine apk versions/shas (Task 2 Step 1) — a procedure that yields exact values, because pins must be verified not guessed. Module set (Task 1) is a concrete candidate list with an explicit build-driven prune rule. No `TODO`/`TBD`.

**Type/name consistency:** Service name `whoami`, label selector `app=m2b-whoami` (the label m2b's whoami pods carry — verify against `m2b-bootstrap.sh` when implementing Task 6), namespace `default`, ClusterIP var `cip`, client pod `m2c-client` — consistent across Tasks 6-8.

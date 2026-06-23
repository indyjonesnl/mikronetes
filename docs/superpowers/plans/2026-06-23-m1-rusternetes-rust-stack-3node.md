# M1 — 3-node rusternetes on containerd-rs + crun + flannel-rs (containers, measured)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) tracking. This is infra/integration work — "tests" are verification commands (image builds, nodes Ready on the right runtime, pod served cross-node, memory table produced), not unit tests.

**Goal:** A 1 control-plane + 2 worker rusternetes cluster whose data plane is **containerd-rs (CRI) + crun (OCI) + flannel-rs (CNI)**, converging and serving a pod cross-node, with a per-component memory breakdown. Fast env (docker compose). Dress rehearsal for M2 (Cloud Hypervisor microVMs).

**Architecture:** rusternetes `fork/main` ships the node as upstream-containerd + youki; M1 **replaces that runtime** with containerd-rs (serving CRI at `/run/containerd-rs.sock`) + crun, points the rusternetes kubelet at it via `CONTAINER_RUNTIME_ENDPOINT`, and keeps flannel-rs for CNI. Control plane (api-server + scheduler + controller-manager + DNS) is unchanged; storage is rhino (shared sqlite-over-etcd-API). Reuses the **containerd-rs v0.1.1 fixes** (branch `fix/k0s-worker-cri-gaps` in `../containerd-rs`: CRI fail-retry, pod cgroups, image-User, UpdateRuntimeConfig, streaming-pull).

**Tech Stack:** rusternetes (indyjonesnl `fork/main`, worktree `/home/jones/PhpstormProjects/rusternetes-m1`), containerd-rs (v0.1.1), crun, flannel-rs (`deploy/flannel/flannel-rs.yaml`), rhino, docker compose, the mikronetes `mem-breakdown.{sh,py}`.

## Global Constraints
- **Measure-only — NO 512 MB cap in M1.** 512 MiB stays a reference line; the cap lands in M2 (microVM guest RAM).
- The data plane MUST be containerd-rs + crun + flannel-rs (user directive), even though fork/main defaults to containerd+youki and our memory data rates containerd-rs low-leverage/heavy — accepted risk.
- Do not modify rusternetes source beyond the node-runtime swap + trivial unblocks; call out any rusternetes edit as its own step.
- Work in the `rusternetes-m1` worktree (branch `mikronetes/m1`) + `../containerd-rs`; harness scripts + recorded results land in the mikronetes repo.
- Commits: identity `Indy Jones <indyjonesnl@gmail.com>` (repo-local) + trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## Task 1 — De-risking spike: containerd-rs + crun under the rusternetes kubelet (single node)

The biggest unknown: does rusternetes' kubelet (its `crates/cri` client) drive **containerd-rs** cleanly, and does crun work under it? Prove on ONE node before the 3-node build.

- [ ] **Step 1:** Confirm the containerd-rs v0.1.1 binary is available — build the static musl binary from the fix branch.
  Run: `cd /home/jones/PhpstormProjects/containerd-rs-k0sfix && git log --oneline -1 && cargo build --release --target x86_64-unknown-linux-musl -p containerd-rs`
  Expected: binary at `…/x86_64-unknown-linux-musl/release/containerd-rs`. (If the worktree is gone, recreate it off `fix/k0s-worker-cri-gaps`.)
- [ ] **Step 2:** Build a node-cdrs image — base on fork/main's node (`/home/jones/PhpstormProjects/rusternetes-m1/Dockerfile.node`'s runtime base), but: install crun (`apk add crun` or distro pkg), copy the containerd-rs binary to `/usr/local/bin/containerd-rs`, drop a containerd-rs `config.toml` (cri_socket `/run/containerd-rs.sock`, cni dirs `/etc/cni/net.d` + `/opt/cni/bin`, `systemd_cgroup=false`), `ln -sf "$(command -v crun)" /usr/local/bin/runc` (containerd-rs invokes the OCI runtime as `runc` on PATH), and a node entrypoint that launches `containerd-rs` (not containerd), waits for `/run/containerd-rs.sock`, then `exec kubelet` with `CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd-rs.sock`. Write this as `deploy/node-cdrs/Dockerfile` + `entrypoint.sh` in the worktree.
  Run: `docker build -f deploy/node-cdrs/Dockerfile -t rusternetes-node-cdrs:m1 .`
  Expected: image builds; `docker run --rm rusternetes-node-cdrs:m1 sh -c 'containerd-rs --help; crun --version; readlink -f /usr/local/bin/runc'` shows crun.
- [ ] **Step 3:** Standalone daemon check: `docker run --rm --privileged --entrypoint sh rusternetes-node-cdrs:m1 -c 'containerd-rs --config /etc/containerd-rs/config.toml & sleep 8; test -S /run/containerd-rs.sock && echo SOCKET_OK'`. Expected: `SOCKET_OK`.
- [ ] **Step 4:** Commit the node-cdrs image assets (in the rusternetes-m1 worktree).
  `git add deploy/node-cdrs && git commit -m "feat(m1): node image running containerd-rs + crun (Co-Authored-By: …)"`

## Task 2 — One rusternetes node on containerd-rs+crun reaches Ready

- [ ] **Step 1:** Author `compose.cdrs-flannel.yml` (worktree) = a copy of `compose.flannel.yml` with `node-1`/`node-2` switched to `image: rusternetes-node-cdrs:m1` (+ the containerd-rs socket/volumes), keeping rhino + api-server + scheduler + controller-manager + kube-proxy. For Task 2, scale to api-server + node-1 only.
- [ ] **Step 2:** Bring up control plane + node-1: `docker compose -f compose.cdrs-flannel.yml up -d rhino api-server node-1` then the cert/bootstrap path the cluster needs (see `scripts/generate-certs.sh`; bootstrap in Task 4).
- [ ] **Step 3:** Verify node-1 registers and the kubelet is on containerd-rs: `kubectl get node node-1 -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}'` shows a containerd-rs identity (not containerd://upstream); and `docker exec rusternetes-node-1 ls -S /run/containerd-rs.sock`.
  Expected: node-1 `Ready`, runtime = containerd-rs. If it fails, debug via the containerd-rs log + the v0.1.1 gap notes (CNI fail-retry / pod cgroup / image-User) — those fixes were for k0s's kubelet; confirm they hold under rusternetes' kubelet.
- [ ] **Step 4:** Commit the compose. (`git add compose.cdrs-flannel.yml && git commit …`)

## Task 3 — crun actually runs the container

- [ ] **Step 1:** Deploy a trivial pod to node-1: `kubectl run hello --image=traefik/whoami:v1.10.2 --overrides '{"spec":{"nodeName":"node-1"}}'` (no CNI needed yet if hostNetwork; else after Task 5).
- [ ] **Step 2:** Verify crun ran it: on node-1, `docker exec rusternetes-node-1 sh -c 'ps -ef | grep -c crun'` ≥1 during create, and the containerd-rs log shows the `runc`(→crun) invocation succeeding (exit 0). Expected: pod `Running` via crun.
- [ ] **Step 3:** No commit (verification only).

## Task 4 — 3-node bring-up + bootstrap + node-IPAM

- [ ] **Step 1:** Bring up the full set: `docker compose -f compose.cdrs-flannel.yml up -d` (rhino, api-server, scheduler, controller-manager, node-1, node-2, kube-proxy-1/2).
- [ ] **Step 2:** Bootstrap with node-IPAM so each node gets `spec.podCIDR` (flannel derives its subnet from it): `ALLOCATE_NODE_CIDRS=1 CLUSTER_CIDR=10.244.0.0/16 bash scripts/bootstrap-cluster.sh` (uses the in-tree `target/release/kubectl` or `$KUBECTL`, `--server https://localhost:6443 --insecure-skip-tls-verify`).
  Expected: both nodes registered, static control-plane pods present, each node has a `spec.podCIDR` within `10.244.0.0/16`.
- [ ] **Step 3:** Verify: `kubectl get nodes -o wide` → node-1 + node-2 `Ready`, runtime containerd-rs on both. (Gate fails → debug per Task 2.)

## Task 5 — flannel-rs CNI, cross-node pod networking

- [ ] **Step 1:** Apply flannel-rs: `kubectl apply -f deploy/flannel/flannel-rs.yaml`. Confirm its `net-conf "Network"` matches `CLUSTER_CIDR=10.244.0.0/16` (the #1187/#1194 caveat) — edit the manifest's net-conf if needed.
- [ ] **Step 2:** Wait for the flannel-rs DaemonSet Ready on both nodes; confirm `/etc/cni/net.d` + `/opt/cni/bin` populated inside each node (`docker exec rusternetes-node-1 ls /etc/cni/net.d`).
- [ ] **Step 3:** Cross-node test: deploy 2 whoami pods pinned to node-1 and node-2 (nodeName), get their pod IPs, and from the node-1 pod `curl` the node-2 pod IP (and vice-versa) — proves flannel-rs VXLAN routes pod-to-pod **across nodes**.
  Expected: both cross-node curls return the whoami `Hostname`. (If stuck: flannel-rs subnet/VXLAN — check flannel-rs logs + each node's `flannel.1` device + `subnet.env`.)
- [ ] **Step 4:** No commit (verification); capture the result for the report.

## Task 6 — Per-component memory breakdown + mikronetes harness

- [ ] **Step 1:** Adapt `mikronetes/scripts/mem-breakdown.sh` container list to the rusternetes containers (`rusternetes-rhino`, `rusternetes-api-server`, `rusternetes-node-1`, `rusternetes-node-2`, `rusternetes-kube-proxy-*`) — parameterize the container list rather than hardcoding.
- [ ] **Step 2:** Run it against the live cluster → per-component PSS table (rusternetes api-server/scheduler/cm, kubelet, **containerd-rs**, **crun**, flannel-rs, rhino, kube-proxy). Record it.
- [ ] **Step 3:** Author `mikronetes/scripts/m1-up.sh` (build node-cdrs → compose up → bootstrap → apply flannel-rs) and `mikronetes/scripts/m1-smoke.sh` (gate: 2 nodes Ready on containerd-rs + cross-node pod served + emit the memory breakdown). Wrap the verified Task 1-5 commands.
- [ ] **Step 4:** Record the M1 result + memory table in `docs/` and a memory note; compare to k0s (control-plane node ~588 MiB, workers ~340 MiB) and to the rusternetes idle control plane (~48 MiB). Commit the harness + result.
  `git add scripts/m1-*.sh docs/… && git commit -m "feat(m1): mikronetes M1 harness + recorded Rust-stack memory breakdown (Co-Authored-By: …)"`

---

## Self-Review
- **Spec coverage:** containerd-rs+crun+flannel-rs data plane (Tasks 1-5) ✅; 3-node cp+2-worker (Task 4) ✅; cross-node serve (Task 5) ✅; per-component memory breakdown (Task 6) ✅; measure-only/no-cap (Global Constraints) ✅; mikronetes harness (Task 6) ✅.
- **Known risk surfaced:** forcing containerd-rs+crun re-enters the canary's hard territory under a *different* kubelet (rusternetes vs k0s); the v0.1.1 fixes were validated against k0s's kubelet only — Task 1-2 is the de-risking spike. Per the memory data this is low-leverage (containerd ≈63 MiB/node); the user accepted that trade.
- **Placeholders:** none — exact compose/commands derived from the verified `fork/main` files (`compose.flannel.yml` recipe, node entrypoint, `bootstrap-cluster.sh` flags, flannel net-conf caveat). The only authored-new assets are the node-cdrs Dockerfile/entrypoint + `compose.cdrs-flannel.yml` (Tasks 1-2), specified concretely.
- **Open dependency:** containerd-rs v0.1.1 lives on an unmerged branch in `../containerd-rs`; Task 1 rebuilds from it.

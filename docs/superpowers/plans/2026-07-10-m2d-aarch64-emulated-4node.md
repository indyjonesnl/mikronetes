# M2d — Four-Node Cluster on Emulated aarch64 (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the full M2c-1 four-node cluster (Services + DNS + PHP DaemonSet) on aarch64 artifacts under `qemu-system-aarch64` (TCG) on the x86_64 dev box, proving the stack is arch-portable before real Pi 3A+ hardware (M2e).

**Architecture:** Same topology/harness as M2c-1; only the CPU arch (arm64) and VMM (`qemu-system-aarch64 -M virt -cpu cortex-a53`, TCG, no KVM) change. The arch-agnostic `m2b-net.sh`/`m2c1-bootstrap.sh`/`m2c1-smoke.sh` are reused; the work is producing arm64 artifacts + an emulated-aarch64 launcher + TCG-scaled timeouts.

**Tech Stack:** qemu-system-aarch64 (TCG), Alpine linux-virt aarch64, aarch64-unknown-linux-musl, docker buildx (arm64 emulation), containerd-rs v0.3.0 arm64, crun arm64.

## Global Constraints

- Every node caps at **512 MiB**; no OOM. Report node-1 arm64 control-plane RSS vs the cap.
- Git identity **Indy Jones <indyjonesnl@gmail.com>**; commit trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Emulated aarch64 only** (dev box is x86_64 → TCG, no KVM). Real Pi (linux-rpi) is M2e.
- Artifacts: the pinned **`aarch64`** linux-virt set (NOT `aarch64-rpi`).
- Reuse `m2b-net.sh`, `m2c1-bootstrap.sh`, `m2c1-smoke.sh` unchanged where possible; durability stays gated (`DURABILITY=1`); exec/logs already work (v0.3.0 + `CONTAINERD_STREAM_HOST=127.0.0.1`).
- containerd-rs pin is **v0.3.0**, `CONTAINERD_RS_ARCH=arm64`.
- Repos: mikronetes `/home/jones/PhpstormProjects/mikronetes` (branch `experiment/m2a`); machined-rs `/home/jones/PhpstormProjects/machined-rs` (feature branch for its changes).
- Verified prereq facts: `containerd-rs_v0.3.0_linux_arm64.tar.gz` = HTTP 200; imager `arch_config("aarch64")` exists; machined `Makefile` has `dist-aarch64` (needs `aarch64-linux-gnu-gcc`) + `boot-test-aarch64`.

---

### Task 1: Host prerequisites (operator step — not automatable here)

**Files:** none (host packages).

`qemu-system-aarch64` is not installed, the aarch64 cross-linker is absent, and binfmt arm64 (for emulated buildx) isn't registered. These need root (`sudo apt`), which the agent can't run. The operator runs, in the session, via the `!` prefix:

- [ ] **Step 1: Install packages + binfmt**

```
! sudo apt-get update && sudo apt-get install -y qemu-system-arm gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
! docker run --privileged --rm tonistiigi/binfmt --install arm64
```

- [ ] **Step 2: Verify**

Run:
```bash
which qemu-system-aarch64 && aarch64-linux-gnu-gcc --version | head -1 && \
  ls /proc/sys/fs/binfmt_misc/qemu-aarch64 && docker buildx ls | grep -q . && echo "PREREQS OK"
```
Expected: all present + `PREREQS OK`. Do not proceed to build tasks until this passes.

---

### Task 2: machined-rs — aarch64 iptables userspace apks

**Files:**
- Modify: `machined-rs/crates/imager/artifacts.toml` (the `aarch64 = [ ... ]` list)

**Interfaces:**
- Produces: arm64 `/usr/sbin/iptables-nft` + lib closure in the aarch64 rootfs, so kube-proxy works on arm64. Consumed by Tasks 5, 9.

Mirror the x86_64 iptables apk work (already merged) for aarch64. machined-rs is on a feature branch (not main).

- [ ] **Step 1: Create/checkout a feature branch**

```bash
cd /home/jones/PhpstormProjects/machined-rs && git checkout main && git pull --ff-only 2>/dev/null; git checkout -b feat/m2d-aarch64-iptables
```

- [ ] **Step 2: Derive the aarch64 apk pins**

```bash
cd /tmp
for pkg in iptables libxtables libnftnl libmnl; do
  base="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64"
  file=$(curl -fsSL "$base/" | grep -oE "${pkg}-[0-9][^\"]*\.apk" | grep -vE "${pkg}-(dev|doc|openrc|legacy)-" | sort -V | tail -1)
  url="$base/$file"; sha=$(curl -fsSL "$url" | sha256sum | awk '{print $1}')
  echo "{ name = \"$pkg\", url = \"$url\", sha256 = \"$sha\", kind = \"apk\" },"
done
```

- [ ] **Step 3: Add the four lines** to the `aarch64` list in `artifacts.toml` (after `libuuid`), with a comment mirroring the x86_64 block. Update the "Same closure as x86_64 EXCEPT iptables x86_64-only" comment to note aarch64 now has them too.

- [ ] **Step 4: Verify + commit**

```bash
cd /home/jones/PhpstormProjects/machined-rs && cargo test -p machined-imager 2>&1 | tail -3
git add crates/imager/artifacts.toml
git commit -m "feat(imager): aarch64 iptables userspace apks for kube-proxy

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(If a build-test fixture asserts arch parity and fails, extend it the same way the x86_64 netfilter fixture was.)

---

### Task 3: Overlay build — arm64 crun + containerd-rs

**Files:**
- Modify: `mikronetes/scripts/m2a-build-overlay.sh` (crun URL + containerd-rs arch)

**Interfaces:**
- Consumes: `CONTAINERD_RS_ARCH`, a new `ARCH`/crun-arch selector.
- Produces: arm64 `crun` + `containerd-rs` in the overlay when building aarch64. Consumed by Task 5.

- [ ] **Step 1: Parameterize crun by arch**

The crun URL is hardcoded amd64 (`m2a-build-overlay.sh:225`). Replace with an arch-selected URL:
```bash
CRUN_ARCH="${CRUN_ARCH:-amd64}"   # amd64 | arm64
CRUN_URL="https://github.com/containers/crun/releases/download/1.28/crun-1.28-linux-${CRUN_ARCH}"
```
(Both `crun-1.28-linux-amd64` and `crun-1.28-linux-arm64` are published.)

- [ ] **Step 2: containerd-rs arch already supported** — `CONTAINERD_RS_ARCH=arm64` is honored by `install_containerd_rs` (downloads `containerd-rs_v0.3.0_linux_arm64.tar.gz`, verified HTTP 200). No change; just pass it from the build driver (Task 5).

- [ ] **Step 3: Commit**

```bash
cd /home/jones/PhpstormProjects/mikronetes
git add scripts/m2a-build-overlay.sh
git commit -m "feat(m2d): select crun arch in the overlay build (arm64)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: arm64 cross-builds of the musl overlay images

**Files:**
- Modify: `mikronetes/scripts/m2a-build-overlay.sh` (aio/kubelet/kube-proxy image builds → `--platform`)
- Modify: `mikronetes/scripts/m2c1-bootstrap.sh` (rusternetes-dns image build → `--platform`)

**Interfaces:**
- Produces: arm64 `mikronetes-aio`/`mikronetes-kubelet`/`mikronetes-kube-proxy`/`rusternetes-dns` images. Consumed by Tasks 5, 9.

- [ ] **Step 1: Add a `TARGETPLATFORM` arg to each `docker build`**

For the all-in-one, kubelet, and kube-proxy builds in `m2a-build-overlay.sh` and the rusternetes-dns build in `m2c1-bootstrap.sh`, thread a `PLATFORM` env (default `linux/amd64`) into `docker build --platform "$PLATFORM"`. The `rust:1.95-alpine` base is multi-arch; buildx with the arm64 binfmt (Task 1) cross-builds. Extract each binary with `docker create`/`cp` as today (the emulated image runs under binfmt on `docker create`? No — use `docker buildx build --platform linux/arm64 --output type=local` OR keep `docker build --platform` + `docker create` which works for extraction without executing the binary). Tag images `:m2d-arm64` to avoid clobbering the amd64 `:m2a`/`:m2b`/`:m2c` tags.

- [ ] **Step 2: Verify one arm64 binary**

Run (after Task 1 binfmt):
```bash
cd /home/jones/PhpstormProjects
PLATFORM=linux/arm64 docker build --platform linux/arm64 -f mikronetes/deploy/m2a/kube-proxy-musl.Dockerfile -t mikronetes-kube-proxy:m2d-arm64 . 2>&1 | tail -5
cid=$(docker create --platform linux/arm64 mikronetes-kube-proxy:m2d-arm64); docker cp "$cid:/app/kube-proxy" /tmp/kp-arm64; docker rm "$cid" >/dev/null
file /tmp/kp-arm64   # expect: ELF 64-bit LSB ... ARM aarch64
```
Expected: `ARM aarch64` ELF.

- [ ] **Step 3: Commit** (both scripts) with a `feat(m2d): arm64 cross-builds via buildx --platform` message + trailer.

---

### Task 5: `ARCH=aarch64` in the image build driver

**Files:**
- Modify: `mikronetes/scripts/m2b-build-images.sh`

**Interfaces:**
- Consumes: Tasks 2-4 outputs + machined `dist-aarch64`.
- Produces: `out/m2b/boot/vmlinuz`(arm64 Image)+`initramfs.img` + per-node `m2b.img` for aarch64. Consumed by Tasks 6, 9.

- [ ] **Step 1: Add `ARCH` (default `x86_64`) and thread it**

In `m2b-build-images.sh`: `ARCH="${ARCH:-x86_64}"`. When `aarch64`:
- build machined via `make dist-aarch64` (needs the cross-gcc from Task 1); `MACHINED=$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release/machined`.
- imager `build --arch aarch64`.
- pass `CONTAINERD_RS_ARCH=arm64 CRUN_ARCH=arm64 PLATFORM=linux/arm64` into the `m2a-build-overlay.sh` invocations, and use the `:m2d-arm64` image tags.

- [ ] **Step 2: Build the arm64 images**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && ARCH=aarch64 bash scripts/m2b-build-images.sh 2>&1 | tail -20
file out/m2b/boot/vmlinuz | grep -qi 'ARM aarch64\|MS-DOS\|data' ; echo "kernel built"
```
Expected: build completes; the module closure resolves against the **arm64** `modules.dep` (fails loudly if a netfilter/crc32c module name is absent there — if so, adjust `VIRT_MODULES`/note it). node images present.

- [ ] **Step 3: Commit** `feat(m2d): ARCH=aarch64 build path` + trailer.

---

### Task 6: Emulated-aarch64 launcher (`BACKEND=qemu-aarch64`)

**Files:**
- Modify: `mikronetes/scripts/m2b-up.sh` (add `launch_qemu_aarch64` + backend case)
- Create: `mikronetes/scripts/m2b-up-qemu-aarch64.sh` (wrapper, like `m2b-up-ch.sh`)

**Interfaces:**
- Consumes: the arm64 boot artifacts + node images (Task 5).
- Produces: 4 booted arm64 VMs. Consumed by Task 9.

- [ ] **Step 1: Add `launch_qemu_aarch64`** to `m2b-up.sh`, mirroring `launch_qemu` but:
  - binary `qemu-system-aarch64`, `-M virt -cpu cortex-a53 -smp 2` (no `-enable-kvm`),
  - `-append "console=ttyAMA0 root=/dev/ram0 rw"` (PL011 UART, not ttyS0),
  - `-device virtio-net-pci,netdev=n0,mac=…`, raw virtio disks, `-nographic -serial file:$serial -daemonize`.
  Add `qemu-aarch64` to the `BACKEND` case selecting it for all four nodes.

- [ ] **Step 2: Wrapper** `m2b-up-qemu-aarch64.sh`: `exec env BACKEND=qemu-aarch64 bash "$SCRIPT_DIR/m2b-up.sh"` (mirrors `m2b-up-ch.sh`); assert `qemu-system-aarch64` present.

- [ ] **Step 3: Syntax-check + commit** (`bash -n` both) `feat(m2d): qemu-system-aarch64 launcher (BACKEND=qemu-aarch64)` + trailer.

---

### Task 7: TCG-scaled timeouts (`WAIT_SCALE`)

**Files:**
- Modify: `mikronetes/scripts/m2b-up.sh`, `scripts/m2c1-bootstrap.sh`, `scripts/m2c1-smoke.sh`

**Interfaces:**
- Produces: readiness/convergence waits multiplied by `WAIT_SCALE` (default 1; set ~4 for TCG) so slow emulated boots don't spuriously fail.

- [ ] **Step 1:** In each script's Ready/convergence loops, multiply the iteration counts by `${WAIT_SCALE:-1}` (e.g. `for _ in $(seq 1 $((96 * ${WAIT_SCALE:-1})))`). Keep default 1 so x86_64/CH behavior is unchanged.

- [ ] **Step 2: Syntax-check + commit** `feat(m2d): WAIT_SCALE for slow TCG boots` + trailer.

---

### Task 8: arm64 pod images in bootstrap

**Files:**
- Modify: `mikronetes/scripts/m2b-bootstrap.sh` + `scripts/m2c1-bootstrap.sh` (image mirroring)

**Interfaces:**
- Produces: arm64 `busybox`/`whoami`/`flannel-rs`/`php`/`rusternetes-dns` in the local registry. Consumed by Task 9.

- [ ] **Step 1: `--platform linux/arm64` on the mirror pulls**

Where the bootstraps `docker pull`/`tag`/`push` the workload/CNI images, add `--platform linux/arm64` to the pulls (guarded by an env like `POD_PLATFORM=${POD_PLATFORM:-linux/amd64}`) so the arm64 manifests land in the registry. The php-alpine + rusternetes-dns images are built with `PLATFORM=linux/arm64` (Task 4).

- [ ] **Step 2: Commit** `feat(m2d): arm64 pod images in bootstrap (POD_PLATFORM)` + trailer.

---

### Task 9: Integration — build, boot 1 node, then 4-node, bootstrap, smoke

**Files:** none (acceptance run).

- [ ] **Step 1: Single-node arm64 smoke first (cheap early failure under TCG)**

Build arm64 images (Task 5), then boot **only node-1** (via a one-node `NODES=node-1` override or a manual `launch_qemu_aarch64` call) and confirm it reaches Ready with `containerd-rs://0.3.0` on arm64. If it doesn't boot, stop and debug before the 4-node cost.

- [ ] **Step 2: Full 4-node run**

```bash
cd /home/jones/PhpstormProjects/mikronetes
export ARCH=aarch64 WAIT_SCALE=4 CONTAINERD_RS_ARCH=arm64 CRUN_ARCH=arm64 PLATFORM=linux/arm64 POD_PLATFORM=linux/arm64
bash scripts/m2b-down.sh || true
bash scripts/m2b-build-images.sh
bash scripts/m2b-up-qemu-aarch64.sh
bash scripts/m2c1-bootstrap.sh
DURABILITY=0 bash scripts/m2c1-smoke.sh
```
Expected: `=== M2c-1 SMOKE PASSED ===` on arm64 — 4 nodes Ready, kube-proxy NAT rules, pinned system Services, DNS Deployment Ready + resolves, PHP DaemonSet 3 pods with distinct per-node IPs, `web` Service load-balances, per-node arm64 memory reported, no OOM. (Expect a long wall-clock under TCG.)

- [ ] **Step 3: If a stage fails, bisect by layer** — arm64 build (Task 5), boot/console (Task 6), netfilter modules on arm64 kernel (Task 2/5), or a not-yet-arm64 pod image (Task 8). Fix at the owning task.

- [ ] **Step 4: M2d complete** when `m2c1-smoke.sh` passes on emulated aarch64.

---

## Self-Review

**Spec coverage** (M2d design): emulated-aarch64 launcher → Task 6; ARCH=aarch64 build → Task 5; arm64 cross-builds → Tasks 3,4; arm64 iptables apks → Task 2; TCG timeouts → Task 7; arm64 pod images → Task 8; reuse of m2c1 bootstrap/smoke → Task 9; single-node-first validation → Task 9 Step 1; host prereqs → Task 1. ✓

**Placeholder scan:** the machined fixture-extension (Task 2 Step 4) and the exact per-`docker build` platform threading (Task 4) are described procedurally against proven patterns (the merged x86_64 iptables work; the existing musl Dockerfiles) rather than reproduced line-for-line; the arm64 `modules.dep` netfilter check (Task 5 Step 2) is build-driven. No `TODO`/`TBD`.

**Consistency:** arm64 image tags `:m2d-arm64`; env knobs `ARCH=aarch64`, `CONTAINERD_RS_ARCH=arm64`, `CRUN_ARCH=arm64`, `PLATFORM=linux/arm64`, `POD_PLATFORM=linux/arm64`, `WAIT_SCALE`; containerd-rs pin v0.3.0 — consistent across Tasks 2-9.

**Blocking dependency:** Task 1 (host packages via sudo) gates everything; it is an operator step, not agent-automatable.

# M2d — Four-Node Cluster on Emulated aarch64

## Goal

Prove the mikronetes stack (rusternetes + containerd-rs + crun + flannel-rs) on
**aarch64**, by running the full M2c-1 four-node cluster under
`qemu-system-aarch64` (TCG emulation) on the x86_64 dev box: cross-node pod
networking, kube-proxy Services, cluster DNS, and the PHP DaemonSet — the same
gates as M2c-1, but on arm64 artifacts.

This de-risks the arm64 build + the whole stack on arm64 **before** touching
real Raspberry Pi 3A+ hardware (a later milestone, M2e). The target hardware is
arm64; proving the software on emulated arm64 removes the "does any of this
compile/boot/run on arm64" unknown without needing physical boards.

## Scope and Decisions

Locked during brainstorming:

- **Target:** emulated aarch64 on this dev box (not real hardware). Real Pi 3A+
  bring-up (linux-rpi kernel, USB-Ethernet, SD image) is deferred to M2e.
- **Emulator:** `qemu-system-aarch64 -M virt -cpu cortex-a53` (Pi 3A+ CPU
  model), **TCG — no KVM** (host is x86_64, cross-arch). Cloud-Hypervisor is
  x86_64-only here, so CH is not used for M2d.
- **Artifacts:** the pinned `aarch64` linux-virt set in
  `machined-rs/crates/imager/artifacts.toml` (Alpine linux-virt 6.12.95 arm64).
  NOT `aarch64-rpi` (that kernel is for real hardware / M2e).
- **Scope:** full four-node parity with M2c-1 (Services + DNS + PHP DaemonSet),
  not a single-node subset — though bring-up validates one node boots before
  paying the 4-node TCG cost.
- **Reuse:** `m2b-net.sh`, `m2c1-bootstrap.sh`, `m2c1-smoke.sh` are
  arch-agnostic and run unchanged once arm64 images exist. Durability stays
  gated (`DURABILITY=1`); exec/logs work (containerd-rs v0.3.0 +
  `CONTAINERD_STREAM_HOST=127.0.0.1`, already in the configs).

## Architecture

Identical topology to M2c-1 — 4 nodes `10.88.0.2`–`10.88.0.5` on bridge
`mkn-br0`, host-gw flannel, per-node podCIDRs `10.244.0/1/2/3.0/24`, kube-proxy
Services, embedded DNS-disabled + `rusternetes-dns` Deployment, PHP DaemonSet on
the 3 workers, node-1 tainted. Only the **CPU arch and emulator** change.

## Components

### 1. Emulated-aarch64 launcher (`BACKEND=qemu-aarch64`)

Add a `launch_qemu_aarch64` path to `scripts/m2b-up.sh`:

```
qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 2 -m "$mem" \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append "console=ttyAMA0 root=/dev/ram0 rw" \
  -drive file="$node_dir/m2b.img",if=virtio,format=raw,index=0 \
  -drive file="$node_dir/state.img",if=virtio,format=raw,index=1 \
  -netdev tap,id=n0,ifname="$tap",script=no,downscript=no \
  -device virtio-net-pci,netdev=n0,mac="$mac" \
  -nographic -serial "file:$serial" -daemonize
```

Notes: arm64 `virt` console is the PL011 UART (`ttyAMA0`), not `ttyS0`. No BIOS
needed for direct `-kernel` boot of the arm64 `Image`. No `-enable-kvm` (TCG).
`BACKEND=qemu-aarch64` selects this in the launcher's case; `m2b-up.sh`'s
`ensure_taps_free` and per-node loop are reused. `scripts/m2b-up-qemu-aarch64.sh`
wraps it (like `m2b-up-ch.sh`).

### 2. arm64 image build (`ARCH=aarch64`)

`scripts/m2b-build-images.sh` gains `ARCH` (default `x86_64`); for `aarch64`:
- imager `--arch aarch64` (uses the `aarch64` artifact set; `VIRT_MODULES` is
  arch-shared; kernel `boot/vmlinuz-virt` = arm64 Image).
- an **arm64 machined** musl binary (`make dist-aarch64` in machined-rs, or the
  `aarch64-unknown-linux-musl` target).
- the manifest filter + overlay assembly stay; overlay binaries become arm64.

### 3. arm64 overlay + pod binaries/images

- Musl overlay binaries (rusternetes all-in-one, kubelet, kube-proxy,
  rusternetes-dns): build with `docker buildx --platform linux/arm64` against
  the existing musl Dockerfiles (emulated build via binfmt/qemu — slow).
- containerd-rs **v0.3.0 arm64** release tarball + **crun arm64** release
  (both publish arm64; `CONTAINERD_RS_ARCH=arm64`).
- Pod images (busybox, traefik/whoami, flannel-rs, php-alpine, rusternetes-dns)
  → arm64 variants pulled/built with `--platform linux/arm64` and pushed to the
  local registry (multi-arch registry serves them).

### 4. arm64 netfilter enablement (machined-rs)

- Add the **aarch64** iptables userspace apks (`iptables`/`libnftnl`/`libmnl`/
  `libxtables`) to `machined-rs/crates/imager/artifacts.toml` `aarch64` (only
  x86_64 has them today).
- Verify the arm64 linux-virt kernel's `modules.dep` declares the netfilter +
  `crc32c_generic` modules the shared `VIRT_MODULES` lists (the build errors
  loudly on any missing module; adjust if the arm64 kernel names differ).

### 5. Timeouts for TCG

Emulated arm64 boots + converges far slower than KVM/CH. Add an arch/emulator
multiplier (~3–4×) to the Ready/convergence waits in `m2b-up.sh`,
`m2c1-bootstrap.sh`, and `m2c1-smoke.sh` (e.g. an env `WAIT_SCALE`), so slow TCG
boots don't spuriously time out. A full cycle may take 1–2 h.

## Data Flow

Unchanged from M2c-1 — the only differences are the CPU arch and that
`qemu-system-aarch64` replaces Cloud-Hypervisor as the VMM. Build → boot 4 arm64
VMs → `m2c1-bootstrap.sh` (system Services + DNS Deployment + PHP DaemonSet) →
`m2c1-smoke.sh` (placement + LB + memory; durability gated).

## Prerequisites

- `qemu-system-aarch64` installed on the dev box (`qemu-system-arm` package);
  install if missing.
- `docker buildx` with arm64 emulation (binfmt/qemu-user) for cross-builds.

## Testing / Smoke Gate

Reuse `m2c1-smoke.sh` unchanged (arch-agnostic). M2d passes when, on emulated
aarch64:
- all four arm64 nodes reach Ready (containerd-rs://0.3.0, arm64);
- kube-proxy programs NAT rules on every node;
- system Services pinned (`kubernetes`@`10.96.0.1`, `kube-dns`@`10.96.0.10`);
- the `rusternetes-dns` Deployment is Ready and DNS resolves by name;
- the PHP DaemonSet runs 3 pods (one per worker, none on node-1, distinct
  per-node IPs) and the `web` Service load-balances across them;
- per-node/per-application memory is reported (arm64 numbers vs 512 MiB);
- no OOM / kernel panic.

Bring-up validates a single arm64 node boots + a pod runs before scaling to 4
(cheap early failure under TCG).

## Success Criteria

M2d passes when `m2c1-smoke.sh` is green from a clean build+boot on emulated
aarch64 — i.e. the full M2c-1 workload runs on arm64 artifacts, proving the
stack is arch-portable ahead of real Pi hardware.

## Out of Scope / Follow-ups

- **M2e — real Raspberry Pi 3A+ hardware:** linux-rpi kernel (`aarch64-rpi`),
  USB-Ethernet driver + fixed MAC, GPU firmware, SD-card image, physical boot.
- **KVM-accelerated arm64** (on an arm64 host / CI runner) — TCG is a dev-box
  stopgap; a real arm64 runner would make this fast.
- **rhino `synchronous=FULL`** durability (still deferred from M2c-1).
- **containerd-rs airgap tarball import** (pull-only) — the Pi no-registry path.
- **Worker disk sizing** for large images (the ENOSPC constraint; use small
  images or grow the disk).

# M2b — Four 512 MiB MicroVM Nodes for Raspberry Pi 3A+ Viability

## Goal

Replicate the intended Raspberry Pi 3A+ deployment shape in QEMU and Cloud Hypervisor:

- `node-1`: control-plane node, 512 MiB RAM.
- `node-2`, `node-3`, `node-4`: worker nodes, 512 MiB RAM each.
- Runtime stack on every node: `machined-rs` + `containerd-rs` + `crun`.
- Control-plane service: `rusternetes` all-in-one or split control-plane services, depending on measured memory.
- Worker service: standalone `rusternetes-kubelet` in API mode, not the all-in-one.
- CNI: `flannel-rs` by default; keep the manifest boundary so `calico-rs` can replace it later.

The single-node M2a result is not enough for a Pi recommendation. The real question is whether the control-plane node and worker nodes each fit inside their own 512 MiB RAM budget while the cluster runs cross-node pod networking.

## Current Evidence

Latest M2a QEMU smoke with `MEM=1024` passed and reported roughly:

- `rusternetes`: 90 MiB RSS
- `containerd-rs`: 21 MiB RSS
- `flannel-rs`: 11 MiB RSS
- `whoami`: 7 MiB RSS
- `crun`: 9 MiB RSS
- guest app total: 138 MiB RSS

The earlier `MEM=512` single-node run OOM-killed `rusternetes`. That proves the current all-in-one control-plane path does not yet have enough margin at boot, but it does not answer whether worker-only nodes fit. M2b must measure control-plane and worker memory separately.

## Architecture

Use one host bridge with four tap devices:

- host bridge: `mkn-br0`, `10.88.0.1/24`
- `node-1`: `10.88.0.2`, MAC `52:55:00:88:00:02`
- `node-2`: `10.88.0.3`, MAC `52:55:00:88:00:03`
- `node-3`: `10.88.0.4`, MAC `52:55:00:88:00:04`
- `node-4`: `10.88.0.5`, MAC `52:55:00:88:00:05`

Use one state disk per node:

- `out/m2b/node-1/state.img`
- `out/m2b/node-2/state.img`
- `out/m2b/node-3/state.img`
- `out/m2b/node-4/state.img`

Use one serial log per node:

- `out/m2b/node-1/serial.log`
- `out/m2b/node-2/serial.log`
- `out/m2b/node-3/serial.log`
- `out/m2b/node-4/serial.log`

The launcher must support both:

- `BACKEND=qemu`
- `BACKEND=ch`

QEMU remains the CI-compatible default. Cloud Hypervisor remains the local target once the multi-node harness is stable.

## Required Node Images

M2a currently bakes one static `deploy/m2a/config.yaml` with `node-1` and `10.88.0.2`. M2b needs generated per-node config.

Control-plane config:

- hostname: `node-1`
- IP: `10.88.0.2/24`
- services:
  - `rusternetes` control-plane/all-in-one
  - `containerd-rs`
- initial target: keep all-in-one for continuity, then measure if split control-plane services are needed.

Worker config:

- hostname: `node-2`, `node-3`, `node-4`
- IPs: `10.88.0.3/24`, `10.88.0.4/24`, `10.88.0.5/24`
- services:
  - `kubelet` standalone binary from `crates/kubelet`
  - `containerd-rs`
- kubelet mode:
  - `--kubeconfig /boot/kubelet.kubeconfig`
  - `--api-server-url https://10.88.0.2:6443`
  - `--insecure-skip-tls-verify` until per-node PKI is wired
  - `CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd-rs.sock`

The worker nodes must not run API server, scheduler, controller-manager, DNS, or embedded kube-proxy unless a measured networking requirement forces it.

## Smoke Gate

Create a new M2b smoke gate instead of overloading M2a:

`scripts/m2b-smoke.sh`

Assertions:

- all four nodes register and become Ready
- each node reports `containerd-rs` as RuntimeReady through `machined-rs`
- each node runs the selected CNI DaemonSet pod
- each node receives a unique pod CIDR:
  - `node-1`: `10.244.0.0/24`
  - `node-2`: `10.244.1.0/24`
  - `node-3`: `10.244.2.0/24`
  - `node-4`: `10.244.3.0/24`
- one `whoami` pod is pinned to each node
- pod-to-pod traffic works across nodes
- host-to-pod traffic works through host routes
- no node serial log contains OOM or kernel panic

Memory output must be per node and per application at two points:

- boot/readiness
- booted/idle

Required table shape:

| Node | Phase | Application | RSS MiB | Processes |
|------|-------|-------------|---------|-----------|
| node-1 | boot/readiness | rusternetes | ... | ... |
| node-2 | boot/readiness | kubelet | ... | ... |
| node-2 | booted/idle | containerd-rs | ... | ... |

Also report host-side VMM RSS per node:

| Node | Backend | VMM RSS MiB | Guest Cap MiB |
|------|---------|-------------|---------------|
| node-1 | qemu | ... | 512 |

## Development Focus

1. Build the multi-node harness first.

   Do not spend more optimization time on the single-node all-in-one result until M2b tells us which node role is failing. A worker-only node may fit comfortably even if the control-plane node does not.

2. Measure boot peak, not just idle RSS.

   The current failure mode is boot-time OOM. Add continuous sampling for every node during launch and bootstrap, then summarize peak RSS per application.

3. Separate control-plane optimization from worker optimization.

   If only `node-1` fails at 512 MiB, focus on splitting or slimming the control plane. If workers fail, focus on kubelet/containerd-rs/CNI.

4. Keep CNI work bounded.

   `flannel-rs` is currently small relative to `rusternetes`. Do not switch to `calico-rs` for memory reasons unless M2b shows CNI dominates worker-node memory or flannel-rs cannot do cross-node pod networking.

5. Defer Kubernetes surface area.

   DNS, Service proxying, exec/log streaming, metrics, admission extras, and dashboard/console should stay off until four 512 MiB nodes pass the core smoke.

## Implementation Tasks

- [ ] Add `scripts/m2b-net.sh` to create `mkn-br0` plus taps `mkn0` through `mkn3`, and install pod CIDR routes via each node IP.
- [ ] Add per-node config generation so one image template can emit control-plane and worker `/boot/config.yaml` files.
- [ ] Extend overlay assembly to include the standalone `kubelet` binary alongside `rusternetes`.
- [ ] Add `scripts/m2b-up.sh` to boot four VMs with per-node state disks, serial logs, tap devices, MACs, and IPs.
- [ ] Add `scripts/m2b-bootstrap.sh` to patch node InternalIPs, assign pod CIDRs, apply CNI, and launch pinned smoke pods.
- [ ] Add `scripts/m2b-smoke.sh` with per-node readiness, cross-node networking, OOM detection, and per-node memory reporting.
- [ ] Run first at `MEM=1024` to prove topology and networking.
- [ ] Run at `MEM=512` and record exactly which node/app fails first.
- [ ] Only after the failing role is known, optimize the dominant memory consumer.

## Decision Rules

- If workers pass at 512 MiB and control-plane fails, prioritize control-plane split/slimming.
- If workers fail at 512 MiB, prioritize standalone kubelet and containerd-rs memory before CNI replacement.
- If cross-node CNI fails with flannel-rs, fix flannel-rs integration before evaluating calico-rs.
- If QEMU works but Cloud Hypervisor fails, keep QEMU as the measured baseline and treat CH as a backend parity bug.
- If 1024 MiB fails, stop memory optimization and fix correctness/topology first.


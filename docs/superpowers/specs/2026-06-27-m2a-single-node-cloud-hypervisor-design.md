# M2a — single mikronetes node in a Cloud Hypervisor microVM @512 MiB

**Date:** 2026-06-27
**Milestone:** M2a of the mikronetes North Star.
M1 (3-node all-Rust stack, containers) ✅ done → **M2a (one node in a Cloud
Hypervisor microVM, 512 MiB, machined-rs PID 1)** → M2b (3 microVMs on a bridged
LAN, cross-node flannel) → M3 (Ginkgo conformance, suite-by-suite).

## Goal

Boot **one** mikronetes node inside a **Cloud Hypervisor** microVM with
**machined-rs as PID 1**, running the whole Rust stack **as machined-supervised
services**, capped at **512 MiB of real guest RAM**. This proves the all-Rust
stack fits and runs in a genuinely RAM-limited guest with its own kernel — not
just containers sharing the host kernel (which is all M1 proved). Cross-VM /
LAN networking is explicitly deferred to M2b.

This is the hard de-risk for M2: *does the all-Rust control plane + worker +
a guest kernel actually fit and run in 512 MiB?*

## Why this is an assembly job (not build-from-scratch)

Every piece already exists and is independently green:

- **machined-rs** is a mature Talos-style PID 1: boot sequencer, typed reconcile
  runtime, service supervisor with CRI `RuntimeReady` health-gating, block
  provisioning (STATE+EPHEMERAL), static network config, mTLS gRPC API +
  `machinectl`, and a userspace **imager** that already builds a bootable
  `vmlinuz` + `initramfs.img` from pinned Alpine artifacts and boots them under
  QEMU in CI. It is *payload-agnostic by design* — the payload is just
  supervised services with a readiness gate.
- **rusternetes** ships an **all-in-one** control-plane binary
  (api-server + scheduler + controller-manager + rhino, sqlite/rhino in-tree),
  measured at ~48 MiB PSS, plus a kubelet — both published as public GHCR
  images.
- **containerd-rs** (Rust CRI), **crun** (OCI), **flannel-rs** (Rust CNI) are
  the same M1-proven data-plane components.

M2a wires these into a single machined node image and boots it on Cloud
Hypervisor. The only genuinely new code is a small image-overlay mechanism and
the CH launch/verify harness; any machined-rs gaps surfaced are fixed
upstream-faithfully with tests.

## Success criteria

All of the following must hold for a green M2a:

1. Cloud Hypervisor boots the imager's `vmlinuz` + `initramfs.img` via **direct
   kernel boot** (`--kernel` / `--initramfs` / `--cmdline`, no OVMF /
   systemd-boot), and machined comes up as PID 1.
2. `machinectl get ServiceStatus` (over mTLS) shows containerd-rs reporting CRI
   `RuntimeReady`, and the control plane, kubelet, and flannel all
   `Running` / healthy.
3. The node registers with its own api-server and reports **Ready**.
4. **One workload pod runs**: scheduled by the CP, created by
   kubelet → containerd-rs → crun, networked by flannel-rs (single-node, local
   subnet). A `curl` to the pod succeeds.
5. The guest stays **under 512 MiB**: `free` inside the guest plus the host-side
   RSS of the `cloud-hypervisor` process, captured in a per-component memory
   report in the M1 style. If it genuinely does not fit, that is a recorded
   *finding*, not a silent failure.

## Architecture

Single **all-in-one node** (control-plane + worker colocated). One
`machine.yaml` declares everything; machined reconciles it.

```
┌──────────────── Cloud Hypervisor microVM (512 MiB, 1–2 vCPU) ─────────────────┐
│  vmlinuz + initramfs   (direct --kernel/--initramfs boot, virtio console)      │
│                                                                                │
│  machined (PID 1) ── reads /boot/machine.yaml ──┐                              │
│     ├─ network: eth0 static IP on the bridge (network.interfaces)             │
│     ├─ block:   provision STATE+EPHEMERAL on /dev/vda (blank virtio-blk)      │
│     ├─ runtime: containerd-rs  ── gated on CRI RuntimeReady                    │
│     └─ services (depends_on graph):                                            │
│          rusternetes all-in-one CP  (api+sched+ctrl+rhino, ~48 MiB)           │
│          flannel-rs        depends_on: [all-in-one]  → writes subnet.env       │
│          kubelet           depends_on: [containerd, all-in-one]                │
│                            --container-runtime-endpoint unix://…containerd-rs.sock
│  kubelet → containerd-rs → crun → workload pod (flannel CNI, /opt/cni/bin)     │
│  mTLS gRPC :50000 (machinectl)         api-server :6443 (kubectl from host)    │
└────────────────────────────────────────────────────────────────────────────────┘
        host: tap device on a Linux bridge ── reaches the VM's eth0
```

### Component decisions

- **Control plane = the rusternetes all-in-one binary** as a single machined
  service — leanest option for the 512 MiB budget, and the machined-native
  "supervised service" model rather than static pods.
- **flannel-rs = a machined service**, not a DaemonSet. On a single node there
  is no pod-scheduling bootstrap to satisfy; flannel only needs the CP up, then
  writes `/run/flannel/subnet.env`. (Divergence from upstream's DS is justified:
  declarative machined-native bring-up, and flannel-rs is our reimplementation.
  M2b revisits whether multi-node wants the DS form.)
- **kubelet = a machined service**, `depends_on: [containerd, all-in-one]`. Its
  CRI endpoint is set via the standard kubelet **flag**
  (`--container-runtime-endpoint unix://…/containerd-rs.sock`), avoiding the need
  for an `env:` field on machined's `ServiceConfig` (which it does not currently
  have). The kubelet manages all workload pods.
- **machined's own `pods:` block is NOT used.** It is host-network-only today
  (CNI is its unfinished M8b). Workload pods go through the rusternetes kubelet,
  which has full flannel CNI.
- **Binaries are baked into the image, build-free** (same philosophy as the M1
  CI): rusternetes all-in-one + kubelet pulled from public GHCR images,
  containerd-rs from the baked `deploy/node-cdrs/bin` binary, crun + CNI plugins
  (flannel, bridge, host-local) as pinned artifacts, flannel-rs binary.

## Image build & boot mechanics

### Image build — a payload overlay

Extend machined's `imager` with a *payload overlay*: a mikronetes-specific
staging tree merged into the initramfs/rootfs the imager already builds from
pinned Alpine artifacts.

```
/boot/vmlinuz                      Alpine virt kernel (imager already fetches)
/boot/initramfs.img                imager-built; /init = machined
/boot/machine.yaml                 the all-in-one node config above
/usr/bin/rusternetes               all-in-one control plane            ┐
/usr/bin/rusternetes-kubelet                                            │ baked,
/usr/bin/containerd-rs                                                  │ build-
/usr/bin/crun                                                           │ free
/usr/bin/flannel-rs                                                     ┘
/opt/cni/bin/{flannel,bridge,host-local}
/etc/cni/net.d/10-flannel.conflist
+ PKI/cert material that machined issues at first boot
```

**Open decision (resolved in the plan by reading the imager source):** add a
`--overlay <dir>` flag to `machined-imager` (clean, reusable, upstreamable to
machined-rs) vs. assemble the staging tree in a mikronetes script and hand it to
the existing imager. **Leaning toward the `--overlay` flag** — small, reusable,
keeps the image build in one tool.

### Boot mechanics (Cloud Hypervisor)

```
cloud-hypervisor \
  --kernel    /…/vmlinuz \
  --initramfs /…/initramfs.img \
  --cmdline   "console=hvc0 …" \
  --disk      path=/…/state.img        # blank; machined provisions STATE+EPHEMERAL
  --net       tap=mkn0,mac=… \
  --memory    size=512M \
  --cpus      boot=2 \
  --api-socket /…/ch.sock
```

- **Cloud Hypervisor is acquired as a pinned static release binary** — it is not
  installed on the dev box or in CI. Acquisition is an explicit setup step in
  both `m2a-up.sh` and the CI workflow.
- **Networking:** the host creates a Linux bridge `mkn-br0` + a tap; the VM's
  eth0 receives a static IP on that subnet via `network.interfaces`; the host
  reaches api-server `:6443` and machined `:50000` over the bridge. One VM for
  now; the same bridge pattern scales directly to M2b's three VMs.

### Data flow at boot

machined mounts the pseudo-filesystems → configures eth0 → provisions
`/dev/vda` (STATE+EPHEMERAL) → starts containerd-rs and waits for CRI
`RuntimeReady` → starts the all-in-one CP → starts flannel-rs (writes
`subnet.env`) → kubelet registers the node → the CP schedules the smoke pod →
kubelet + containerd-rs + crun run it and flannel CNI wires its network.

## Harness & verification

Mirrors M1's `m1-up.sh` / `m1-smoke.sh`.

- **`scripts/m2a-up.sh`** — acquire CH if missing → build the overlay image →
  create bridge + tap → launch CH → block on a **real convergence gate**
  (machinectl reports all services healthy *and* node Ready *and* `subnet.env`
  present). All probes are `set -e`-safe with `|| echo` fallbacks (the M1
  lesson: a failing command-substitution under `set -euo pipefail` silently
  aborts the script). `die` loudly on timeout with diagnostics.
- **`scripts/m2a-smoke.sh`** — exits non-zero on any failed assertion:
  1. `machinectl get ServiceStatus` → containerd-rs / CP / kubelet / flannel all
     healthy.
  2. Node **Ready** (kubectl via the VM's api-server IP).
  3. Self-provision one workload pod, wait Running, `curl` it — proves
     kubelet → containerd-rs → crun → flannel end-to-end **inside a VM**.
  4. **Memory report:** `free -m` inside the guest + host RSS of the CH process,
     rendered as a table like M1's, asserting < 512 MiB.

### Error handling & determinism

Convergence is gated on real conditions, never sleeps. On failure the harness
dumps the serial-console log, `machinectl` status, and CP/kubelet logs. Carry
forward the M1 hard-won fixes: pre-create any host-mounted dirs as the invoking
user, generate certs/PKI before boot, and keep every gate probe `set -e`-safe.

### Testing

machined-rs already has root-free fakes plus QEMU boot tests. Any machined-rs
change (the `--overlay` flag; possibly an `env:` field on services, or readiness
handling for non-CRI services) is built under TDD with unit tests there before
use. The end-to-end gate is `m2a-up.sh` + `m2a-smoke.sh`, runnable locally and
in CI.

**CI runs on our self-hosted GitHub ARC runners** (Spot Rackspace, our own
rented hardware), not GitHub-hosted runners. The ARC runner pods run
**privileged**, so the CH launch has everything it needs from userspace —
`NET_ADMIN` for the bridge/tap, loop devices for the imager — *provided the
host exposes KVM*. The single thing to confirm (a plan task) is that
**`/dev/kvm` is present and passable** into the runner pod (nested virt if the
Spot nodes are VMs, native if bare metal). With that, M2a's end-to-end boot is a
real CI gate, not a local-only stretch. If a given runner lacks `/dev/kvm`, fall
back to local verification and gate only the unit-level machined-rs changes in
CI.

## Risks

1. **512 MiB is tight.** Guest kernel (~40–80 MiB) + initramfs + machined +
   all-in-one (~48 MiB) + containerd-rs + kubelet + crun + a pod. Mitigations:
   use the all-in-one (not a split CP), measure early, trim the kernel config if
   needed. If it genuinely will not fit, report that as a finding rather than
   hiding it.
2. **Cloud Hypervisor acquisition + KVM availability.** Acquired as a pinned
   static binary. CI runs on our self-hosted, **privileged** GitHub ARC runners
   (Spot Rackspace), which removes the GitHub-hosted-runner KVM uncertainty —
   the only open check is that the runner host exposes `/dev/kvm` to the pod
   (nested virt on VM nodes, native on bare metal).
3. **machined-rs gaps** surfaced during the build (service `env`, ordering,
   readiness for non-CRI services). Fix upstream-faithfully in machined-rs with
   tests, mirroring the M1 containerd-rs / rusternetes gap work.

## Deliverables

- mikronetes `scripts/m2a-up.sh` + `scripts/m2a-smoke.sh` + the all-in-one
  `machine.yaml`.
- imager `--overlay` support (a machined-rs PR), with tests.
- A recorded 512 MiB per-component memory breakdown.
- A green local M2a run (and CI if the runner supports KVM).

## Addendum — decisions from plan-time research (2026-06-27)

Reading the four repos + the live Dallas cluster refined several points above.
Where this addendum and the body differ, **the addendum wins**.

- **VM backend = QEMU-TCG in CI + Cloud Hypervisor locally**, selected by a
  `--backend qemu|ch` flag in the harness. The Dallas Spot ARC nodes expose **no
  `/dev/kvm`** (no `vmx`/`svm` even in a privileged pod — verified), and Cloud
  Hypervisor is KVM-only with no emulation fallback. QEMU-TCG boots the *same*
  M2a image (kernel + initramfs + disk) with `-m 512` (the RAM cap is real under
  TCG; only the CPU is emulated), giving a green-on-push CI boot+fit gate now.
  CH remains the North Star VMM — verified locally on the dev box (has
  `/dev/kvm`) and the documented production launch path; it moves into CI once a
  KVM-capable runner exists. machined-rs already boot-tests under QEMU-TCG, so
  the QEMU path reuses a proven harness.
- **The node uses the all-in-one's *embedded* kubelet — no separate kubelet
  service.** `rusternetes` (the all-in-one) already runs api-server + scheduler
  + controller-manager + storage **+ an embedded kubelet + kube-proxy** in one
  process, and its embedded kubelet defaults to `PodNetworkMode::Cni` (drives an
  external CRI). So machined supervises exactly two payload units: the
  containerd-rs **runtime** and the **all-in-one** (in CNI mode). Running a
  second kubelet would fight the embedded one.
- **flannel-rs stays a DaemonSet applied post-boot** (as in M1), *not* a machined
  service. flannel-rs has no `--kubeconfig` flag — it auto-detects an in-cluster
  ServiceAccount token, which a bare machined service wouldn't have. The
  DaemonSet (hostNetwork, needs no CNI to start) is the lower-divergence path and
  reuses M1's working `deploy/flannel/flannel-rs.yaml`.
- **Two confirmed machined-rs gaps to fix upstream-faithfully (TDD):**
  1. `ServiceConfig` has **no `env`** field, but the all-in-one's embedded
     kubelet reads `CONTAINER_RUNTIME_ENDPOINT` from the environment (it is not a
     CLI flag). Add `env` to `ServiceConfig`.
  2. machined's `runtime:` block **generates an upstream-containerd v3
     `config.toml`** (`containerd_config_toml`) and passes `--config` to the
     binary; **containerd-rs uses its own config schema**. Add a "bring-your-own
     config" knob so machined supervises `containerd-rs --config <baked>` and
     CRI-health-probes its socket **without** overwriting the baked config. This
     preserves machined's `RuntimeReady` gating (the embedded kubelet then waits
     for a genuinely-ready CRI — avoids the M1 startup race).
- **Payload is delivered through the imager's existing artifact-staging system**
  (artifact kinds `boot-binary` / `boot-tarball` / `cni-plugins`, which land
  files on the FAT `/boot` partition at `/boot/bin/*`, `/boot/cni/bin`), plus a
  small **`--overlay <dir>`** flag for the mikronetes-specific files
  (`/boot/config.yaml`, the baked containerd-rs config, certs). The **boot disk
  is the imager's own GPT image** (which carries `/boot` *and* free space
  machined provisions as STATE+EPHEMERAL) — not a separate blank disk. The
  QEMU/CH launch is `--kernel vmlinuz --initramfs initramfs.img` (from the
  imager's `--emit-boot`) **plus** `--disk <image>`, exactly mirroring
  machined-rs's existing aarch64 boot test.
- **Pinned artifact versions:** Cloud Hypervisor `v52.0`
  (`cloud-hypervisor-static`); crun `v1.28` static; CNI plugins `v1.9.1`
  (`bridge`/`host-local`/`loopback`/`portmap`); flannel CNI plugin
  `v1.9.1-flannel1`. (The M1 `node-cdrs` image already vendors CNI `v1.6.2` +
  crun-as-runc; reuse if simpler.) GHCR binaries are extracted from the public
  images via `docker create` + `docker cp`: `rusternetes` at `/app/rusternetes`
  (in the `api-server` image), `kubelet` at `/app/kubelet`, containerd-rs from
  the baked `deploy/node-cdrs/bin/containerd-rs`.

## Out of scope (M2a)

- Multiple VMs, cross-VM flannel VXLAN, a bridged multi-node LAN (→ M2b).
- The 512 MiB *hard cap as a gate across all nodes* (M2a measures one node).
- Ginkgo conformance suites (→ M3).
- A/B upgrade / disk-boot persistence of the VM image (machined supports it; not
  needed to prove the stack boots and runs).

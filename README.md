# mikronetes

[![smoke-test](https://github.com/indyjonesnl/mikronetes/actions/workflows/smoke.yml/badge.svg)](https://github.com/indyjonesnl/mikronetes/actions/workflows/smoke.yml)

**A Talos-style Kubernetes distribution for 512 MB devices.**

One Rust stack that turns cheap, RAM-starved single-board computers into a real
Kubernetes cluster — flashed from a micro SD image or installed onto vanilla
Raspbian/Ubuntu — and managed entirely over an **encrypted API. No SSH, no
shell.**

> Status: **early / pre-alpha.** This README is the plan. See the [Roadmap](#roadmap).

---

## Why

The target is deliberately absurd: a working Kubernetes cluster on
**Raspberry Pi 3A+ / Pi Zero 2 W** boards — **512 MB of RAM each**, quad-core
Cortex-A53, wired networking over **USB-ethernet adapters**, a single micro SD
card per node holding the OS, the binary, and all cluster state.

Two distributions shape the design. [k0s](https://k0sproject.io) proves the
*packaging*: one binary that bootstraps and supervises a whole cluster, no
external dependencies. [Talos Linux](https://www.talos.dev) proves the
*operating model*: an immutable node with **no SSH and no shell**, configured by
a single declarative file and managed entirely over a mutual-TLS API.

mikronetes takes both — k0s's single-stack packaging, Talos's API-driven,
SSH-less management — and runs them on a fully Rust component stack.

Why Rust, end to end:

- **Footprint.** A control plane measured in hundreds of MB, not gigabytes, so a
  512 MB node still has room for actual workloads.
- **One static binary.** No runtime, no GC pauses, no package manager on the
  node. Cross-compiles cleanly for `aarch64`.
- **Flash-friendly.** Cluster state lives in SQLite, not etcd — no quorum, no
  write amplification chewing through the SD card.

mikronetes is **not** another Kubernetes rewrite. The hard parts already exist
as standalone Rust projects; mikronetes is the thin **distribution layer** that
assembles them.

## The stack

| Project | Role | Upstream analog |
|---|---|---|
| **mikronetes** | Distribution layer: PKI, machine config, bootstrap, join tokens, CLI, packaging | k0s |
| [**machined-rs**](../machined-rs) | PID 1 / node supervisor, typed reconcile, depends-on + CRI health gates, **mTLS gRPC API — no SSH** | Talos `machined` / `apid` |
| [**rusternetes**](../rusternetes) | Kubernetes in Rust — apiserver, scheduler, controller-manager, kubelet, kube-proxy; SQLite storage, no etcd | bundled `kube-*` + kine |
| [**containerd-rs**](../containerd-rs) | CRI v1 container runtime (runs containers via `runc`) | bundled containerd |
| [**flannel-rs**](../flannel-rs) | CNI: `flanneld` (VXLAN) + the per-pod plugin chain | bundled CNI |

mikronetes owns the cluster lifecycle and **delegates all process supervision to
machined-rs**. The `machine:` section of the config *is* what machined-rs
consumes — there is no second, rendered config format.

## Architecture

```
                  Control-plane node (1)                     Worker node (N)
        ┌──────────────────────────────────┐      ┌──────────────────────────────┐
        │  machined-rs (PID 1 / supervisor) │      │ machined-rs (PID 1)          │
        │   mTLS gRPC API ▲ (no SSH)        │      │  mTLS gRPC API ▲ (no SSH)    │
        │   ├─ containerd-rs (CRI)          │      │  ├─ containerd-rs (CRI)      │
        │   ├─ rusternetes control plane    │      │  ├─ flannel-rs (CNI)         │
        │   │    apiserver/sched/cm  +SQLite │◀─────│  └─ rusternetes kubelet      │
        │   ├─ flannel-rs (CNI)             │ join │                              │
        │   └─ rusternetes kubelet          │token │   USB-ethernet LAN           │
        └────────────────▲─────────────────┘      └───────────────▲──────────────┘
                         │            mTLS gRPC (client certs from node CA)        │
                         └──────────────────  mikronetes CLI  ────────────────────┘
                            apply-config · bootstrap · kubeconfig · reset
```

With 512 MB per node the topology is fixed like k0s: **one control-plane node,
the rest workers.** No HA control plane at this RAM budget (see Roadmap P5).

## Configuration

A node is described by one declarative file, Talos-style, with a `machine:`
section (the node, consumed by machined-rs) and a `cluster:` section (the
rusternetes control plane):

```yaml
# mikronetes.yaml
machine:                          # consumed directly by machined-rs
  type: controlplane              # controlplane | worker
  hostname: node-1
  install:
    disk: /dev/mmcblk0
  network:
    interface: eth0               # USB-ethernet adapter
  swap: off                       # SD cards die under swap
  zram:
    enabled: true
    percent: 150                  # zram size as % of RAM
  ca:                             # node CA — issues the mTLS client certs
    crt: <base64>
    key: <base64>
cluster:                          # rusternetes control-plane spec
  controlPlane:
    endpoint: https://10.0.0.1:6443
  storage:
    type: sqlite                  # no etcd
    path: /var/lib/mikronetes/state.db
  network:
    podCIDR: 10.244.0.0/16
    serviceCIDR: 10.96.0.0/12
  token: <bootstrap-join-token>
```

The same file provisions a node whether it was flashed from an image or
installed onto an existing OS.

## Quickstart

> Both paths are roadmap targets, not yet shipping.

**Option A — flash an image (recommended for the Pi):**

```sh
# Write the prebuilt image to an SD card (OS + binaries, stripped + tuned)
xz -dc mikronetes-aarch64.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
# Drop mikronetes.yaml on the boot partition; first boot self-provisions.
```

**Option B — install onto existing Raspbian/Ubuntu:**

```sh
# Installs machined-rs as a managed service, ready to accept config over mTLS.
curl -sSL https://get.mikronetes.io | sh
```

Either way, you then manage the cluster over the API — never SSH:

```sh
mikronetes apply-config --nodes 10.0.0.1 --file controlplane.yaml
mikronetes bootstrap     --nodes 10.0.0.1          # init the first controller
mikronetes apply-config --nodes 10.0.0.2 --file worker.yaml
mikronetes kubeconfig    > ~/.kube/config
kubectl get nodes
```

## Management — no SSH

Like Talos, a mikronetes node has **no SSH daemon and no shell to log into.**
Every operation goes through machined-rs's **mutual-TLS gRPC API**, authenticated
with client certificates issued by the node's own CA:

- `apply-config` — push or update a node's machine config (declarative reconcile)
- `bootstrap` — initialise the first control-plane node
- `kubeconfig` — pull admin credentials for `kubectl`
- `reset` — wipe state and reprovision
- inspect live node/service/runtime status over the same API

This keeps the attack surface tiny and the node immutable — exactly what a
headless board with no console attached wants.

## Development & testing

You don't need a Pi to develop mikronetes. The cluster is simulated with Docker
or Podman as **three containers** — one control-plane + two workers — each pinned
to the **same 512 MB budget as the real hardware**:

```sh
docker compose up -d            # see compose.yaml
scripts/cluster-up.sh           # bring up the cluster (handles the join token)
scripts/smoke-test.sh           # the PR gate (below)
scripts/cluster-down.sh         # tear it all down
```

Each container is capped with **equal `mem_limit` and `memswap_limit` (512 MB)** —
a hard cap with NO swap, mirroring the Pi where swap is disabled. This is the
whole point: without the swap limit the container silently swaps and the test
lies. The dev box has plenty of RAM (ours has 64 GB) — but each *node* is held to
512 MB, so what passes locally is what runs on the boards.

Today the harness runs **real k0s v1.36 (kine/SQLite backend)** as a known-good
baseline; the mikronetes Rust stack will replace it component by component while
this same harness stays green.

**The PR gate (hard rule):** every PR is preceded by `scripts/smoke-test.sh`,
which brings up the cluster under the 512 MB-per-node cap and verifies it still
works — control-plane converges, both workers join and reach `Ready`, a Hello
World pod schedules on a worker and serves HTTP, and **no container is
OOM-killed.** If it fails to converge or OOMs inside 512 MB, the change does not
merge. Memory regressions are caught before review, not in production on a board
you can't `ssh` into.

## Memory strategy

Fitting Kubernetes into 512 MB is the whole game. mikronetes images and the
installer apply:

- **Swap off.** SD cards die fast under swap write amplification — disabled outright.
- **Aggressive ZRAM.** Compressed RAM-backed swap instead, so cold pages cost CPU, not flash.
- **Stripped OS.** The image removes everything unused on a headless node: **Wi-Fi,
  Bluetooth, HDMI/GPU**, audio, and their firmware/drivers.
- **SQLite, not etcd.** No etcd process, no quorum overhead, one file on disk.
- **One static binary.** No language runtime resident in memory per component.

> **Background:** [`docs/k0s-memory-research.md`](docs/k0s-memory-research.md)
> investigates exactly how upstream k0s fits Kubernetes on small nodes — and the
> runtime knobs it leaves untouched that mikronetes must tune to hit 512 MB.
> Agentic assistants: read it before changing anything memory-related.

## Launch goal — the Proof of Concept

The first release is **not** a feature-complete distro. It is one **vertical slice**
that proves the whole stack integrates and fits the memory budget:

> **A "Hello World" Kubernetes cluster — 1 control-plane + 2 workers, each node
> capped at 512 MB — running a pod you can reach.**

**Definition of done (Milestone 0):**

- Three containers via `compose.yaml`, each pinned to 512 MB with no swap
  (control-plane + 2 workers) — see [Development & testing](#development--testing).
- The control-plane brings up the rusternetes control plane (SQLite) + supporting
  components, supervised by machined-rs.
- Both workers join over a bootstrap token and register.
- `kubectl get nodes` → **both worker nodes `Ready`**.
- `kubectl apply` a trivial HTTP "hello world" Deployment → it **schedules on a
  worker, goes `Running`, and serves a request**.
- **No container OOMs** — every node stays inside 512 MB for the whole run.

> **Status:** the harness exists today and passes with **real k0s** standing in for
> the mikronetes stack — proving the topology, the 512 MB cap, and the smoke test
> are real before a line of mikronetes is written. See `compose.yaml` and
> `scripts/`.

That single green run is the launch. Everything below builds on it.

## Roadmap

**M0 — Proof of Concept (the launch goal above)**
The work to make that two-container Hello World pass: `mikronetes` CLI skeleton,
bundling the four sibling binaries, the `mikronetes.yaml` schema (`machine:` +
`cluster:`), PKI + `apply-config`/`bootstrap`/`kubeconfig`, join tokens, and the
two-container `compose.yaml` harness + PR smoke-test gate wired into CI from day one.

**P1 — Real multi-node + networking depth**
Harden join across the USB-ethernet LAN, flannel VXLAN pod-to-pod across nodes,
services/DNS (CoreDNS), and `kubectl` ergonomics beyond the happy path.

**P2 — VM fidelity**
Re-run the PoC in 512 MB VMs (firecracker/qemu) with machined-rs as **PID 1**,
real swap-off, and ZRAM — proving the actual node model the containers can't.

**P3 — The image**
Flashable micro SD image: stripped OS (Wi-Fi/BT/HDMI removed), swap off, ZRAM
configured, machined-rs as PID 1, first-boot provisioning from a `mikronetes.yaml`
on the boot partition. First run on real Pi 3A+ / Zero 2 W hardware.

**P4 — Memory hardening + ergonomics**
Tune ZRAM and per-component limits to leave real workload headroom inside
512 MB; round out the management API (`reset`, status, log streaming); write the docs.

**P5 — Later**
HA / multi-controller (for boards with more RAM), autopilot-style self-update,
SQLite backup/restore, and a build matrix across Pi Zero 2 W vs Pi 3A+.

## Contributing

mikronetes is the integration layer; most heavy lifting lives in the sibling
repos. Issues and PRs welcome once P0 lands.

## License

MIT. Each component reimplements its upstream's *behaviour*, not its source —
original Rust, MIT-licensed throughout.

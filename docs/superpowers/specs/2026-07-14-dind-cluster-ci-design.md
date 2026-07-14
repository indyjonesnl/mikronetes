# dind-cluster CI — kind-style multi-arch smoke for the all-Rust stack (Design)

Date: 2026-07-14
Status: approved (brainstorming)
Milestone: M2e (CI)

## Problem

The only CI on mikronetes PRs was `m1-stack` (an M1 docker-compose smoke) which
built `deploy/node-cdrs` from the rusternetes fork's `main`; that path was
deleted upstream in the Calico/containerd migration, so the gate had been
red on every run and was retired. The full M2 microVM smoke (machined + CH /
qemu) needs nested KVM or emulation and does not run on stock GitHub runners —
emulated aarch64 is also where a CPU-starvation scheduler stall surfaced.

We want a CI gate that actually runs the **all-Rust container-native stack**
(rusternetes + containerd-rs + crun + flannel-rs) as a small cluster, on stock
GitHub runners, on **both x86_64 and arm64** — natively, no emulation.

## Goals

- kind-style cluster: node = a privileged Docker container running an inner
  container runtime (`containerd-rs` + `crun`), pods are nested containers.
- 1 control-plane + 2 workers, per run.
- Multi-arch: the same gate runs on `ubuntu-latest` (amd64) and
  `ubuntu-24.04-arm` (arm64) — native CPU on each, no QEMU/TCG/binfmt.
- Acceptance = **Services parity**: nodes Ready on `containerd-rs`, flannel-rs
  cross-node pod networking with distinct per-node podCIDRs, and a ClusterIP
  Service load-balancing across ≥2 worker pods on distinct nodes.
- Locally reproducible: the workflow only calls in-repo scripts.

## Non-goals

- The microVM layer (machined / cloud-hypervisor / qemu) is NOT exercised here;
  that stays in the M2 microVM harness (self-hosted / KVM follow-up).
- No in-cluster DNS / PHP DaemonSet (that is the heavier "full M2c parity" bar,
  explicitly out of scope for this gate).
- Not a conformance suite; a focused services-parity smoke.

## Architecture — two workflows + one node image

A single multi-arch **`mikronetes-node`** image (kind-style: one image, role
chosen at runtime via `ROLE`) is published to
`ghcr.io/indyjonesnl/mikronetes/node`. Two workflows:

### `publish-node.yml` (workflow_dispatch; optionally on push to `main`)
Matrix `{amd64 → ubuntu-latest, arm64 → ubuntu-24.04-arm}`. Each runner:
1. builds the rusternetes musl binaries (`all-in-one`, `kubelet`, `kube-proxy`)
   **natively** from a configurable rusternetes ref (default `main`, overridable
   to pin) using the existing `deploy/m2a/*-musl.Dockerfile`s;
2. fetches `containerd-rs` + `crun` release artifacts and the CNI plugin +
   flannel-shim binaries for its arch (reusing the `CNI_ARCH` / `CRUN_ARCH` /
   `CONTAINERD_RS_ARCH` selectors already in `m2a-build-overlay.sh`);
3. assembles + pushes a per-arch `mikronetes-node` image.
A final step stitches the two per-arch images into one multi-arch manifest.
Runs occasionally, not per-PR.

### `dind-cluster.yml` (pull_request; workflow_dispatch)
Matrix `{amd64 → ubuntu-latest, arm64 → ubuntu-24.04-arm}`. Each runner:
1. `docker pull ghcr…/mikronetes/node` (Docker auto-selects the runner arch);
2. `scripts/dind-up.sh` → `scripts/dind-smoke.sh`.
Fast (pull + run, minutes; no compile).

**Trade-off (accepted):** the PR gate tests the *published* node image plus the
PR's *harness* (compose / bootstrap / smoke scripts — the files that actually
change in this repo). Node-image / Dockerfile changes are validated by
re-running `publish-node` (a pre-merge dispatch), not automatically per PR.

## Components

### `mikronetes-node` image (multi-arch)
Contents:
- rusternetes `all-in-one`, `kubelet`, `kube-proxy` (built from source).
- `containerd-rs`, `crun` (release binaries, arch-selected).
- CNI plugins (`bridge`/`host-local`/`loopback`/`portmap`) + flannel CNI shim
  (arch-selected) + a baked `10-flannel.conflist` (host-gw).
- `iptables` (nft) userspace for kube-proxy; `ca-certificates`.
- `entrypoint.sh`: set up cgroup2 + required mounts, start `containerd-rs`
  (unix socket), then dispatch on `ROLE`:
  - `control-plane` → `all-in-one` (embedded kubelet registers node-1, tainted
    `NoSchedule`; embedded proxy/DNS disabled as in M2);
  - `worker` → `kubelet` + `kube-proxy`, pointed at the CP api-server at
    `https://10.88.0.2:6443`.
  argv/env are lifted from the proven M2 `deploy/m2a/config.yaml`
  (`--cluster-cidr 10.244.0.0/16`, baked `/boot/pki`, `--disable-dns`,
  `CONTAINERD_STREAM_HOST=127.0.0.1`, `CONTAINER_RUNTIME_ENDPOINT`).

### Cluster (in-repo `compose.dind.yml`) on bridge `mikronetes-net` (10.88.0.0/24)
Mirrors M2 addressing so the M2 PKI, `bootstrap-cluster.yaml`,
`flannel-rs.yaml`, and conflist assets reuse directly.
- `registry` (registry:2) at `10.88.0.1:5000`. The CI seeds it with the
  arch-matched `flannel-rs`, `whoami`, `busybox` (runner docker pulls → pushes);
  node `containerd-rs` treats `10.88.0.1:5000` as an insecure registry (M2's
  pattern — avoids musl-CA / node-egress issues).
- `node-1` control-plane (10.88.0.2, tainted), `node-2`/`node-3` workers
  (10.88.0.3 / 10.88.0.4). All `--privileged`, static IPs, distinct podCIDRs
  10.244.0.0/24 / 10.244.1.0/24 / 10.244.2.0/24.

flannel-rs runs as a **DaemonSet** (image pulled from the seeded registry,
multi-arch); only its CNI shim + conflist are baked into the node image.

### Harness scripts (in-repo; the workflow only calls these)
- `scripts/dind-up.sh` — `compose up` the 3 nodes + registry → wait CP api →
  seed registry → `kubectl` (insecure, `--token dummy`) apply
  `bootstrap-cluster.yaml` (kubernetes Service `.1`, namespaces/RBAC,
  **priorityclasses**), per-node podCIDRs, flannel-rs DaemonSet, a **`whoami`
  Deployment (2 replicas, one per worker via pod anti-affinity)** + a ClusterIP
  Service → wait workers Ready + pods Running + Service endpoints.
- `scripts/dind-smoke.sh` — the services-parity assertions (below).

Workload is a **Deployment** (not a DaemonSet) so the gate exercises the
rusternetes scheduler on native hardware.

## Data flow

1. `dind-cluster.yml` (per arch) → `docker pull …/node` → `dind-up.sh`.
2. compose up 3 privileged node containers + registry → each entrypoint starts
   `containerd-rs` then its role process → `all-in-one` serves the api-server
   at 10.88.0.2:6443 → workers' `kubelet` register.
3. Seed registry (arch-matched images) → apply bootstrap-cluster.yaml,
   per-node podCIDRs, flannel-rs DS, whoami Deployment (2 replicas, one per
   worker) + ClusterIP Service.
4. `dind-smoke.sh` asserts and exits non-zero on any failure.

## Smoke assertions (services parity)

- All 3 nodes `Ready` with `containerd-rs://<version>` as the runtime.
- Worker pods get IPs from their distinct podCIDRs (10.244.1.x on node-2,
  10.244.2.x on node-3); no duplicate pod IPs.
- A busybox **probe pod** curls the Service ClusterIP 20× and observes **≥2
  distinct backend hostnames on distinct worker nodes** (kube-proxy DNAT +
  flannel-rs cross-node routing).
- Identical assertions pass on amd64 and arm64.

## Error handling

- Every wait loop is bounded with a clear timeout.
- On any timeout/failure, a diagnostics step dumps `docker ps`, each node's
  `containerd-rs` / rusternetes / `kube-proxy` logs, and
  `kubectl get nodes,pods -A -o wide`.
- Cleanup step always runs `docker compose -f compose.dind.yml down -v`.

## Testing

The harness is the test. `scripts/dind-up.sh` + `scripts/dind-smoke.sh` run
locally against Docker on either arch; the workflows are thin wrappers. A
`bash -n` check of the new scripts joins the existing `harness-ci` gate.

## Reuse of existing assets

- `deploy/m2a/*-musl.Dockerfile` (all-in-one / kubelet / kube-proxy builds).
- `m2a-build-overlay.sh` arch selectors + CNI/crun/containerd-rs fetch logic +
  the baked `10-flannel.conflist` + PKI generation.
- `deploy/m2a/flannel-rs.yaml`, the M2 `bootstrap-cluster.yaml`, and the
  probe-pod / cross-node-LB pattern from `m2c-smoke.sh` / `m2c1-smoke.sh`.
- M2 addressing (10.88.0.0/24, 10.244.0.0/16) and argv/env from
  `deploy/m2a/config.yaml`.

## Decisions

- Single multi-arch node image, role via `ROLE` (kind-style).
- 1 control-plane + 2 workers.
- Prebuilt GHCR images (publish workflow), pulled by the per-PR gate.
- Workload = whoami Deployment (exercises the scheduler).
- Local insecure registry sidecar for image distribution (M2 pattern).

## Deferred / follow-ups

- Full M2c parity (DNS + PHP DaemonSet + Service-by-name) as a heavier optional
  job.
- MicroVM (machined/CH/qemu) smoke on a KVM/self-hosted ARC runner.
- Auto-rebuild the node image in the PR gate when the node Dockerfile/source
  changes (path-filtered), if pull-prebuilt proves too coarse.

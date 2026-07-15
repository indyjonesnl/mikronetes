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

We want a CI gate that runs the **all-Rust container-native stack**
(rusternetes + containerd-rs + crun + flannel-rs) as a small cluster, on stock
GitHub runners, on **both x86_64 and arm64** — natively, no emulation.

The rusternetes fork now publishes **multi-arch (amd64+arm64)** images for its
control-plane and node components (`api-server`, `scheduler`,
`controller-manager`, `kubelet`, `kube-proxy`, `dns`), so the gate can consume
prebuilt binaries and skip compiling rusternetes. (There is no `all-in-one`
image — the fork runs a componentized control plane.)

## Goals

- kind-style cluster: node = a privileged Docker container running an inner
  container runtime (`containerd-rs` + `crun`); pods are nested containers.
- 1 control-plane + 2 workers, per run.
- Multi-arch: the same gate runs on `ubuntu-latest` (amd64) and
  `ubuntu-24.04-arm` (arm64) — native CPU on each, no QEMU/TCG/binfmt.
- Acceptance = **Services parity**: nodes Ready on `containerd-rs`, flannel-rs
  cross-node pod networking with distinct per-node podCIDRs, and a ClusterIP
  Service load-balancing across ≥2 worker pods on distinct nodes.
- Fast: no rusternetes compile — pull the fork's multi-arch binaries; the node
  image is a COPY-only assembly. Whole gate is minutes.
- Locally reproducible: the workflow only calls in-repo scripts.

## Non-goals

- The microVM layer (machined / cloud-hypervisor / qemu) is NOT exercised here;
  that stays in the M2 microVM harness (self-hosted / KVM follow-up).
- No in-cluster DNS / PHP DaemonSet (heavier "full M2c parity" bar, out of scope
  for this gate).
- Not a conformance suite; a focused services-parity smoke.
- No building rusternetes from source (the fork's multi-arch images are consumed
  as-is).

## Architecture — one workflow, one node image

A single **`dind-cluster.yml`** workflow (pull_request + workflow_dispatch),
matrix `{amd64 → ubuntu-latest, arm64 → ubuntu-24.04-arm}`. Each runner, on its
native arch:

1. **COPY-only assembles a `mikronetes-node` image** (kind-style: one image,
   role via `ROLE`). A multi-stage Dockerfile `COPY --from` the fork's
   **multi-arch** component images (Docker pulls the runner-arch variant — no
   emulation) and adds the `containerd-rs` / `crun` / CNI-plugin / flannel-shim
   release artifacts for the arch. No compile — a fast COPY build (~1-2 min).
2. `scripts/dind-up.sh` → `scripts/dind-smoke.sh`.

There is **no separate publish workflow** — because the fork already publishes
the multi-arch binaries, assembly is cheap enough to run inline per PR, which
also means the gate tracks the fork images the harness will actually use.

A `RUSTERNETES_IMAGE_TAG` var (default `main`, pinnable to a tag/digest) fixes
which fork images are consumed, so a fork push can't silently break the gate.

`containerd-rs` / `crun` are not in the fork's GHCR (separate repos); they are
fetched from their own release artifacts (arm64 + amd64 both available),
reusing the `CONTAINERD_RS_ARCH` / `CRUN_ARCH` / `CNI_ARCH` selectors already in
`m2a-build-overlay.sh`.

## Components

### `mikronetes-node` image (assembled per-arch, COPY-only)
A multi-stage Dockerfile:
- `COPY --from=ghcr.io/indyjonesnl/rusternetes/<c>:${TAG}` the binaries for
  `api-server`, `scheduler`, `controller-manager`, `kubelet`, `kube-proxy`
  (paths per the fork image layout, resolved during implementation).
- adds `containerd-rs`, `crun` (release binaries, arch-selected), CNI plugins
  (`bridge`/`host-local`/`loopback`/`portmap`) + flannel CNI shim, and a baked
  `10-flannel.conflist` (host-gw).
- base has `iptables` (nft) for kube-proxy + `ca-certificates`.
- `entrypoint.sh`: set up cgroup2 + required mounts, start `containerd-rs`
  (unix socket), then dispatch on `ROLE`:
  - `control-plane` → run `api-server` + `scheduler` + `controller-manager`
    (rhino-sqlite storage); node-1 tainted `NoSchedule`; embedded DNS not used.
  - `worker` → `kubelet` + `kube-proxy`, pointed at the CP api-server at
    `https://10.88.0.2:6443`.
  argv/env are lifted from the proven M2 configuration
  (`--cluster-cidr 10.244.0.0/16`, baked `/boot/pki`,
  `CONTAINERD_STREAM_HOST=127.0.0.1`, `CONTAINER_RUNTIME_ENDPOINT`), adapted from
  the all-in-one flags to the componentized api-server/scheduler/CM flags.

### Cluster (in-repo `compose.dind.yml`) on bridge `mikronetes-net` (10.88.0.0/24)
Mirrors M2 addressing so the M2 PKI, `bootstrap-cluster.yaml`,
`flannel-rs.yaml`, and conflist assets reuse directly.
- `registry` (registry:2) at `10.88.0.1:5000`. CI seeds it with the arch-matched
  `flannel-rs`, `whoami`, `busybox` (runner docker pulls → pushes); node
  `containerd-rs` treats `10.88.0.1:5000` as an insecure registry (M2's pattern —
  avoids musl-CA / node-egress issues).
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

1. `dind-cluster.yml` (per arch) → COPY-only `docker build` of `mikronetes-node`
   (pulls the fork's arch-matched component images + release artifacts) →
   `dind-up.sh`.
2. compose up 3 privileged node containers + registry → each entrypoint starts
   `containerd-rs` then its role processes → CP serves the api-server at
   10.88.0.2:6443 → workers' `kubelet` register.
3. Seed registry (arch-matched images) → apply bootstrap-cluster.yaml, per-node
   podCIDRs, flannel-rs DS, whoami Deployment (2 replicas, one per worker) +
   ClusterIP Service.
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
  `containerd-rs` / rusternetes-component / `kube-proxy` logs, and
  `kubectl get nodes,pods -A -o wide`.
- Cleanup step always runs `docker compose -f compose.dind.yml down -v`.

## Testing

The harness is the test. `scripts/dind-up.sh` + `scripts/dind-smoke.sh` run
locally against Docker on either arch; the workflow is a thin wrapper. A
`bash -n` check of the new scripts joins the existing `harness-ci` gate.

## Reuse of existing assets

- `m2a-build-overlay.sh` arch selectors + containerd-rs/crun/CNI fetch logic +
  the baked `10-flannel.conflist` + PKI generation.
- `deploy/m2a/flannel-rs.yaml`, the M2 `bootstrap-cluster.yaml`, and the
  probe-pod / cross-node-LB pattern from `m2c-smoke.sh` / `m2c1-smoke.sh`.
- M2 addressing (10.88.0.0/24, 10.244.0.0/16) and the argv/env baseline from
  `deploy/m2a/config.yaml` (adapted all-in-one → componentized CP flags).

## Decisions

- Single workflow `dind-cluster.yml`; no separate publish workflow.
- Consume the fork's multi-arch component images; node image is COPY-only.
- Control plane is componentized (api-server + scheduler + controller-manager),
  since the fork ships no all-in-one image.
- Single multi-arch-agnostic node image, role via `ROLE` (kind-style).
- 1 control-plane + 2 workers.
- Workload = whoami Deployment (exercises the scheduler).
- Local insecure registry sidecar for image distribution (M2 pattern).
- `RUSTERNETES_IMAGE_TAG` (default `main`, pinnable) fixes the consumed fork
  images.

## Deferred / follow-ups

- Full M2c parity (DNS + PHP DaemonSet + Service-by-name) as a heavier optional
  job.
- MicroVM (machined/CH/qemu) smoke on a KVM/self-hosted ARC runner.
- If the fork ever publishes `containerd-rs`/`crun` node artifacts or an
  `all-in-one` image, revisit the assembly.

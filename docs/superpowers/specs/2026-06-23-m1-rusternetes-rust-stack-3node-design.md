# Design — M1: 3-node rusternetes on the Rust stack (containers), measured

**Date:** 2026-06-23
**Status:** Approved (framing); bring-up mechanics to be verified against the `fork/main` worktree at plan time
**Milestone:** M1 of the mikronetes North Star (M1 containers → M2 Cloud Hypervisor microVMs on a LAN → M3 conformance suite-by-suite)

## Goal

Stand up a **1 control-plane + 2 worker** rusternetes cluster whose data plane is the
all-Rust stack — **containerd-rs (CRI) + crun (OCI) + flannel-rs (CNI)** — prove it
converges and serves a pod **cross-node**, and produce a **per-component memory
breakdown**. Fast environment (docker compose) for iteration; this is the dress
rehearsal for the Cloud Hypervisor microVMs in M2.

## Why this is now an assembly job (not a build-from-scratch)

The real rusternetes is **`indyjonesnl/rusternetes` `fork/main`** (local remote `fork`;
NOT `origin`=calfonso upstream, NOT the stale local checkout `ci/per-binary-ghcr-images`).
`fork/main` is **CNI/CRI/OCI**: bollard/Docker-API removed; it has `crates/cri`
(`RuntimeServiceClient` gRPC → drives containerd-rs), `crates/kubelet/src/cni/` (CNI →
flannel-rs), `compose.flannel.yml`, `deploy/flannel/flannel-rs.yaml`,
`deploy/{node,containerd}/entrypoint.sh`, multi-node composes, `scripts/bootstrap-cluster.sh`,
and a full conformance harness (`scripts/conformance-*.sh`, the M3 tooling). So M1 wires
existing pieces into a measured 3-node bring-up; it does not build the integration.

## Architecture

- **Control plane (node 1):** rusternetes api-server + scheduler + controller-manager +
  DNS, backed by **rhino** (shared SQLite-over-etcd-API gRPC — the proven multi-node
  store; per-node `--storage-backend sqlite` files would be 3 disjoint clusters, so rhino
  is required).
- **Workers (nodes 2 & 3):** rusternetes **kubelet** → **CRI gRPC** → **containerd-rs**
  socket → **crun**; **flannel-rs** for pod networking (VXLAN); kube-proxy.
- **Assembly:** fork/main's `compose.flannel.yml` + `deploy/{node,containerd}` entrypoints,
  using prebuilt **GHCR images** if available (build-free) else a cargo build. Topology
  extended to control-plane + 2 workers if the shipped compose isn't already 3-node.

## Components / files (mikronetes side)

- **`rusternetes-m1` worktree** (off `fork/main`, branch `mikronetes/m1`) — isolated
  build/run tree; the user's `../rusternetes` checkout stays untouched.
- **A mikronetes M1 harness** (thin wrapper, likely `scripts/m1-up.sh` +
  `scripts/m1-smoke.sh`) that brings up the 3-node Rust-stack cluster via fork/main's
  composes, gates convergence, and runs the memory breakdown.
- **Reuse** `scripts/mem-breakdown.{sh,py}` and `scripts/mem-sampler.sh`/`mem-report.py`
  from the measurement work for the per-component PSS table.

## Success criteria (gate-then-measure)

1. Both worker nodes reach **`Ready`**, with the kubelet driving **containerd-rs over
   CRI** (verified — not a fallback runtime).
2. A pod schedules on a worker, runs via **crun**, and is reachable **cross-node** over
   **flannel-rs** (proves the VXLAN/CNI path end-to-end).
3. A **per-component PSS table** (api-server, scheduler, controller-manager, kubelet,
   containerd-rs, flannel-rs, crun, rhino) — the all-Rust analogue of the k0s breakdown,
   to compare against k0s (control-plane node ~588 MiB; workers ~340 MiB; see
   `control-plane-memory-comparison`).

## Measure-only (no cap in M1)

Per the agreed approach, M1 does **not** impose the 512 MB cap — bring it up, measure
real per-component memory on the Rust stack, then the 512 MB target is enforced in M2
(microVMs with real guest RAM). 512 MiB stays a reference line in the report.

## To verify against the `fork/main` worktree at plan time

(Resolved in the implementation plan, not assumed here.)
- Whether **GHCR images** exist for a build-free bring-up vs a required cargo build.
- Exact `compose.flannel.yml` topology — already multi-node, or add worker2/3.
- How the kubelet is **pointed at the containerd-rs CRI socket** (flag/endpoint) and how
  containerd-rs + crun are launched per node (`deploy/{node,containerd}/entrypoint.sh`).
- Worker → shared-rhino join mechanics (node-name, store endpoint, certs from
  `generate-certs.sh`/`bootstrap-cluster.sh`).
- Whether flannel-rs converges in docker compose (it failed under k0s's nested-docker; on
  fork/main the conformance harness already runs containerized, so the path is exercised —
  but cross-node VXLAN in compose is the key risk to validate early).

## Out of scope (later milestones)

- Cloud Hypervisor / microVMs, machined-rs as PID 1 (M2).
- The 512 MB hard cap (M2).
- Ginkgo conformance suites (M3 — reuse fork/main's `scripts/conformance-*`).

## Success = M1 done

`scripts/m1-smoke.sh` brings up the 3-node Rust-stack cluster from `fork/main`, both
workers Ready on containerd-rs+crun, a pod served cross-node over flannel-rs, and a
per-component memory breakdown is produced and recorded for the k0s comparison.

# Design — CNI memory comparison: kube-router vs flannel-rs (measure-only)

**Date:** 2026-06-22
**Status:** Approved (design); implementation pending
**Branch:** `experiment/cni-memory-compare` (off green `origin/main`, stock k0s — canary work stays separate)

## Goal

Measure and compare the memory footprint of a stock k0s cluster using its default
**kube-router** CNI versus the same cluster using **flannel-rs** (the Rust CNI,
`ghcr.io/indyjonesnl/flannel-rs`). **No memory caps** — we observe real usage, not
enforce a limit. Output: avg + peak memory per node for each variant, side by side,
with the delta, plus raw per-sample CSVs.

## Pivot from the prior 512MB gate

- **No more `--memory`/`memswap` caps.** Remove them from compose so nothing is
  OOM-killed; the sampler simply records `docker stats`. 512 MiB stays only as a
  **reference line** in the report ("% of 512 MiB" = how close to the Pi budget),
  not a kill threshold.
- The containerd-rs/crun canary is **out of scope** here — both variants run plain
  stock k0s so the only variable is the CNI.
- Each variant is **gated then measured**: it must reach the working state (both
  workers `Ready` + a hello pod served over the CNI) before its memory counts; a
  variant that can't converge is reported failed, not silently measured.

## Variants

| | CNI | k0s config |
|---|---|---|
| **A** | kube-router (k0s default) | `poc/k0s.yaml` (kine; no `provider` ⇒ kube-router) |
| **B** | flannel-rs | `poc/k0s-flannel-rs.yaml` (kine; `spec.network.provider: custom`) + apply `poc/flannel-rs-release.yaml` |

Note (B): with `provider: custom` k0s installs no CNI, so workers stay `NotReady`
until flannel-rs is applied and running — the harness applies it right after
cluster-up, *before* waiting for Ready.

## Components

- **`compose.yaml`** (modify): remove `mem_limit`/`memswap_limit`; mount the k0s
  config from `${K0S_CONFIG:-./poc/k0s.yaml}` so a variant can swap it. 1
  control-plane + 2 workers unchanged.
- **`poc/k0s-flannel-rs.yaml`** (new): kine storage + `spec.network.provider: custom`.
- **`poc/flannel-rs-release.yaml`** (new): vendored copy of flannel-rs's
  `deploy/flannel-rs-release.yaml` (pinned to a release image tag, not `:latest`,
  for reproducibility), applied for variant B.
- **`scripts/mem-sampler.sh`**, **`scripts/mem-report.py`**, **`scripts/test_mem_report.py`**
  (new; reused from the metrics work): poll `docker stats` → CSV; CSV → avg/peak/%512
  Markdown table; unit test. mem-report keeps "% of 512 MiB" as a reference column.
- **`scripts/compare-cni.sh`** (new): the orchestrator. For each variant:
  1. `cluster-down` (clean slate) → `K0S_CONFIG=<variant>` `cluster-up`.
  2. Variant B only: `kubectl apply -f poc/flannel-rs-release.yaml`.
  3. Start `mem-sampler.sh` → `mem-samples-<variant>.csv`.
  4. Gate: wait both workers `Ready` (timeout), deploy hello, wait Available, expose
     NodePort, curl until it serves. On timeout → record the variant as FAILED.
  5. Stop sampler; tear down.
  Then render each variant's avg/peak table and a **side-by-side comparison
  (per node: kube-router vs flannel-rs + delta)**; write to stdout and, if set,
  `$GITHUB_STEP_SUMMARY`.
- **`.github/workflows/cni-compare.yml`** (new, `workflow_dispatch`): runs
  `compare-cni.sh`, uploads both CSVs + the comparison as artifacts. Separate from
  the smoke gate (this is an on-demand experiment, not a per-PR gate).

## Data flow

per variant: cluster-up (variant config) → [apply flannel-rs] → sampler polls
`docker stats` every 2s → CSV → gate checks → teardown. After both: mem-report on
each CSV → side-by-side table (+ delta) → stdout / job summary; CSVs as artifacts.

## Error handling

- A variant that fails the gate is reported `FAILED (did not converge)` with its
  partial memory captured; the other variant still runs and reports. The script's
  exit code is non-zero if either variant failed, so a broken variant is visible.
- Sampler is best-effort (skips absent containers, never fatal).
- flannel-rs in containers needs `privileged`/`NET_ADMIN` + VXLAN across the compose
  network — if it can't establish pod networking, variant B fails the gate (an
  honest negative result, not a crash).

## Testing

- `mem-report.py` unit-tested (parse/aggregate/render) — runnable without docker.
- `compare-cni.sh` / `mem-sampler.sh`: `bash -n` syntax; live sampler smoke.
- End-to-end: run `compare-cni.sh` locally; expect a side-by-side table. Variant A
  (kube-router) is known-good; variant B (flannel-rs) is the experiment — its
  convergence is itself a finding.

## Out of scope

- Enforcing any memory limit (measure-only now).
- containerd-rs/crun canary (separate WIP).
- Persistent cross-run charting (raw CSV artifacts only, as before).
- flannel-go baseline (kube-router vs flannel-rs is the comparison asked for).

## Success criteria

`scripts/compare-cni.sh` brings up both variants, gates each (2 workers Ready +
hello served over that CNI), and prints a side-by-side avg/peak-per-node table with
the kube-router-vs-flannel-rs delta; raw CSVs are produced; mem-report math is
unit-tested. A variant failing to converge is reported explicitly, not hidden.

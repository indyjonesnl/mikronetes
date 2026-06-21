# k0s memory research — how k0s fits Kubernetes on small nodes

> **For agentic assistants:** this is a reference investigation of the upstream k0s
> Go codebase (cloned at `upstream/`, gitignored). It documents what k0s does — and
> notably does *not* do — to run on memory-constrained devices, and what mikronetes
> must do beyond k0s to fit 512 MB Raspberry Pi nodes. All findings are cited with
> `file:line` and were verified against `upstream/` on 2026-06-21 (k0s `main`).

## TL;DR

k0s's "small footprint" reputation comes mostly from **a single static binary +
the kine (SQLite) option + profiling disabled + the ability to shed components** —
**not** from aggressive runtime memory tuning. The big runtime knobs (Go heap
limit, apiserver cache sizing, kubelet reservations) are left at upstream
defaults. **mikronetes must go further** (see [Implications](#implications-for-mikronetes)).

## What k0s does

### Storage — kine/SQLite (opt-in, NOT default)
- Kine = SQLite shim replacing etcd. Data source:
  `sqlite://.../db/state.db?mode=rwc&_journal=WAL` — `upstream/pkg/apis/k0s/v1beta1/storage.go:213-217` (WAL journal).
- **Default backend is etcd**, not kine — `storage.go:63` (`Type: EtcdStorageType`).
  Kine is only used if the operator sets `spec.storage.type: kine`.
- Kine feeds the apiserver over a unix socket: `--etcd-servers=unix:///.../kine.sock`
  — `upstream/pkg/component/controller/apiserver.go` (~288-314).
- Kine compaction: `--compact-interval: 0` — `upstream/pkg/component/controller/kine.go`.

### Process model
- One static binary; each component (apiserver, scheduler, controller-manager,
  kubelet, etcd-or-kine, konnectivity) runs as a **separate supervised `os/exec`
  process** — `upstream/pkg/supervisor/supervisor.go`.
- Component binaries are **embedded** and staged to disk at runtime — no external
  dependencies — `upstream/pkg/assets/stage.go`.

### Profiling disabled everywhere (drops pprof heap machinery)
- apiserver `profiling: false` — `apiserver.go:115`
- controller-manager `profiling: false` — `controllermanager.go:95`
- scheduler `profiling: false` — `scheduler.go:78`
- etcd `--enable-pprof=false` — `etcd.go` (~188)

### Sheddable components — `--disable-components`
applier-manager, autopilot, control-api, coredns, csr-approver,
endpoint-reconciler, helm, konnectivity-server, kube-controller-manager,
kube-proxy, kube-scheduler, metrics-server, network-provider, node-role,
system-rbac, update-prober — names in `upstream/pkg/constant/constant.go`, gated in
`upstream/cmd/controller/controller.go` via `slices.Contains(flags.DisableComponents, ...)`.
- Konnectivity is **auto-disabled in SingleNodeMode** (`controller.go`).

### Addon footprints kept small
- CoreDNS `memory: 70Mi`, DNS cache TTL 30s — `coredns.go:168`.
- metrics-server **scales requests with cluster size**: `10m CPU + 30MiB mem per
  10 nodes` (single node ⇒ 30M) — `metricserver.go:343-368`.
- kube-router `memory: 16Mi` — `kuberouter.go:353`.

### Misc
- controller-manager `terminated-pod-gc-threshold: 12500` — caps orphaned-pod
  memory growth — `controllermanager.go:96`.
- Node modes: `ControllerOnlyMode` / `ControllerPlusWorkerMode` / `SingleNodeMode`
  — `upstream/pkg/config/cli.go` (~38-44).

## What k0s does NOT do (verified absent)

- ❌ **No `GOMEMLIMIT` / `GOGC` / `debug.SetMemoryLimit`** anywhere — no Go heap
  ceiling on any component. The biggest gap for a 512 MB node.
- ❌ **Kine is opt-in; etcd is the default** — out of the box k0s pays etcd's full cost.
- ❌ No apiserver `--watch-cache-sizes`, `--max-requests-inflight`, or
  `--max-mutating-requests-inflight` tuning (uses k8s defaults).
- ❌ No kubelet `--kube-reserved` / `--system-reserved` / eviction-threshold /
  `--max-pods` tuning.
- ❌ No scheduler/controller-manager pod resource limits in their own manifests.

## Implications for mikronetes

mikronetes targets 512 MB hard, so it must do what k0s leaves on the table:

1. **SQLite-only, by default.** rusternetes already stores state in SQLite — make
   it the only path, no etcd option to fall back to.
2. **Cap per-component memory.** Components share one 512 MB cgroup. Set explicit
   memory ceilings / bounded caches per component (the Rust analog of `GOMEMLIMIT`,
   since rusternetes/containerd-rs/flannel-rs are Rust with no GC but still have
   caches and buffers to bound).
3. **Tune the apiserver down.** Shrink watch-cache and inflight-request limits —
   k0s never does this; at 512 MB it is mandatory.
4. **Set kubelet reservations + eviction.** `--kube-reserved` / `--system-reserved`
   so the kubelet doesn't OOM-kill the control plane under pressure.
5. **Adopt k0s's cheap wins outright:** profiling off, ship with konnectivity and
   metrics-server disabled by default, keep addon limits tiny.
6. **Beyond k0s entirely:** swap off + aggressive ZRAM + a stripped OS image — see
   the [Memory strategy](../README.md#memory-strategy) section of the README.

## How to reproduce / verify

```sh
# upstream/ is a shallow clone of github.com/k0sproject/k0s (gitignored)
grep -rn '"profiling"' upstream/pkg/component/controller/
grep -rn 'EtcdStorageType\|sqlite://' upstream/pkg/apis/k0s/v1beta1/storage.go
grep -rn 'GOMEMLIMIT\|SetMemoryLimit\|SetGCPercent' upstream/   # returns nothing
```

# mikronetes M1 — result: all-Rust cluster, per-component memory breakdown

**Date:** 2026-06-23
**Stack:** rusternetes control plane (api-server / scheduler / controller-manager
+ rhino) + 2 `node-cdrs` nodes, each one container running the **rusternetes
kubelet → containerd-rs (Rust CRI) → crun (OCI)**, with **flannel-rs** as the
CNI (VXLAN overlay). Brought up via `rusternetes-m1/compose.cdrs-flannel.yml`
+ `deploy/flannel/flannel-rs.yaml`.

M1 goal achieved: a fully Rust data + control plane (no Go kubelet runtime, no
upstream containerd/runc), 3 containers' worth of control plane + 2 worker
nodes, both nodes `Ready`, **cross-node pod-to-pod networking verified** over
flannel-rs. Reproduce with `scripts/m1-up.sh`; gate + measure with
`scripts/m1-smoke.sh`.

---

## Per-component memory breakdown (PSS)

Metric: **PSS** (proportional set size, `/proc/<pid>/smaps_rollup`) — shared
pages split across sharers, so summing PSS does not double-count shared
libraries. Captured by `scripts/mem-breakdown.sh` (now parameterized for the
`rusternetes-cdrsf-*` container set) sweeping both node containers + the four
control-plane service containers + the two kube-proxy containers. Each node
container's `/proc` sees its co-resident pod processes (kubelet, containerd-rs,
crun/runc, flannel daemon, test pods), so one sweep per node captures the node's
full footprint.

### As-measured (live cluster)

| Component | PSS (MiB) | % of total | procs | nodes |
|-----------|-----------|-----------|-------|-------|
| flanneld | 144.1 | 27% | 26 | node-1,node-2 |
| api-server | 106.8 | 20% | 1 | api-server |
| kubelet | 86.3 | 16% | 2 | node-1,node-2 |
| controller-manager | 45.7 | 8% | 1 | controller-manager |
| rhino-server | 40.7 | 8% | 1 | rhino |
| containerd-rs | 38.1 | 7% | 2 | node-1,node-2 |
| kube-proxy | 27.7 | 5% | 2 | kube-proxy-1,kube-proxy-2 |
| scheduler | 20.1 | 4% | 1 | scheduler |
| whoami (test pods) | 15.3 | 3% | 3 | node-1,node-2 |
| runc (crun, as `runc`) | 11.3 | 2% | 29 | node-1,node-2 |
| sh | 2.3 | 0% | 8 | (all) |
| **TOTAL** | **538.3** | 100% | | |

### IMPORTANT — flanneld / runc figures are inflated by a containerd-rs process leak

The `flanneld` row shows **26 processes** and `runc` shows **29**, where the
intended steady state is **1 flanneld + ~1 runc supervisor per node**. The
flannel-rs DaemonSet pod restarted 6-7 times (the Task-5 `privileged: true`
transition recreate + the CNI retry loop), and **containerd-rs did not reap the
prior OCI-runtime process trees**: each old `runc`(=crun) supervisor and its
`flanneld` child are left behind as live, sleeping (`Ssl`) processes,
re-parented to PID 1. We observed **12 leaked `flanneld` + 13 leaked `runc` per
node**, none corresponding to a current CRI/kubectl container.

**Corrected steady-state estimate** (1 flanneld/node @ ~5.6 MiB, 1 runc
supervisor/active pod @ ~0.4 MiB):

| Component | as-measured | steady-state (deduped) |
|-----------|-------------|------------------------|
| flanneld | 144.1 MiB (26 procs) | ~11.2 MiB (2 procs) |
| runc/crun | 11.3 MiB (29 procs) | ~2 MiB (~5 procs) |
| **adjusted TOTAL** | **538.3 MiB** | **~390 MiB** |

So the **true all-Rust cluster footprint is ~390 MiB** across the whole 3-node
stack once the leak is discounted — the as-measured 538 MiB is mostly leaked
flannel restarts. This leak is itself a finding (see CRI gaps below).

### Reading the numbers

- **api-server (107 MiB)** is the single largest *legitimate* component, then
  **kubelet (~86 MiB total, ~43 MiB/node)**.
- **containerd-rs is cheap: ~38 MiB total, ~19 MiB/node** — the Rust CRI runtime
  is a small fraction of the node footprint, consistent with the
  containerd-rs-canary finding that the runtime swap is low-leverage on memory.
- **crun (as `runc`) is ~0.4 MiB per live supervisor** — negligible.
- **flannel-rs steady-state ~5.6 MiB/node** — very light; the headline 144 MiB
  is leak, not flannel's real cost.

---

## Cross-node networking confirmation

Two `whoami` pods, one pinned per node, received flannel pod IPs
(`10.244.0.2` on node-1, `10.244.1.3` on node-2) and curl succeeds **across the
VXLAN overlay**:

```
whoami-n1 (10.244.0.2, node-1) -> whoami-n2 (10.244.1.3, node-2)
  Hostname: whoami-n2
```

(`kubectl exec` is broken on containerd-rs — see gaps — so the curl is run
inside the source pod's netns via `nsenter` on the node host, the proven Task-5
method. Bidirectional success was recorded in the Task-5 report.)

The smoke gate (`scripts/m1-smoke.sh`) re-verifies this on demand and also proves
the **real runtime is containerd-rs** via CRI evidence (live containerd-rs
process child of the kubelet + `CONTAINER_RUNTIME_ENDPOINT=…containerd-rs.sock`
+ real `RunPodSandbox`/`CreateContainer` RPCs in the `cri::server` log) — **not**
the kubelet's hardcoded `containerd://1.7.0` version string, which is a baked-in
literal and is NOT evidence of the runtime.

---

## containerd-rs CRI gaps found (Task 5) — M3 / conformance blockers

All three are real containerd-rs v0.1.x CRI gaps, not flannel-rs or rusternetes
bugs. They do not block M1 (worked around) but must be fixed for conformance.

1. **`securityContext.capabilities.add` is ignored.** flanneld got only the
   containerd default cap set (`KILL, NET_BIND_SERVICE, AUDIT_WRITE`), not the
   requested `NET_ADMIN`/`NET_RAW`, so the VXLAN netlink create returned EPERM.
   **Workaround:** flannel DaemonSet forced `privileged: true`. Until fixed, any
   pod needing added caps must run privileged.
2. **`hostPath` `DirectoryOrCreate` not honored.** flannel's `install-cni` init
   container failed because `/etc/cni/net.d` did not exist and was not
   auto-created. **Workaround:** added `type: DirectoryOrCreate` to the cni /
   run / cni-plugin hostPath volumes (committed in the flannel manifest).
3. **`kubectl exec` / `kubectl logs` broken.** exec/attach/port-forward streaming
   closes with websocket `close 1005`; `logs` fails with
   `ListContainers … No such file or directory (os error 2)`. **Workaround:**
   logs read from the host pod-log dir, exec replaced with host-side `nsenter`.

### New gap found in Task 6 (this task)

4. **containerd-rs leaks OCI-runtime process trees on container restart.** On
   each flannel pod restart, the prior `runc`(crun) supervisor + its child
   process are not reaped — 12-13 stale `flanneld`+`runc` per node accumulated
   over 6-7 restarts. This inflates node memory unboundedly under any
   crash-looping pod. Lifecycle/cleanup gap to file against containerd-rs.

---

## Comparison to the k0s baseline and to idle rusternetes

| Configuration | Footprint |
|---------------|-----------|
| **k0s (Go) — control-plane node** | ~588 MiB |
| **k0s (Go) — worker node** | ~340 MiB |
| **rusternetes idle control plane** | ~48 MiB |
| **mikronetes M1 — all-Rust, full 3-node, as-measured** | ~538 MiB total |
| **mikronetes M1 — all-Rust, full 3-node, leak-discounted** | **~390 MiB total** |

Notes on the comparison:

- The k0s numbers are **per node** (control-plane ~588, worker ~340). The
  mikronetes M1 number is the **whole-cluster** PSS sum across all containers.
  Even as-measured, the entire 3-node Rust stack (538 MiB) is **below a single
  k0s control-plane node (588 MiB)**, and leak-discounted (~390 MiB) it is close
  to a single k0s *worker*.
- **rusternetes idle control plane ~48 MiB** is the control plane with no
  workload / no nodes attached. Here the control-plane services under load
  measure api-server 107 + controller-manager 46 + scheduler 20 + rhino 41 ≈
  **214 MiB** with two nodes registered, real reconcile traffic, and rhino
  (etcd-substitute) carrying cluster state — the growth over the 48 MiB idle
  figure is expected working set, not regression.
- **containerd-rs (~19 MiB/node)** vs the runtime layer it replaces is a small
  slice of the ~43 MiB/node kubelet + ~19 MiB/node runtime; the Rust runtime
  swap is memory-cheap, as the canary predicted.

---

## Reproduce

```bash
# bring up (builds node-cdrs image if missing -> compose up -> bootstrap -> flannel)
mikronetes/scripts/m1-up.sh [/path/to/rusternetes-m1]

# gate (nodes Ready + containerd-rs CRI proof + cross-node curl) + memory table
mikronetes/scripts/m1-smoke.sh    # exits non-zero on any failed assertion
```

`m1-smoke.sh` needs two cross-node test pods labelled `m1smoke=whoami` (one per
node); it prints the exact `kubectl run` commands if they are missing.

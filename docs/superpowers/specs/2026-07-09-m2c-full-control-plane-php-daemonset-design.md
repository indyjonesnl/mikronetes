# M2c — Full Control Plane + PHP DaemonSet Behind a Service

## Goal

Prove that mikronetes can run a real, self-contained control plane and serve a
workload — a PHP website as a 3-replica DaemonSet fronted by one Service — on
the four-node 512 MiB microVM cluster, using only the all-Rust stack plus
`crun`.

M2b proved the data-plane shape: four nodes Ready at 512 MiB, flannel host-gw
cross-node pod networking, per-node podCIDRs. But M2b ran a **stripped**
control plane: no DNS, no Service proxying, no persistent storage. M2c closes
that gap by standing up the integrated control plane and running a
representative workload through it.

The single question M2c answers: **does the full control plane
(api-server + scheduler + controller-manager + DNS + kube-proxy +
rhino-SQLite storage) fit inside node-1's 512 MiB and correctly serve a
DaemonSet workload behind a load-balanced Service, with cluster state
surviving a control-plane restart?**

## Milestone Split

Research into the codebase (rusternetes, machined-rs) showed the
netfilter/iptables enablement is a separable, higher-risk subsystem. M2c is
therefore split into two independently-testable plans:

- **M2c-0 — Services work on the microVM.** Get iptables userspace + the
  netfilter module closure into the guest image, enable the all-in-one's
  embedded kube-proxy + DNS on node-1, add a standalone kube-proxy host
  service on each worker, and prove a ClusterIP Service load-balances across
  nodes and DNS resolves — using the existing `whoami` workload. This retires
  the netfilter risk in isolation.
- **M2c-1 — PHP DaemonSet + durability.** Switch node-1's storage to
  rhino-SQLite on the persistent STATE partition, replace `whoami` with the
  placeholder PHP `DaemonSet` on the three workers, and add the full
  `m2c-smoke.sh` including the kill/relaunch durability test.

This document is the shared design for both. Each plan is written separately.

## Scope and Decisions

Locked during brainstorming:

- **Platform:** x86_64 Cloud-Hypervisor microVMs, extending the M2b harness on
  the dev box. The aarch64 / Raspberry Pi 3A+ port is deferred to a later
  milestone.
- **Storage backend:** rhino-SQLite — selected at runtime by the all-in-one's
  `--storage-backend sqlite` (already the default) with the DB path set by
  `--data-dir`. rhino hardcodes WAL journal mode + `synchronous = NORMAL`
  (`rhino/src/drivers/sqlite/mod.rs`); this is not configurable from
  rusternetes. NORMAL is safe against a clean process kill (the M2c-1
  durability test); true power-loss safety (`synchronous = FULL`) would require
  a rhino change and is out of scope. Kine-on-SQLite remains the conservative
  fallback if the durability test fails; not wired in M2c.
- **Workload:** a placeholder PHP image (prints its hostname / pod IP), run as
  a DaemonSet on the three worker nodes, fronted by a ClusterIP Service.
  Verification is in-cluster: DNS resolves the Service name and repeated
  requests to the ClusterIP load-balance across all three pods. Not the user's
  real website, and no external (NodePort/Ingress) exposure — both deferred.
- **Control-plane composition:** all-in-one — a single `rusternetes` binary on
  node-1 that already embeds api-server + scheduler + controller-manager +
  kubelet + kube-proxy + DNS. M2b disabled the last two via
  `--disable-proxy --disable-dns`; M2c drops those flags to enable them.
- **kube-proxy:** the `rusternetes-kube-proxy` iptables(-nft) backend, run as a
  **host process**, not a DaemonSet — embedded in the all-in-one on node-1, and
  as a standalone machined **service** on each worker (API mode, mirroring how
  the standalone kubelet already runs). No kube-proxy image or DaemonSet
  manifest.

## Architecture

Same four-node layout as M2b (`10.88.0.2`–`10.88.0.5` on bridge `mkn-br0`,
host-gw flannel, per-node podCIDRs `10.244.0/1/2/3.0/24`), extended:

- **node-1 — control-plane, tainted `NoSchedule`:** `rusternetes` all-in-one
  with embedded kube-proxy + DNS enabled and `--cluster-cidr 10.244.0.0/16`,
  storage `--storage-backend sqlite --data-dir /system/state/rusternetes/state.db`
  on the persistent **STATE** partition (see Persistence), plus
  containerd-rs / crun / flannel.
- **node-2 / node-3 / node-4 — workers:** standalone kubelet + a standalone
  `kube-proxy` machined service (API mode) + containerd-rs / crun / flannel +
  **one PHP pod each** (M2c-1).
- **Workload (M2c-1):** a placeholder PHP `DaemonSet` (nodeSelector / no CP
  toleration so it lands only on the three workers) + a ClusterIP `Service`
  selecting it; a DNS `A` record resolves the service name to the ClusterIP.
- **CNI:** unchanged from M2b — flannel host-gw, per-node podCIDRs.

## Persistence

machined does **not** mount the second disk (`state.img` / `vdb`) the harness
attaches — there is no data-disk mount mechanism today, and using `vdb` would
require new machined code (out of scope). Persistence instead uses the install
disk's **STATE** partition (`/system/state`, ext4, ~1 GiB), which machined
already provisions and mounts and which already persists PKI across reboots.
The rhino-SQLite DB lives at `/system/state/rusternetes/state.db`. It survives
the M2c-1 kill/relaunch durability test (the provisioner leaves an
already-laid-out disk untouched); it is only wiped by an explicit
`machinectl reset`.

## Components

New or changed relative to M2b:

1. **iptables userspace in the guest rootfs.** kube-proxy shells out to
   `/usr/sbin/iptables-nft` and `iptables-restore` (auto-detecting the backend).
   The minimal Alpine rootfs the imager builds has no iptables. Add pinned
   Alpine `apk` artifacts — `iptables` plus its NEEDED-lib closure (`libnftnl`,
   `libmnl`) — to `machined-rs/crates/imager/artifacts.toml`, following the
   existing e2fsprogs closure pattern. They extract into the initramfs rootfs
   at `/usr/sbin/`.
2. **Netfilter module closure.** `bridge`, `br_netfilter`, `nf_tables`,
   `nf_nat`, `nf_conntrack` are already in `VIRT_MODULES`
   (`machined-rs/crates/imager/src/modules.rs`). Add the iptables-nft
   translation + match/target modules kube-proxy needs (`nft_compat`,
   `nft_chain_nat`, and the `xt_*` modules its rules use — e.g. `xt_comment`,
   `xt_mark`, `xt_conntrack`, `xt_statistic`). The imager resolves
   dependencies transitively from the kernel package's `modules.dep` and fails
   the build loudly if a named module is absent, so the exact set is confirmed
   by building. machined `finit_module`s them in dependency order at boot (no
   runtime modprobe / autoload).
3. **rusternetes all-in-one config change (node-1).** Drop
   `--disable-proxy` and `--disable-dns`; add `--cluster-cidr 10.244.0.0/16`;
   set `--data-dir /system/state/rusternetes/state.db`. DNS binds `0.0.0.0:53`
   and is reached by pods via the `--cluster-dns 10.96.0.10` ClusterIP, which
   the embedded kube-proxy DNATs.
4. **Standalone kube-proxy on workers.** Build a musl-static `kube-proxy`
   binary (`cargo build --profile release-fast --features sqlite -p
   rusternetes-kube-proxy`, or without `sqlite` in API mode; `mimalloc`
   recommended for musl), stage it into the worker overlay at `/boot/bin/kube-proxy`,
   and add a `ServiceConfig` to each worker's generated `config.yaml`:
   `command = ["/boot/bin/kube-proxy", "--node-name", "node-N", "--kubeconfig",
   "/boot/kubelet.kubeconfig", "--api-server-url", "https://10.88.0.2:6443",
   "--insecure-skip-tls-verify", "true", "--cluster-cidr", "10.244.0.0/16"]`.
5. **Controllers** (already in `controller-manager`, active in all-in-one):
   `daemonset`, `service`, `endpoints` / `endpointslice`. Confirmed:
   a Service with a pod selector produces an EndpointSlice populated with
   matching pod IPs; DNS serves `A` for `<svc>.<ns>.svc.cluster.local`.
6. **Workload manifests (M2c-1):** the placeholder PHP `DaemonSet` and its
   ClusterIP `Service`. The PHP image is mirrored into the local registry.
7. **Scripts:** `scripts/m2c-bootstrap.sh` (extends m2b — taint node-1, apply
   the Service and, in M2c-1, the PHP DaemonSet) and `scripts/m2c-smoke.sh`.

## Data Flow

```
boot       node-1 rusternetes -> open rhino-SQLite on /system/state -> serve API + DNS(0.0.0.0:53)
           embedded kube-proxy programs iptables (incl. 10.96.0.10 -> DNS)
           workers' kubelets + kube-proxy services register / program local iptables
bootstrap  patch per-node podCIDRs (m2b) -> flannel host-gw DS ->
           taint node-1 NoSchedule -> apply DaemonSet + ClusterIP Service
schedule   daemonset ctrl -> 1 pod per worker (node-1 excluded by taint)
           kubelet pulls image (local registry) -> flannel assigns per-node pod IP
endpoints  service + endpointslice ctrl -> EndpointSlice = {pod IPs}
proxy      kube-proxy on each node watches Service + EndpointSlice ->
           iptables DNAT: ClusterIP:80 -> {podIPs}, load-balanced
serve      client pod: nslookup <svc> -> ClusterIP;  wget ClusterIP:80 xN -> all pods hit
durable    kill + relaunch node-1 -> CP reopens SQLite DB -> API state intact, pods still Running
```

The load-bearing new links are **EndpointSlice → kube-proxy → iptables DNAT**
(the Service load-balancer) and **rusternetes → rhino-SQLite on the STATE
partition** (state durability).

## Image Distribution

The runtime image store is containerd-rs's own content store, filled by
**pulling from a registry** over HTTP via `/boot/certs.d/<host>/hosts.toml`
(containerd's registry-mirror format). Docker is **not** the image backend and
does not run in the guest.

For M2c the registry is the standard OCI **Distribution** registry
(`registry:2`) run as a Docker container on the dev box — harness plumbing
only, as in M2b. The node runtime is unchanged by this choice.

k0s/k3s parity note: neither ships a registry; they pull from the image's own
registry, import airgap tarballs into containerd, or point the runtime at a
registry the operator provides. The eventual Pi path will either self-host a
small registry on the LAN (e.g. Zot or Distribution) or require a new
containerd-rs airgap-import capability (containerd-rs is currently pull-only).
See Follow-ups.

## Error Handling

Each failure mode maps to a gate assertion so failures are loud, not silent:

| Failure | Symptom | Caught by |
|---|---|---|
| netfilter modules missing / image build | build aborts (`module <name> not found in modules.dep`) | image build fails |
| iptables userspace missing | kube-proxy can't exec `/usr/sbin/iptables-nft` | kube-proxy logs error; no `KUBE-`/`RUSTERNETES-` chains |
| netfilter modules not loaded at boot | iptables-restore fails | Service load-balancing check fails |
| rhino-SQLite open or corrupt | control plane fails fast at boot | node-1 never Ready |
| clean-kill mid-write | last txns lost, DB intact (WAL) | durability phase asserts prior committed state present |
| node-1 taint missing | a 4th PHP pod lands on the CP | pod count != 3 |
| Service has 0 endpoints | endpointslice controller not populating | load-balancing check fails |
| registry unreachable | pod `ImagePullBackOff` | pod-Running wait fails |
| DNS not serving | pods cannot resolve the service | nslookup check fails |

## Smoke Gate

`scripts/m2c-smoke.sh` extends the six M2b steps.

M2c-0 assertions:

1. **kube-proxy up** — node-1 all-in-one started with proxy+DNS enabled; each
   worker's `kube-proxy` service is running (serial log / process present).
2. **Service + endpoints** — the ClusterIP Service has an EndpointSlice with
   the expected number of endpoints.
3. **DNS** — from a client pod, `nslookup <svc>.<ns>.svc.cluster.local`
   returns the ClusterIP.
4. **Service load-balancing** — from a client pod, `wget http://<ClusterIP>:80`
   repeated N times returns **all distinct backend pod identities** (proves
   kube-proxy DNAT + cross-node spread).

M2c-1 adds:

5. **CP composition** — storage backend is SQLite (assert
   `/system/state/rusternetes/state.db` exists and is non-empty on node-1).
6. **PHP DaemonSet** — exactly **three** pods, one per worker, **none on
   node-1** (taint honored), all Running; per-node pod IPs within each node's
   podCIDR and globally distinct (reusing M2b's step 3b assertion).
7. **Durability (the rhino proof)** — snapshot API state (nodes, PHP pods,
   Service, EndpointSlice); kill and relaunch node-1; wait for the API to
   return; assert the **same resources are present** (control plane recovered
   from rhino-SQLite), PHP pods still Running, and load-balancing still works.
   Runs last, as its own phase.

Memory reporting extends the M2b per-node / per-application table: add
`kube-proxy` and the PHP process (`php-fpm` / `apache2`) to the memprobe's
tracked process names, and report **node-1's full control-plane total vs the
512 MiB cap** at boot-peak and idle. The OOM / kernel-panic serial scan is
unchanged.

## Success Criteria

M2c-0 passes when a ClusterIP Service load-balances real cross-node traffic
across its backend pods and DNS resolves the Service name from inside a pod,
with kube-proxy programming iptables on every node.

M2c-1 passes when, additionally: node-1 runs the full control plane on
rhino-SQLite inside 512 MiB with no OOM; the PHP DaemonSet runs exactly three
pods (one per worker, none on node-1); cluster state survives a node-1
restart; and per-node / per-application memory is reported at boot-peak and
idle.

## Out of Scope / Follow-ups

- **aarch64 / Raspberry Pi 3A+ port** — arm64 builds (the aarch64 artifact set
  already exists in `artifacts.toml`), USB-Ethernet image, real hardware.
- **External exposure** — NodePort / Ingress / LoadBalancer.
- **The real PHP website** — actual app image, assets, secrets, datastore.
- **`synchronous = FULL`** — true power-loss durability; needs a rhino change to
  thread the pragma through `SqliteConfig`.
- **Mounting the `state.img` second disk** — needs new machined code (disk
  selection + label→mountpoint mapping); M2c uses the STATE partition instead.
- **Kine fallback** — wire Kine-on-SQLite only if the rhino durability test
  fails.
- **containerd-rs airgap import** — tarball / OCI-layout import so a fixed
  workload runs with no registry (containerd-rs is currently pull-only).
- **Self-hosted LAN registry for Pi** — Zot or Distribution on the LAN.
- **High availability** — single control-plane node, single copy of state; no
  multi-CP / raft. Restore-from-backup as DR.

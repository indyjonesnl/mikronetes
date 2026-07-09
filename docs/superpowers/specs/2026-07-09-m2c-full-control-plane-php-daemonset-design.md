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

## Scope and Decisions

Locked during brainstorming:

- **Platform:** x86_64 Cloud-Hypervisor microVMs, extending the M2b harness on
  the dev box. Fast to iterate, CI-friendly. The aarch64 / Raspberry Pi 3A+
  port is explicitly deferred to a later milestone.
- **Storage backend:** rhino-SQLite — the storage crate's native
  `sqlite = ["dep:rhino"]` path. Dogfoods the all-Rust stack, lightest
  footprint, no Go process. Because rhino is unproven end-to-end, M2c includes
  a durability test. Kine-on-SQLite remains the conservative fallback if the
  durability test fails, but is not wired in M2c.
- **Workload:** a placeholder PHP image (prints its hostname / pod IP), run as
  a DaemonSet on the three worker nodes, fronted by a ClusterIP Service.
  Verification is in-cluster: DNS resolves the Service name and repeated
  requests to the ClusterIP load-balance across all three pods. Not the user's
  real website, and no external (NodePort/Ingress) exposure — both deferred.
- **Control-plane composition:** all-in-one — a single `rusternetes` binary on
  node-1 embedding api-server + scheduler + controller-manager + DNS, as in
  M2b, now with the `sqlite` storage feature enabled and the
  DaemonSet/Service/endpoints controllers active. A split-services layout costs
  more processes and RAM on a 512 MiB node with no benefit here.
- **kube-proxy:** the `kube-proxy` crate's iptables(-nft) backend, run as a
  DaemonSet on all four nodes.

## Architecture

Same four-node layout as M2b (`10.88.0.2`–`10.88.0.5` on bridge `mkn-br0`,
host-gw flannel, per-node podCIDRs `10.244.0/1/2/3.0/24`), extended:

- **node-1 — control-plane, tainted `NoSchedule`:** `rusternetes` all-in-one
  with `sqlite`(rhino) storage, embedded DNS at `10.96.0.10`, plus
  containerd-rs / crun / flannel. The rhino-SQLite database lives on the
  per-node **persistent** `state.img` (e.g. `/var/lib/rusternetes/state.db`),
  not the ephemeral rootfs, so it survives a node-1 reboot. A kube-proxy
  DaemonSet pod also runs here (it tolerates the taint).
- **node-2 / node-3 / node-4 — workers:** standalone kubelet + containerd-rs /
  crun / flannel + a kube-proxy DaemonSet pod + **one PHP pod each**.
- **Workload:** a placeholder PHP `DaemonSet` (nodeSelector / no CP toleration
  so it lands only on the three workers) + a ClusterIP `Service` selecting it;
  a DNS `A` record resolves the service name to the ClusterIP.
- **CNI:** unchanged from M2b — flannel host-gw, per-node podCIDRs.

## Components

New or changed relative to M2b:

1. **rusternetes all-in-one, storage = `sqlite`(rhino).** The all-in-one image
   is built with the `sqlite` feature
   (`api-server/sqlite → rusternetes-storage/sqlite → rhino`). The DB path is a
   persistent location on `state.img`. `config.yaml` gains a storage-backend
   stanza pointing at that path. SQLite runs in **WAL** mode with
   `synchronous = FULL` so a hard kill cannot tear a committed write.
2. **Embedded DNS**, served at `10.96.0.10:53` (kubelet already advertises this
   resolver to pods, confirmed in M2b logs). Answers `A` for
   `<svc>.<ns>.svc.cluster.local`.
3. **kube-proxy DaemonSet.** A new musl-static image built from the `kube-proxy`
   crate, mirrored into the local registry like flannel. Runs `hostNetwork`,
   privileged, tolerating all taints so it is present on all four nodes.
   iptables(-nft) backend.
4. **Netfilter module set**, packaged into the image and added to
   `modules.load`: `nf_tables`, `nf_nat`, `nf_conntrack`, `nft_compat` /
   `x_tables`, `nft_chain_nat`. The guest kernel (Alpine linux-virt 6.12.93)
   already ships these as modules (`nf_* = m`); M2b's
   `iptables (nf_tables): Could not fetch rule set generation id` failure was
   modules-not-loaded, not an unsupported kernel. This is a bounded
   module-wiring task, not a kernel rebuild.
5. **Controllers** (already in `controller-manager`, activated in all-in-one):
   `daemonset`, `service`, `endpoints` / `endpointslice`.
6. **Workload manifests:** the placeholder PHP `DaemonSet` and its ClusterIP
   `Service`. The PHP image is mirrored into the local registry.
7. **Scripts:** `scripts/m2c-bootstrap.sh` (extends m2b — taint node-1, apply
   the kube-proxy DaemonSet, the PHP DaemonSet, and the Service) and
   `scripts/m2c-smoke.sh`.

## Data Flow

```
boot       node-1 rusternetes -> open rhino-SQLite on state.img -> serve API + DNS(10.96.0.10)
           workers' kubelets register
bootstrap  patch per-node podCIDRs (m2b) -> flannel host-gw DS -> kube-proxy DS ->
           taint node-1 NoSchedule -> apply PHP DaemonSet + ClusterIP Service
schedule   daemonset ctrl -> 1 PHP pod per worker (node-1 excluded by taint)
           kubelet pulls PHP image (local registry) -> flannel assigns per-node pod IP
endpoints  service + endpointslice ctrl -> EndpointSlice = {3 PHP pod IPs}
proxy      kube-proxy on each node watches Service + EndpointSlice ->
           iptables DNAT: ClusterIP:80 -> {podIP1,2,3}, load-balanced
serve      client pod: nslookup <svc> -> ClusterIP;  wget ClusterIP:80 xN -> all 3 pods hit
durable    kill + relaunch node-1 -> CP reopens SQLite DB -> API state intact, pods still Running
```

The load-bearing new links are **EndpointSlice → kube-proxy → iptables DNAT**
(the Service load-balancer) and **rusternetes → rhino-SQLite on persistent
disk** (state durability).

## Image Distribution

The runtime image store is containerd-rs's own content store, filled by
**pulling from a registry** over HTTP via `/boot/certs.d/<host>/hosts.toml`
(containerd's registry-mirror format). Docker is **not** the image backend and
does not run in the guest.

For M2c the registry is the standard OCI **Distribution** registry
(`registry:2`) run as a Docker container on the dev box — harness plumbing
only, exactly as in M2b. The node runtime is unchanged by this choice.

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
| netfilter modules not loaded | kube-proxy iptables backend won't init | kube-proxy pod not Ready / no `KUBE-SVC` chains |
| rhino-SQLite open or corrupt | control plane fails fast at boot | node-1 never Ready |
| power-loss mid-write | inconsistent DB | durability phase |
| node-1 taint missing | a 4th PHP pod lands on the CP | PHP pod count != 3 |
| Service has 0 endpoints | endpointslice controller not populating | load-balancing check fails |
| registry unreachable | PHP pod `ImagePullBackOff` | pod-Running wait fails |
| DNS not serving | pods cannot resolve the service | nslookup check fails |

## Smoke Gate

`scripts/m2c-smoke.sh` extends the six M2b steps with:

1. **Control-plane composition** — API reachable; the storage backend is SQLite
   (assert `state.db` exists and is non-empty on node-1's persistent disk); DNS
   serving on `10.96.0.10`.
2. **kube-proxy** — DaemonSet Ready on all four nodes; the Service has an
   EndpointSlice with exactly three endpoints.
3. **PHP DaemonSet** — exactly **three** pods, one per worker, **none on
   node-1** (taint honored), all Running; per-node pod IPs within each node's
   podCIDR and globally distinct (reusing M2b's step 3b assertion).
4. **DNS** — from a client pod, `nslookup <svc>.<ns>.svc.cluster.local`
   returns the ClusterIP.
5. **Service load-balancing** — from a client pod, `wget http://<ClusterIP>:80`
   repeated N times returns **all three distinct PHP pod identities** (proves
   kube-proxy DNAT and cross-node spread).
6. **Durability (the rhino proof)** — snapshot API state (nodes, PHP pods,
   Service, EndpointSlice); kill and relaunch node-1; wait for the API to
   return; assert the **same resources are present** (control plane recovered
   from rhino-SQLite), PHP pods still Running, and load-balancing still works.
   This phase is destructive and slow, so it runs last, as its own phase; the
   rest of the gate stays fast.

Memory reporting extends the M2b per-node / per-application table: add
`kube-proxy` and the PHP process (`php-fpm` / `apache2`) to the memprobe's
tracked process names, and report **node-1's full control-plane total vs the
512 MiB cap** at boot-peak and idle. The OOM / kernel-panic serial scan is
unchanged.

## Success Criteria

M2c passes when:

- node-1 runs the full control plane (api-server + scheduler +
  controller-manager + DNS + rhino-SQLite storage) inside 512 MiB with no OOM.
- The PHP DaemonSet runs exactly three pods, one per worker, none on node-1.
- One ClusterIP Service load-balances real cross-node traffic across all three
  PHP pods.
- DNS resolves the Service name to its ClusterIP from inside a pod.
- Cluster state survives a node-1 restart (rhino-SQLite durability).
- Per-node / per-application memory is reported at boot-peak and idle.

## Out of Scope / Follow-ups

- **aarch64 / Raspberry Pi 3A+ port** — arm64 builds, USB-Ethernet image, real
  hardware. A later milestone; M2c is the x86_64 proving ground.
- **External exposure** — NodePort / Ingress / LoadBalancer for reaching the
  site from outside the cluster.
- **The real PHP website** — actual app image, assets, secrets, and any backing
  datastore.
- **Kine fallback** — wire Kine-on-SQLite only if the rhino durability test
  fails.
- **containerd-rs airgap import** — a tarball / OCI-layout import path so a
  fixed workload can run with no registry at all (containerd-rs is currently
  pull-only). Needed for the Pi airgap story; a containerd-rs work item.
- **Self-hosted LAN registry for Pi** — Zot or Distribution on the LAN, with
  each node's `hosts.toml` pointed at it (replaces the dev-box Docker registry).
- **High availability** — single control-plane node, single copy of state on
  microSD; no multi-CP / raft. Accept restore-from-backup as DR.

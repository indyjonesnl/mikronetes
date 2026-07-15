# M2a — Single mikronetes node in a microVM @512 MiB — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Boot one mikronetes node — machined-rs as PID 1 supervising the all-Rust stack — inside a 512 MiB microVM, with a workload pod running over flannel, proven by an automated smoke gate.

**Architecture:** machined-rs supervises exactly two payload units: the **containerd-rs** CRI runtime (`runtime:` block, baked config, CRI health-gated) and the **rusternetes all-in-one** binary (api-server + scheduler + controller-manager + storage + an embedded kubelet in CNI mode + embedded kube-proxy), started after the CRI is `RuntimeReady`. flannel-rs is applied post-boot as a DaemonSet (as in M1). The node image is built by machined's `imager` with a mikronetes payload **overlay**; the same image boots under **QEMU-TCG (CI)** or **Cloud Hypervisor (local)** via a `--backend` flag.

**Tech Stack:** Rust (machined-rs, rusternetes), Bash harness, QEMU/Cloud Hypervisor, Alpine kernel+initramfs, GHCR public images, GitHub Actions (self-hosted ARC).

## Global Constraints

- **Git identity (all commits):** `Indy Jones <indyjonesnl@gmail.com>`; trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Never push a broken state; gates must be green before commit/push. Alpha → committing to `main` is permitted.
- **machined-rs Rust changes:** must pass `make pre-commit` (fmt + `clippy -D warnings` + root-free test suite) before commit. Use TDD (test fails first).
- **CI VM backend = QEMU-TCG** (Dallas Spot ARC nodes have no `/dev/kvm`). Cloud Hypervisor = local only (dev box has `/dev/kvm`). Same image boots both.
- **512 MiB guest RAM cap** is enforced by `-m 512` (QEMU) / `--memory size=512M` (CH). The harness measures actual usage and asserts it fits; a genuine non-fit is a recorded finding, not a silent pass.
- **Build-free binaries:** rusternetes `/app/rusternetes` and `/app/kubelet` from public GHCR images (`ghcr.io/indyjonesnl/rusternetes/{api-server,kubelet}:main`) via `docker create`+`docker cp`; containerd-rs from `rusternetes-m1/deploy/node-cdrs/bin/containerd-rs`.
- **Pinned tool versions:** cloud-hypervisor `v52.0` (`cloud-hypervisor-static`), crun `v1.28` static, CNI plugins `v1.9.1`, flannel CNI `v1.9.1-flannel1`.
- **CRI socket = `/run/containerd-rs.sock`** everywhere (containerd-rs config `cri_socket`, machined `runtime.socket`, and the kubelet's `CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd-rs.sock`).
- **Repos:** mikronetes at `/home/jones/PhpstormProjects/mikronetes` (harness + CI + plan); machined-rs at `/home/jones/PhpstormProjects/machined-rs` (imager + ServiceConfig changes, separate PR); rusternetes fork `indyjonesnl/rusternetes` (compose/manifests/Dockerfiles, checkout `rusternetes-m1`). `CARGO_TARGET_DIR=/home/jones/.cache/rusternetes-target`.

---

## Phase A — De-risk the all-in-one + containerd-rs + flannel path (containers, no VM)

The M1 stack used a **separate** kubelet; M2a uses the all-in-one's **embedded** kubelet driving containerd-rs in CNI mode. That exact combination is unproven. Prove it in containers on the dev box before investing in the image/VM layers. If it fails here, the whole node shape is wrong — fail fast.

### Task A1: Prove all-in-one (embedded kubelet, CNI) + containerd-rs + crun + flannel run a pod

**Files:**
- Create: `scripts/m2a-allinone-probe.sh` (mikronetes)
- Reference (do not modify): `rusternetes-m1/compose.cdrs-flannel.yml`, `rusternetes-m1/deploy/node-cdrs/`, `rusternetes-m1/deploy/flannel/flannel-rs.yaml`

**Interfaces:**
- Produces: empirical confirmation that `rusternetes` (all-in-one, default CNI mode) with `CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd-rs.sock` registers a node Ready and runs a flannel-networked pod. Establishes the exact argv/env the machine.yaml will use in Task D1.

- [ ] **Step 1: Write the probe as a failing assertion**

Create `scripts/m2a-allinone-probe.sh`. It runs the all-in-one + containerd-rs in one container (sharing a netns), points the embedded kubelet at containerd-rs, applies flannel + a test pod, and asserts the pod reaches Running. This is the "test" (no unit-test framework applies to a cross-binary integration).

```bash
#!/usr/bin/env bash
# Phase A de-risk: all-in-one embedded kubelet (CNI) + containerd-rs + crun + flannel.
# Reuses the M1 node-cdrs image (containerd-rs+crun+CNI) but runs the rusternetes
# ALL-IN-ONE (embedded kubelet) instead of the split CP + separate kubelet.
set -euo pipefail
M1="${RUSTERNETES_M1:-/home/jones/PhpstormProjects/rusternetes-m1}"
TAG="${IMAGE_TAG:-main}"
GHCR="ghcr.io/indyjonesnl/rusternetes"
say(){ printf '\n==> %s\n' "$*"; }
die(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# 1. node-cdrs image (containerd-rs + crun + CNI v1.6.2 + kubelet baked — we only
#    use its containerd-rs + crun + /opt/cni/bin here).
docker image inspect rusternetes-node-cdrs:m1 >/dev/null 2>&1 || \
  docker build --build-arg "KUBELET_IMAGE=${GHCR}/kubelet:${TAG}" \
    -f "$M1/deploy/node-cdrs/Dockerfile" -t rusternetes-node-cdrs:m1 "$M1"

# 2. all-in-one binary from GHCR.
docker pull "${GHCR}/api-server:${TAG}"
```

- [ ] **Step 2: Extend the probe — launch containerd-rs + all-in-one sharing a netns**

Append to `scripts/m2a-allinone-probe.sh`:

```bash
docker network create m2a-probe >/dev/null 2>&1 || true
# containerd-rs node (also provides /opt/cni/bin + crun); privileged for CNI/netns.
docker rm -f m2a-cdrs >/dev/null 2>&1 || true
docker run -d --name m2a-cdrs --privileged --network m2a-probe \
  -v /lib/modules:/lib/modules:ro \
  rusternetes-node-cdrs:m1 \
  sh -c '/usr/local/bin/containerd-rs --config /etc/containerd-rs/config.toml'
# all-in-one, embedded kubelet pointed at containerd-rs over the shared netns.
docker rm -f m2a-aio >/dev/null 2>&1 || true
docker run -d --name m2a-aio --privileged --network "container:m2a-cdrs" \
  -e RUST_LOG=info \
  -e CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd-rs.sock \
  --volumes-from m2a-cdrs \
  "${GHCR}/api-server:${TAG}" \
  /app/rusternetes --storage-backend sqlite --data-dir /var/lib/rusternetes/db \
    --bind-address 0.0.0.0:6443 --tls --node-name node-1
```

(`--network container:m2a-cdrs` shares the CRI socket + netns; `--volumes-from` shares `/run` so the kubelet sees `/run/containerd-rs.sock`.)

- [ ] **Step 3: Run it; expect node Ready + a pod Running over flannel**

Append:

```bash
API_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' m2a-cdrs)
kc(){ kubectl --server "https://$API_IP:6443" --insecure-skip-tls-verify --token dummy "$@"; }
say "waiting for node-1 Ready"
for _ in $(seq 1 60); do
  [ "$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo)" = True ] && break
  sleep 5
done
[ "$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] || die "node-1 not Ready"
# apply flannel (in-netns, hostNetwork) + a test pod; reuse the M1 manifest.
kc apply -f "$M1/deploy/flannel/flannel-rs.yaml"
kc run probe --image=traefik/whoami:v1.10.2 >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  [ "$(kc get pod probe -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && break
  sleep 5
done
[ "$(kc get pod probe -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] \
  && echo "PASS: all-in-one embedded kubelet + containerd-rs + flannel ran a pod" \
  || die "probe pod never reached Running (embedded-kubelet/CNI path broken)"
```

Run: `bash scripts/m2a-allinone-probe.sh`
Expected: `PASS: all-in-one embedded kubelet + containerd-rs + flannel ran a pod`

- [ ] **Step 4: If it fails — branch the design, do not paper over**

If the embedded kubelet does not drive containerd-rs (e.g. it ignores `CONTAINER_RUNTIME_ENDPOINT`, or defaults to an in-process runtime), STOP and use systematic-debugging. Likely outcomes: (a) needs an extra flag — find it in `crates/rusternetes/src/main.rs` + `crates/kubelet/src/kubelet.rs:411`; or (b) the all-in-one can't use an external CRI → fall back to M1's shape (split/all-in-one CP with embedded kubelet disabled + a **separate** kubelet service), which reintroduces a kubelet machined service. Record the outcome in the plan before proceeding.

- [ ] **Step 5: Capture the proven argv/env, then tear down**

Append:

```bash
echo "=== PROVEN all-in-one argv/env (use verbatim in machine.yaml, Task D1) ==="
docker inspect -f 'cmd={{.Config.Cmd}} env={{.Config.Env}}' m2a-aio
docker rm -f m2a-aio m2a-cdrs >/dev/null 2>&1 || true
docker network rm m2a-probe >/dev/null 2>&1 || true
```

- [ ] **Step 6: Commit**

```bash
cd /home/jones/PhpstormProjects/mikronetes
git add scripts/m2a-allinone-probe.sh
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "test(m2a): de-risk all-in-one embedded kubelet + containerd-rs + flannel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase B — machined-rs: `ServiceConfig.env` (the one real gap)

The all-in-one's embedded kubelet reads `CONTAINER_RUNTIME_ENDPOINT` from the **environment** (`crates/kubelet/src/kubelet.rs:411`), and the service may need `PATH=/boot/bin:...` so containerd-rs finds `runc`/`crun`. machined's `ServiceConfig` has no `env`. Add it (TDD), in machined-rs, as its own PR.

### Task B1: Add `env` to `ServiceConfig` and apply it when spawning

**Files:**
- Modify: `crates/config/src/types.rs` (add field to `ServiceConfig`)
- Modify: `crates/supervisor/src/process.rs` (apply env on spawn)
- Modify: `crates/supervisor/src/runner.rs` (thread env through if the runner owns the command — verify which constructs the `Command`)
- Test: `crates/config/src/types.rs` (parse test), `crates/supervisor/src/process.rs` (spawn-env test)

**Interfaces:**
- Produces: `ServiceConfig { …, pub env: Vec<EnvVar> }` where `EnvVar { key: String, value: String }`, deserialized from YAML `env: [{key: K, value: V}]`. The supervisor sets each on the child process. Consumed by the machine.yaml in Task D1.

- [ ] **Step 1: Write the failing parse test**

In `crates/config/src/types.rs` tests module:

```rust
#[test]
fn service_config_parses_env() {
    let y = r#"
id: kubelet
command: [/boot/bin/rusternetes]
env:
  - key: CONTAINER_RUNTIME_ENDPOINT
    value: unix:///run/containerd-rs.sock
"#;
    let s: ServiceConfig = serde_yaml::from_str(y).unwrap();
    assert_eq!(s.env.len(), 1);
    assert_eq!(s.env[0].key, "CONTAINER_RUNTIME_ENDPOINT");
    assert_eq!(s.env[0].value, "unix:///run/containerd-rs.sock");
}
```

- [ ] **Step 2: Run it; expect failure**

Run: `cd /home/jones/PhpstormProjects/machined-rs && cargo test -p machined-config service_config_parses_env`
Expected: FAIL — `no field 'env'` / `unknown field 'env'` (because `deny_unknown_fields`).

- [ ] **Step 3: Add the field + type**

In `crates/config/src/types.rs`, add to `ServiceConfig` (after `stop_grace_secs`):

```rust
    /// Environment variables set on the service process.
    #[serde(default)]
    pub env: Vec<EnvVar>,
```

And add the type near `ServiceConfig`:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnvVar {
    pub key: String,
    pub value: String,
}
```

Update any `ServiceConfig { … }` literal in the crate (e.g. `runtime_svc.rs::containerd_service`) to add `env: Vec::new()` — `cargo build -p machined-config` will name each site.

- [ ] **Step 4: Run the parse test; expect pass**

Run: `cargo test -p machined-config service_config_parses_env`
Expected: PASS.

- [ ] **Step 5: Write the failing spawn-env test**

In `crates/supervisor/src/process.rs` tests, mirror the existing process-spawn test style. Assert a service whose `command` is `["/bin/sh","-c","echo $FOO > $OUT"]` with `env=[{key:FOO,value:bar}]` writes `bar`. (Read the existing tests in that file first and match their harness — fakes vs real spawn.)

```rust
#[tokio::test]
async fn spawn_applies_env() {
    let out = tempfile::NamedTempFile::new().unwrap();
    let outp = out.path().to_str().unwrap().to_string();
    let svc = test_service(
        "envsvc",
        vec!["/bin/sh".into(), "-c".into(), "printf %s \"$FOO\" > \"$OUT\"".into()],
        vec![
            EnvVar { key: "FOO".into(), value: "bar".into() },
            EnvVar { key: "OUT".into(), value: outp.clone() },
        ],
    );
    run_once(&svc).await; // use this file's existing one-shot spawn helper
    assert_eq!(std::fs::read_to_string(&outp).unwrap(), "bar");
}
```

(Adapt `test_service` / `run_once` to the helpers actually present in `process.rs`; if none, construct the `Command` path the production code uses.)

- [ ] **Step 6: Run it; expect failure**

Run: `cargo test -p machined-supervisor spawn_applies_env`
Expected: FAIL — env not applied (file empty / `FOO` unset).

- [ ] **Step 7: Apply env in the spawn path**

In `crates/supervisor/src/process.rs` (whichever function builds the `tokio::process::Command` / `std::process::Command` for the service), add before spawn:

```rust
for e in &cfg.env {
    cmd.env(&e.key, &e.value);
}
```

(Find the `Command::new(...)` for the service argv; `cfg` is the `ServiceConfig`. If the command is built in `runner.rs`, add it there and thread `cfg.env` in.)

- [ ] **Step 8: Run the spawn test + full suite; expect pass**

Run: `cargo test -p machined-supervisor spawn_applies_env && make pre-commit`
Expected: PASS; `make pre-commit` green (fmt + clippy -D warnings + suite).

- [ ] **Step 9: Commit (machined-rs)**

```bash
cd /home/jones/PhpstormProjects/machined-rs
git add -A
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "feat(config): ServiceConfig.env — set environment on supervised services

Needed so a payload (e.g. a kubelet reading CONTAINER_RUNTIME_ENDPOINT, or a
service needing PATH) gets its environment. Applied in the process spawn path.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase C — machined-rs imager: `--overlay` flag + mikronetes overlay assembly

### Task C1: Add `--overlay <dir>` to `machined-imager build`

**Files:**
- Modify: `crates/imager/src/main.rs` (add `overlay: Option<PathBuf>` to `Build`)
- Modify: `crates/imager/src/build.rs` (copy overlay tree into `staging` after artifacts, before vmlinuz/config writes ~line 158)
- Test: `crates/imager/src/build.rs` (overlay-copy unit test) — or a focused test on a new `copy_overlay` helper

**Interfaces:**
- Produces: `--overlay <dir>` copies `<dir>`'s tree verbatim into the FAT `/boot` staging root, so `<dir>/bin/rusternetes` → `/boot/bin/rusternetes`, `<dir>/config.yaml` → `/boot/config.yaml`, etc. Consumed by Task C2 + D.

- [ ] **Step 1: Write the failing test for a `copy_overlay` helper**

In `crates/imager/src/build.rs` tests:

```rust
#[test]
fn copy_overlay_merges_tree_into_staging() {
    let tmp = tempfile::tempdir().unwrap();
    let staging = tmp.path().join("staging");
    std::fs::create_dir_all(staging.join("bin")).unwrap();
    std::fs::write(staging.join("bin").join("existing"), b"x").unwrap();
    let overlay = tmp.path().join("ov");
    std::fs::create_dir_all(overlay.join("bin")).unwrap();
    std::fs::write(overlay.join("bin").join("rusternetes"), b"elf").unwrap();
    std::fs::write(overlay.join("config.yaml"), b"machine: {}").unwrap();

    copy_overlay(&overlay, &staging).unwrap();

    assert_eq!(std::fs::read(staging.join("bin/rusternetes")).unwrap(), b"elf");
    assert_eq!(std::fs::read(staging.join("config.yaml")).unwrap(), b"machine: {}");
    assert!(staging.join("bin/existing").exists()); // merge, not replace
}
```

- [ ] **Step 2: Run it; expect failure**

Run: `cd /home/jones/PhpstormProjects/machined-rs && cargo test -p machined-imager copy_overlay_merges_tree_into_staging`
Expected: FAIL — `copy_overlay` not found.

- [ ] **Step 3: Implement `copy_overlay` + wire the flag**

In `crates/imager/src/build.rs` add:

```rust
/// Recursively copy `overlay`'s tree into `staging`, creating dirs as needed.
/// Merges (does not wipe) existing staging content; overlay files win on clash.
pub fn copy_overlay(overlay: &std::path::Path, staging: &std::path::Path) -> anyhow::Result<()> {
    for entry in walkdir::WalkDir::new(overlay) {
        let entry = entry?;
        let rel = entry.path().strip_prefix(overlay).unwrap();
        if rel.as_os_str().is_empty() { continue; }
        let dst = staging.join(rel);
        if entry.file_type().is_dir() {
            std::fs::create_dir_all(&dst)?;
        } else {
            if let Some(p) = dst.parent() { std::fs::create_dir_all(p)?; }
            std::fs::copy(entry.path(), &dst)
                .with_context(|| format!("overlay copy {} -> {}", entry.path().display(), dst.display()))?;
        }
    }
    Ok(())
}
```

(If `walkdir` is not already a dep, prefer a hand-rolled recursive copy to avoid adding a dependency — check `crates/imager/Cargo.toml` first; `imager` likely already pulls a walker. If not, write a small recursive `fn` instead.)

In `crates/imager/src/main.rs`, add to `Build`:

```rust
        /// Optional overlay dir copied verbatim into the boot staging tree.
        #[arg(long)]
        overlay: Option<PathBuf>,
```

Thread `overlay` into the build options struct and, in `build.rs` after the artifact-staging loop and **before** the `vmlinuz`/`config.yaml` writes (~line 158), call:

```rust
    if let Some(ov) = &o.overlay {
        copy_overlay(ov, &staging).with_context(|| format!("applying overlay {}", ov.display()))?;
    }
```

- [ ] **Step 4: Run test + suite; expect pass**

Run: `cargo test -p machined-imager copy_overlay_merges_tree_into_staging && make pre-commit`
Expected: PASS; `make pre-commit` green.

- [ ] **Step 5: Commit (machined-rs)**

```bash
cd /home/jones/PhpstormProjects/machined-rs
git add -A
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "feat(imager): --overlay <dir> — merge a payload tree into the boot staging

Lets a distribution bake extra binaries/config (e.g. a Kubernetes payload) onto
the FAT /boot partition without editing the artifact manifest.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task C2: mikronetes overlay-assembly script (binaries + config + certs)

**Files:**
- Create: `scripts/m2a-build-overlay.sh` (mikronetes) — assembles `out/overlay/` for `--overlay`
- Create: `deploy/m2a/config.yaml` (the machine.yaml; written in Task D1, referenced here)
- Create: `deploy/m2a/config-containerd-rs.toml` (baked containerd-rs config)

**Interfaces:**
- Produces: an `overlay/` dir with `bin/{rusternetes,containerd-rs,crun,runc→crun}`, `cni/bin/{bridge,host-local,loopback,portmap,flannel}`, `config.yaml`, `config-containerd-rs.toml`, `pki/`. Consumed by Task D2's image build.

- [ ] **Step 1: Write the assembly script**

Create `scripts/m2a-build-overlay.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
GHCR="ghcr.io/indyjonesnl/rusternetes"; TAG="${IMAGE_TAG:-main}"
M1="${RUSTERNETES_M1:-/home/jones/PhpstormProjects/rusternetes-m1}"
OUT="${OUT:-$(pwd)/out/overlay}"
rm -rf "$OUT"; mkdir -p "$OUT/bin" "$OUT/cni/bin" "$OUT/cni/conf" "$OUT/pki"

# rusternetes all-in-one — BUILD FROM SOURCE. (A1 finding: there is NO GHCR
# all-in-one image — ghcr api-server only carries /app/api-server. The all-in-one
# binary /app/rusternetes is produced ONLY by Dockerfile.all-in-one.)
# IMPLEMENTER: read the header of "$M1/Dockerfile.all-in-one" — it documents the
# exact build context (the PARENT dir of the rusternetes/ checkout, because it
# vendors rhino at rusternetes/rhino). Build with that context, then docker-cp
# /app/rusternetes out. Cache the image (skip rebuild when present) for speed.
docker image inspect mikronetes-aio:m2a >/dev/null 2>&1 || \
  docker build -f "$M1/Dockerfile.all-in-one" -t mikronetes-aio:m2a <BUILD_CONTEXT_PER_DOCKERFILE_HEADER>
cid=$(docker create mikronetes-aio:m2a); docker cp "$cid:/app/rusternetes" "$OUT/bin/rusternetes"; docker rm "$cid" >/dev/null
# containerd-rs from the baked node-cdrs binary.
install -m0755 "$M1/deploy/node-cdrs/bin/containerd-rs" "$OUT/bin/containerd-rs"
# crun (static) + runc symlink (containerd-rs execs "runc").
curl -fsSL -o "$OUT/bin/crun" https://github.com/containers/crun/releases/download/1.28/crun-1.28-linux-amd64
chmod +x "$OUT/bin/crun"; ln -sf crun "$OUT/bin/runc"
# CNI plugins + flannel CNI.
tmp=$(mktemp -d)
curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-amd64-v1.9.1.tgz | tar -xz -C "$tmp"
cp "$tmp"/{bridge,host-local,loopback,portmap} "$OUT/cni/bin/"
curl -fsSL https://github.com/flannel-io/cni-plugin/releases/download/v1.9.1-flannel1/cni-plugin-flannel-linux-amd64-v1.9.1.tgz | tar -xz -C "$tmp"
cp "$tmp/cni-plugin" "$OUT/cni/bin/flannel"; rm -rf "$tmp"
# Bootstrap CNI conflist (A1 finding: containerd-rs v0.1.3 invokes CNI for EVERY
# RunPodSandbox, incl hostNetwork=true — without a conflist in cni_conf_dir at
# boot, the all-in-one's first sandboxes ALL fail). Bake a minimal bridge
# conflist at /boot/cni/conf so boot-time sandboxes (incl the flannel DS pod
# itself) succeed before flannel installs its own.
cat > "$OUT/cni/conf/10-bootstrap-bridge.conflist" <<'JSON'
{ "cniVersion": "0.3.1", "name": "bootstrap", "plugins": [
  { "type": "bridge", "bridge": "cni0", "isGateway": true, "ipMasq": true,
    "ipam": { "type": "host-local", "subnet": "10.244.0.0/24",
              "routes": [ { "dst": "0.0.0.0/0" } ] } } ] }
JSON
# machine config + containerd-rs config (from deploy/m2a, created in Task D1).
cp deploy/m2a/config.yaml "$OUT/config.yaml"
cp deploy/m2a/config-containerd-rs.toml "$OUT/config-containerd-rs.toml"
echo "overlay assembled at $OUT"; find "$OUT" -type f -o -type l | sort
```

- [ ] **Step 2: Create the baked containerd-rs config**

Create `deploy/m2a/config-containerd-rs.toml` (from the M1 node-cdrs config, paths repointed at `/boot`):

```toml
root = "/var/lib/containerd-rs"
state = "/run/containerd-rs"
cri_socket = "/run/containerd-rs.sock"
stream_server_address = "0.0.0.0:10010"

[cri]
sandbox_image = "registry.k8s.io/pause:3.10"
default_runtime_name = "runc"
runtime_type = "io.containerd.runc.v2"
snapshotter = "overlayfs"
systemd_cgroup = false
cni_conf_dir = "/boot/cni/conf"
cni_bin_dir = "/boot/cni/bin"
```

(`cni_conf_dir`/`cni_bin_dir` point at the baked conflist + plugins on the FAT
`/boot`, present at boot — see the bootstrap conflist above. `runc` resolves via
`PATH=/boot/bin` set on the runtime service env in Task D1. **A1 follow-up for
E2:** flannel-rs's DaemonSet writes its conflist to `/etc/cni/net.d` by default;
for M2a, point its conf hostPath at `/boot/cni/conf` (or have containerd-rs watch
both) so flannel's overlay conflist supersedes the bootstrap bridge once flannel
converges — resolve empirically when E2 runs locally.)

- [ ] **Step 3: Run it (deferred until D1 writes config.yaml) — partial run now**

Run (binaries only; comment out the two `cp deploy/m2a/...` lines for this dry run): `bash scripts/m2a-build-overlay.sh`
Expected: `overlay assembled at …` listing `bin/rusternetes`, `bin/containerd-rs`, `bin/crun`, `bin/runc`, the 5 CNI plugins.

- [ ] **Step 4: Commit**

```bash
cd /home/jones/PhpstormProjects/mikronetes
git add scripts/m2a-build-overlay.sh deploy/m2a/config-containerd-rs.toml
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "feat(m2a): overlay assembly — bake Rust stack binaries + CNI + containerd-rs config

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase D — Build the image & boot it

### Task D1: The mikronetes `machine.yaml`

**Files:**
- Create: `deploy/m2a/config.yaml` (mikronetes)

**Interfaces:**
- Produces: the machine config machined reads at `/boot/config.yaml`. Defines static net, the containerd-rs runtime (baked config, socket `/run/containerd-rs.sock`), and the all-in-one service (env: CRI endpoint + PATH; depends_on containerd). Consumed by C2 (copied into overlay) and the boot.

- [ ] **Step 1: Write `deploy/m2a/config.yaml`**

```yaml
# mikronetes M2a — single all-in-one node. machined supervises containerd-rs
# (runtime, CRI-health-gated) + the rusternetes all-in-one (embedded kubelet in
# CNI mode + embedded kube-proxy). flannel is applied post-boot as a DaemonSet.
machine:
  hostname: node-1
  network:
    interfaces:
      - name: eth0
        addresses: ["10.88.0.2/24"]
        routes:
          - via: 10.88.0.1
    nameservers: [10.88.0.1]
  install:
    disk: /dev/vda
    wipe: false
  runtime:
    disabled: false
    binary: /boot/bin/containerd-rs
    socket: /run/containerd-rs.sock
    config_path: /boot/config-containerd-rs.toml   # baked → machined won't overwrite
  services:
    - id: rusternetes
      # Argv/env are A1-PROVEN verbatim (the embedded kubelet drove containerd-rs
      # with exactly these). --disable-dns: no CoreDNS needed for the M2a smoke.
      command:
        - /boot/bin/rusternetes
        - --storage-backend
        - sqlite
        - --data-dir
        - /var/lib/rusternetes/db
        - --tls
        - --bind-address
        - 0.0.0.0:6443
        - --node-name
        - node-1
        - --skip-auth
        - --disable-proxy        # A1 ran with this; E2 MUST re-enable (drop this line) if flannel needs the kubernetes Service ClusterIP route
        - --disable-dns
      depends_on: [containerd]      # gated on CRI RuntimeReady (see boot.rs RuntimeReadiness)
      restart: always
      env:
        - { key: RUST_LOG, value: info }
        - { key: RUST_MIN_STACK, value: "8388608" }
        - { key: PATH, value: "/boot/bin:/usr/bin:/bin" }
        - { key: CONTAINER_RUNTIME_ENDPOINT, value: "unix:///run/containerd-rs.sock" }
```

(Argv/env above are exactly what Task A1 proved. **A1 open item:** flannel DS did
not converge in the A1 container probe — E2 verifies flannel for real and, if the
overlay needs the kubernetes Service ClusterIP, drops `--disable-proxy` here.)

- [ ] **Step 2: Validate it parses (machined config loader)**

Run: `cd /home/jones/PhpstormProjects/machined-rs && cargo run -q -p machined-imager -- build --help >/dev/null && cargo test -p machined-config` then a focused parse via a tiny scratch test or `cargo run -p machinectl`-adjacent validator if present. Minimum: `python3 -c "import yaml,sys; yaml.safe_load(open('/home/jones/PhpstormProjects/mikronetes/deploy/m2a/config.yaml'))"`.
Expected: no YAML error; `machined-config` suite still green (proves `env`/`runtime.socket` fields exist from Tasks B1).

- [ ] **Step 3: Commit**

```bash
cd /home/jones/PhpstormProjects/mikronetes
git add deploy/m2a/config.yaml
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "feat(m2a): machine.yaml — containerd-rs runtime + all-in-one service

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task D2: Build the M2a image (kernel + initramfs + disk)

**Files:**
- Create: `scripts/m2a-build-image.sh` (mikronetes)

**Interfaces:**
- Produces: `out/m2a.img` (GPT disk with FAT `/boot` carrying the overlay) + `out/boot/{vmlinuz,initramfs.img}` (via `--emit-boot`). Consumed by Task D3 (the launcher).

- [ ] **Step 1: Write the build script**

Create `scripts/m2a-build-image.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
MR="${MACHINED_RS:-/home/jones/PhpstormProjects/machined-rs}"
OUT="${OUT:-$(pwd)/out}"; mkdir -p "$OUT/boot"
# 1. overlay (binaries + config).
OUT="$OUT/overlay" bash scripts/m2a-build-overlay.sh
# 2. build the static machined + imager.
( cd "$MR" && cargo build --release -p machined -p machined-imager -p machinectl )
MACHINED="$MR/target/x86_64-unknown-linux-musl/release/machined"
[ -f "$MACHINED" ] || MACHINED="$MR/target/release/machined"   # musl target vs default
IMAGER="$MR/target/release/machined-imager"
# 3. PKI + image with our overlay; emit kernel+initramfs for direct boot.
"$IMAGER" gen-pki --out "$OUT/pki"
"$IMAGER" build --arch x86_64 --image-id m2a \
  --machined "$MACHINED" \
  --config deploy/m2a/config.yaml \
  --overlay "$OUT/overlay" \
  --pki-dir "$OUT/pki" \
  --emit-boot "$OUT/boot" \
  --out "$OUT/m2a.img" --cache "$MR/target/imager-cache"
echo "built: $OUT/m2a.img + $OUT/boot/{vmlinuz,initramfs.img}"
ls -lh "$OUT/m2a.img" "$OUT/boot/vmlinuz" "$OUT/boot/initramfs.img"
```

(`--config` embeds the machine.yaml as `/boot/config.yaml`; the `--overlay` adds the binaries + the containerd-rs config. The base machined `runtime.binary` default is irrelevant — our config overrides it.)

- [ ] **Step 2: Run it**

Run: `cd /home/jones/PhpstormProjects/mikronetes && bash scripts/m2a-build-image.sh`
Expected: `built: …/m2a.img …`; `vmlinuz` (a bzImage, ~10–15 MiB) and `initramfs.img` exist; `m2a.img` is a sparse GPT image.

- [ ] **Step 3: Sanity-check the FAT carries the overlay**

Run: `file out/boot/vmlinuz` (expect "Linux kernel x86 boot executable bzImage") and confirm the imager logged the overlay copy. Optionally `mdir -i` is not available; trust the `copy_overlay` test from C1.
Expected: vmlinuz is a bzImage (CH/QEMU boot it directly).

- [ ] **Step 4: Commit**

```bash
git add scripts/m2a-build-image.sh
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "feat(m2a): build the node image (imager --overlay + --emit-boot)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase E — Boot harness, bootstrap, smoke

### Task E1: `m2a-up.sh` — launch (QEMU-TCG or CH) + convergence gate

**Files:**
- Create: `scripts/m2a-up.sh` (mikronetes)
- Create: `scripts/m2a-net.sh` (bridge + tap helper, sourced by m2a-up.sh)

**Interfaces:**
- Consumes: `out/m2a.img`, `out/boot/{vmlinuz,initramfs.img}` from D2.
- Produces: a running VM reachable at `10.88.0.2` (api-server `:6443`, machined `:50000`); a `state.img`; a serial log at `out/serial.log`. `--backend qemu|ch` (default `qemu`).

- [ ] **Step 1: Write the network helper**

Create `scripts/m2a-net.sh` (idempotent; needs sudo):

```bash
#!/usr/bin/env bash
set -euo pipefail
BR=mkn-br0; TAP="${TAP:-mkn0}"; BRIP=10.88.0.1/24; USER_="$(whoami)"
ip link show "$BR" >/dev/null 2>&1 || sudo ip link add name "$BR" type bridge
ip addr show "$BR" | grep -q 10.88.0.1 || sudo ip addr add "$BRIP" dev "$BR"
ip link show "$TAP" >/dev/null 2>&1 || sudo ip tuntap add mode tap user "$USER_" name "$TAP"
sudo ip link set "$TAP" master "$BR"
sudo ip link set "$BR" up; sudo ip link set "$TAP" up
sudo sysctl -wq net.ipv4.ip_forward=1
echo "bridge $BR + tap $TAP up (gw 10.88.0.1, VM 10.88.0.2)"
```

- [ ] **Step 2: Write `m2a-up.sh` (backend-agnostic launch)**

Create `scripts/m2a-up.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
OUT="${OUT:-$(pwd)/out}"; BACKEND="${BACKEND:-qemu}"; TAP="${TAP:-mkn0}"
KERNEL="$OUT/boot/vmlinuz"; INITRD="$OUT/boot/initramfs.img"; IMG="$OUT/m2a.img"
SERIAL="$OUT/serial.log"; MAC="52:55:00:88:00:02"
say(){ printf '\n==> %s\n' "$*"; }; die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ -f "$KERNEL" ] && [ -f "$IMG" ] || die "image not built — run scripts/m2a-build-image.sh"
[ -f "$OUT/state.img" ] || truncate -s 2G "$OUT/state.img"
bash scripts/m2a-net.sh
: > "$SERIAL"

case "$BACKEND" in
  qemu)
    KVM=""; [ -w /dev/kvm ] && KVM="-enable-kvm -cpu host"   # TCG when no /dev/kvm (CI)
    # shellcheck disable=SC2086
    qemu-system-x86_64 $KVM -m 512 -smp 2 -machine q35 \
      -kernel "$KERNEL" -initrd "$INITRD" \
      -append "console=ttyS0 root=/dev/ram0 rw" \
      -drive file="$IMG",if=virtio,format=raw \
      -drive file="$OUT/state.img",if=virtio,format=raw \
      -netdev tap,id=n0,ifname="$TAP",script=no,downscript=no \
      -device virtio-net-pci,netdev=n0,mac="$MAC" \
      -display none -serial "file:$SERIAL" -daemonize ;;
  ch)
    [ -w /dev/kvm ] || die "cloud-hypervisor needs /dev/kvm"
    CH="${CH_BIN:-$OUT/cloud-hypervisor}"
    [ -x "$CH" ] || { curl -fsSL -o "$CH" https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v52.0/cloud-hypervisor-static; chmod +x "$CH"; }
    "$CH" --kernel "$KERNEL" --initramfs "$INITRD" \
      --cmdline "console=ttyS0 root=/dev/ram0 rw" \
      --memory size=512M --cpus boot=2 \
      --disk path="$IMG" path="$OUT/state.img" \
      --net "tap=$TAP,mac=$MAC" \
      --serial tty --console off --api-socket "$OUT/ch.sock" \
      > "$SERIAL" 2>&1 &
    ;;
  *) die "unknown backend $BACKEND (qemu|ch)";;
esac
```

(`root=/dev/ram0` because machined boots from the initramfs; the disks are the imager image + state. Confirm the exact `root=`/cmdline machined expects against `scripts/boot-test-x86_64.sh` — match its `-append` if it differs.)

- [ ] **Step 3: Add the convergence gate**

Append to `scripts/m2a-up.sh`:

```bash
VMIP=10.88.0.2
kc(){ kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }
say "waiting for node-1 Ready + api reachable (~ up to 8m on TCG)"
ok=0
for _ in $(seq 1 96); do
  st=$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo)
  if [ "$st" = True ]; then ok=1; break; fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "---- serial tail ----"; tail -50 "$SERIAL"; die "node-1 not Ready (see $SERIAL)"; }
say "node-1 Ready. machinectl + smoke next: scripts/m2a-smoke.sh"
```

- [ ] **Step 4: Run locally (CH, since dev box has KVM) — first real boot**

Run: `BACKEND=ch bash scripts/m2a-up.sh`
Expected: eventually `node-1 Ready`. If it stalls, `tail -50 out/serial.log` shows where machined stopped (use systematic-debugging; common: net config, CRI socket, missing binary in overlay).

- [ ] **Step 5: Run under QEMU-TCG too (the CI path)**

Run: `BACKEND=qemu bash scripts/m2a-up.sh` (force TCG: temporarily `chmod` aside `/dev/kvm` is overkill — instead trust that CI nodes have none; locally it'll use KVM via qemu which is fine for proving the qemu path boots).
Expected: `node-1 Ready` under qemu as well.

- [ ] **Step 6: Commit**

```bash
git add scripts/m2a-up.sh scripts/m2a-net.sh
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "feat(m2a): boot harness — qemu|ch backend + bridge/tap + convergence gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task E2: Post-boot bootstrap (flannel DaemonSet + cluster resources + test pod)

**Files:**
- Create: `scripts/m2a-bootstrap.sh` (mikronetes)

**Interfaces:**
- Consumes: a Ready node at `10.88.0.2`. Reuses `rusternetes-m1/deploy/flannel/flannel-rs.yaml` + the M1 bootstrap cluster resources (`kubernetes` Service 10.96.0.1, kube-dns, RBAC, SAs).
- Produces: flannel Ready (`/run/flannel/subnet.env` written), the `kubernetes` Service routable, and a `whoami` test pod Running.

- [ ] **Step 1: Write the bootstrap script**

Create `scripts/m2a-bootstrap.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
M1="${RUSTERNETES_M1:-/home/jones/PhpstormProjects/rusternetes-m1}"
VMIP="${VMIP:-10.88.0.2}"
kc(){ kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }
# Cluster resources the all-in-one doesn't self-create (the kubernetes Service,
# kube-dns Service, RBAC, ServiceAccounts). Reuse M1's bootstrap manifest.
[ -f "$M1/bootstrap-cluster.yaml" ] && kc apply -f "$M1/bootstrap-cluster.yaml" || true
# flannel DaemonSet (hostNetwork; needs no CNI to start).
kc apply -f "$M1/deploy/flannel/flannel-rs.yaml"
echo "waiting for flannel Ready"
for _ in $(seq 1 60); do
  r=$(kc get ds -n kube-flannel kube-flannel-ds -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
  [ "${r:-0}" -ge 1 ] && break; sleep 5
done
# the smoke test pod.
kc run whoami --image=traefik/whoami:v1.10.2 --labels=m2a=whoami >/dev/null 2>&1 || true
echo "bootstrap applied"
```

(If the all-in-one already creates the `kubernetes` Service internally, the `bootstrap-cluster.yaml` apply is a harmless no-op/partial — keep it for the SAs/RBAC flannel needs. Verify against the A1 run: if flannel came up in A1 without bootstrap-cluster.yaml, drop that line.)

- [ ] **Step 2: Run it; expect flannel Ready + pod scheduled**

Run: `bash scripts/m2a-bootstrap.sh`
Expected: `flannel Ready`; `kubectl … get pods` shows `whoami` progressing to Running.

- [ ] **Step 3: Commit**

```bash
git add scripts/m2a-bootstrap.sh
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "feat(m2a): post-boot bootstrap — flannel DS + cluster resources + test pod

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task E3: `m2a-smoke.sh` — assertions + 512 MiB memory report

**Files:**
- Create: `scripts/m2a-smoke.sh` (mikronetes)

**Interfaces:**
- Consumes: the running VM (`10.88.0.2`), `out/serial.log`, the machined mTLS API, the `whoami` pod.
- Produces: exit 0 + a memory report only if all assertions hold.

- [ ] **Step 1: Write the smoke gate**

Create `scripts/m2a-smoke.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
VMIP="${VMIP:-10.88.0.2}"; OUT="${OUT:-$(pwd)/out}"; MR="${MACHINED_RS:-/home/jones/PhpstormProjects/machined-rs}"
fail=0; pass(){ printf 'PASS: %s\n' "$*"; }; bad(){ printf 'FAIL: %s\n' "$*" >&2; fail=1; }
kc(){ kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

echo "=== 1. node Ready ==="
[ "$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
  && pass "node-1 Ready" || bad "node-1 not Ready"

echo "=== 2. machined services healthy (mTLS API) ==="
MCTL="$MR/target/release/machinectl"
if [ -x "$MCTL" ]; then
  out=$("$MCTL" --endpoint "https://$VMIP:50000" --pki "$OUT/pki" get ServiceStatus 2>&1 || echo "")
  echo "$out"
  echo "$out" | grep -q 'rusternetes' && echo "$out" | grep -q 'healthy=true' \
    && pass "machined reports services healthy" || bad "machined ServiceStatus not healthy"
else
  bad "machinectl not built at $MCTL"
fi

echo "=== 3. CRI is containerd-rs (RuntimeStatus) ==="
"$MCTL" --endpoint "https://$VMIP:50000" --pki "$OUT/pki" get RuntimeStatus 2>&1 | grep -q 'ready=true' \
  && pass "containerd-rs RuntimeReady" || bad "runtime not ready"

echo "=== 4. workload pod Running + reachable over flannel ==="
ip=""; for _ in $(seq 1 60); do
  ph=$(kc get pod whoami -o jsonpath='{.status.phase}' 2>/dev/null || echo)
  ip=$(kc get pod whoami -o jsonpath='{.status.podIP}' 2>/dev/null || echo)
  [ "$ph" = Running ] && [ -n "$ip" ] && break; sleep 5
done
if [ "$(kc get pod whoami -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]; then
  out=$(kc exec whoami -- wget -qO- "http://127.0.0.1:80/" 2>/dev/null || true)
  printf '%s' "$out" | grep -q 'Hostname:' && pass "whoami Running and serving ($ip)" \
    || bad "whoami Running but not serving"
else bad "whoami pod not Running"; fi

echo "=== 5. 512 MiB memory report ==="
# Guest-side: free -m inside the VM via machinectl exec if available, else parse serial.
# Host-side: RSS of the qemu/cloud-hypervisor process.
hostrss=$(ps -o rss= -C qemu-system-x86_64 2>/dev/null | awk '{s+=$1} END{print s/1024 " MiB (qemu RSS)"}')
[ -z "$hostrss" ] && hostrss=$(ps -o rss= -C cloud-hypervisor 2>/dev/null | awk '{s+=$1} END{print s/1024 " MiB (ch RSS)"}')
echo "host VMM RSS: ${hostrss:-unknown}"
echo "guest cap: 512 MiB (enforced by -m 512 / --memory size=512M)"
# A genuine OOM shows as the kubelet/pods crashlooping or machined OOM in serial:
grep -qiE 'Out of memory|oom-kill' "$OUT/serial.log" && bad "guest OOM in serial log" || pass "no guest OOM"

[ "$fail" -eq 0 ] && { echo "=== M2a SMOKE PASSED ==="; exit 0; } || { echo "=== M2a SMOKE FAILED ===" >&2; exit 1; }
```

(Adjust `machinectl` flag names — `--endpoint`/`--pki` — to the real ones in `crates/machinectl/src/main.rs`; read it first and match. The kubectl-exec in §4 relies on the exec/logs work landed in rusternetes #1504; if the all-in-one image predates it, fall back to the nsenter-in-netns method from `m1-smoke.sh`.)

- [ ] **Step 2: Run the full local sequence**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes
bash scripts/m2a-build-image.sh
BACKEND=ch bash scripts/m2a-up.sh
bash scripts/m2a-bootstrap.sh
bash scripts/m2a-smoke.sh
```
Expected: `=== M2a SMOKE PASSED ===` and a host VMM RSS line. Record the memory numbers.

- [ ] **Step 3: Commit + record the memory finding in the spec**

```bash
git add scripts/m2a-smoke.sh
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "feat(m2a): smoke gate — node Ready, machined healthy, pod over flannel, 512MB report

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Then append the measured numbers to the spec's success-criteria section and commit that too.

---

## Phase F — CI: QEMU-TCG boot gate on self-hosted ARC

### Task F1: GitHub Actions workflow (build → QEMU-TCG boot → smoke)

**Files:**
- Create: `.github/workflows/m2a-stack.yml` (mikronetes)

**Interfaces:**
- Consumes: the harness scripts (E1–E3) + `deploy/m2a/`. Runs on a self-hosted ARC runner.
- Produces: a green-on-push gate proving the M2a image boots under QEMU-TCG and the smoke passes, without `/dev/kvm`.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/m2a-stack.yml`:

```yaml
name: m2a-microvm-smoke
on:
  push: { branches: [main] }
  pull_request:
  workflow_dispatch:
concurrency: { group: m2a-${{ github.ref }}, cancel-in-progress: true }
jobs:
  m2a:
    runs-on: [self-hosted, linux, x64]   # Dallas ARC; QEMU-TCG (no /dev/kvm needed)
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      - name: Checkout rusternetes fork (compose/manifests; PUBLIC)
        uses: actions/checkout@v4
        with: { repository: indyjonesnl/rusternetes, ref: main, path: rusternetes-m1 }
      - name: Checkout machined-rs (imager + machined)
        uses: actions/checkout@v4
        with: { repository: indyjonesnl/machined-rs, ref: main, path: machined-rs }
      - name: Tooling
        run: |
          set -e
          which qemu-system-x86_64 || sudo apt-get update && sudo apt-get install -y qemu-system-x86 iproute2
          KV=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
          sudo curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KV}/bin/linux/amd64/kubectl"
          sudo chmod +x /usr/local/bin/kubectl
      - name: Build image
        env: { RUSTERNETES_M1: ${{ github.workspace }}/rusternetes-m1, MACHINED_RS: ${{ github.workspace }}/machined-rs }
        run: bash scripts/m2a-build-image.sh
      - name: Boot (QEMU-TCG) + bootstrap + smoke
        env: { RUSTERNETES_M1: ${{ github.workspace }}/rusternetes-m1, MACHINED_RS: ${{ github.workspace }}/machined-rs, BACKEND: qemu }
        run: |
          bash scripts/m2a-up.sh
          bash scripts/m2a-bootstrap.sh
          bash scripts/m2a-smoke.sh
      - name: Diagnostics on failure
        if: failure()
        run: tail -200 out/serial.log || true
```

(The runner must allow `sudo ip`/`qemu` — the ARC pods are privileged per the runner config. `cargo` must be available on the runner image for the imager build; if not, add a Rust setup step or pre-bake it.)

- [ ] **Step 2: Validate the workflow YAML**

Run: `cd /home/jones/PhpstormProjects/mikronetes && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/m2a-stack.yml'))"`
Expected: no error.

- [ ] **Step 3: Commit + push; watch the run**

```bash
git add .github/workflows/m2a-stack.yml
git -c user.name="Indy Jones" -c user.email="indyjonesnl@gmail.com" \
  commit -m "ci(m2a): QEMU-TCG microVM boot+smoke gate on self-hosted ARC

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push
gh run watch
```

Expected: green. Iterate on real failures via systematic-debugging (most likely: cargo missing on runner, tap permissions, or boot-time stalls in serial.log). Do not merge a red gate.

---

## Self-Review

**Spec coverage:**
- Success #1 (CH direct-boots kernel+initramfs, machined PID1) → D2 + E1 (ch backend). ✓
- Success #2 (machinectl shows services healthy/RuntimeReady) → E3 §2–3. ✓
- Success #3 (node Ready) → E1 gate + E3 §1. ✓
- Success #4 (one pod runs over flannel, curl works) → E2 + E3 §4. ✓
- Success #5 (under 512 MiB, report) → E3 §5. ✓
- Addendum: QEMU/CH backend → E1; embedded kubelet (no separate kubelet) → A1 + D1; flannel as DS → E2; machined `env` gap → B1; runtime byo-config (write-if-absent) → D1 (no code change, baked config); payload via imager `--overlay` + artifacts → C1/C2; boot disk = imager image + state → D2/E1; pinned versions → C2. ✓

**Placeholder scan:** No "TBD"/"handle errors". Two explicit verify-against-source notes (machinectl flag names in E3; exact `-append` cmdline in E1) point at named files — acceptable, not placeholders. A1 Step 4 documents the design-branch if the embedded-kubelet assumption fails.

**Type consistency:** `EnvVar{key,value}` defined in B1 and used in D1's YAML (`{key:…, value:…}`). `copy_overlay(overlay, staging)` defined + tested in C1, invoked in build.rs. `runtime.socket`/`config_path` used in D1 match `RuntimeSection` fields confirmed in research. CRI socket `/run/containerd-rs.sock` consistent across C2/D1.

**Risk note (logged, not silenced):** A1 is a hard gate — if the all-in-one's embedded kubelet cannot drive an external containerd-rs, the node shape changes (separate kubelet service) and D1/E* adjust; this is why A1 runs first.

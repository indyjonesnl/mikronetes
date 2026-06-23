# containerd-rs CRI gap fixes (v0.1.2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`). containerd-rs uses TDD with `cargo test`; each task writes a failing test first.

**Goal:** Fix the four CRI gaps M1 surfaced so a rusternetes/k8s node on containerd-rs passes more conformance: honor `capabilities.add`, create missing hostPath bind sources, make `kubectl logs`/`exec` work, and stop leaking container process trees on restart.

**Architecture:** All work is in the containerd-rs worktree `/home/jones/PhpstormProjects/containerd-rs-k0sfix` (branch `fix/k0s-worker-cri-gaps`, the v0.1.1 line, HEAD `c359b0f`). Direct-runc model: `create_container`→`start_container`→`supervise_container` runs `runc run` (runc symlinked to crun) supervised by a Tokio task. Fixes are localized to `crates/runtime/src/bundle.rs`, `crates/runtime/src/runc.rs`, and `crates/cri/src/server.rs`/`streaming.rs`.

**Tech Stack:** Rust, oci-spec, tonic CRI, tokio; `cargo test`; `make check` (fmt+clippy+test).

## Global Constraints
- Work ONLY in `/home/jones/PhpstormProjects/containerd-rs-k0sfix` (branch `fix/k0s-worker-cri-gaps`). Do not touch rusternetes or mikronetes.
- TDD: write the failing test first, against the existing `#[cfg(test)]` suites named per task. `make check` (fmt + clippy `-D warnings` + full workspace test) must pass before each commit.
- Preserve the `privileged` short-circuit semantics already in `bundle.rs::apply_privileged`.
- Keep the direct-runc model (no shim); OCI runtime is invoked as `runc` on PATH (= crun in deployment).
- Commits: identity `Indy Jones <indyjonesnl@gmail.com>` + trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. No tag/push (the human cuts v0.1.2).

---

## Task 1 — hostPath: create missing bind-mount source dirs

**Files:** Modify `crates/runtime/src/bundle.rs` (`add_bind_mounts`, ~393-415). Test: `crates/runtime/src/bundle.rs` tests (~450).

- [ ] **Step 1: Failing test** — in `bundle.rs` tests, build a `ContainerRequest` with a `MountSpec` whose `source` is a non-existent temp subdir (use `tempfile::tempdir()` + a `.join("net.d")` that doesn't exist), call `generate_spec`, assert (a) the dir now exists and (b) the spec's mounts contain a bind mount with that source/destination.
- [ ] **Step 2:** `cargo test -p runtime add_bind_mounts_creates_missing_source` → FAIL (dir not created).
- [ ] **Step 3: Implement** — in `add_bind_mounts`, before building each bind `MountBuilder`, if `Path::new(&m.source)` does not exist, `std::fs::create_dir_all(&m.source)` (best-effort: log on error, still add the mount). Only create directories — do NOT attempt to create file sources (documented limitation; CNI/dir case is the target).
- [ ] **Step 4:** `cargo test -p runtime add_bind_mounts_creates_missing_source` → PASS; then `make check`.
- [ ] **Step 5: Commit** `fix(runtime): create missing hostPath bind-mount source dirs (DirectoryOrCreate)`.

## Task 2 — honor `securityContext.capabilities.add`/`drop`

**Files:** Modify `crates/runtime/src/bundle.rs` (`ContainerRequest` ~50-102, `generate_spec`/`ProcessBuilder` ~285-327, reuse `all_capabilities()` ~128-175) + `crates/cri/src/server.rs` (`create_container` security-context wiring ~847-919). Test: `crates/runtime/src/bundle.rs` tests (~450).

**Interfaces produced:** `ContainerRequest { add_capabilities: Vec<String>, drop_capabilities: Vec<String> }` (CRI capability names like `"NET_ADMIN"` or `"CAP_NET_ADMIN"`).

- [ ] **Step 1: Failing tests** — in `bundle.rs` tests (mirror `run_as_user_overrides_image_user` ~604): (a) a `ContainerRequest{ privileged:false, add_capabilities: vec!["NET_ADMIN".into()], ..}` → `generate_spec` → assert the OCI `process.capabilities` bounding/effective/permitted sets contain `Capability::NetAdmin`; (b) `drop_capabilities: vec!["NET_ADMIN".into()]` removes it; (c) `privileged:true` still yields the full `all_capabilities()` set regardless of add/drop (short-circuit unchanged).
- [ ] **Step 2:** `cargo test -p runtime capabilities` → FAIL (fields/logic absent).
- [ ] **Step 3: Implement**
  - Add `add_capabilities: Vec<String>` + `drop_capabilities: Vec<String>` to `ContainerRequest` (default empty).
  - Add a helper `fn parse_cap(name: &str) -> Option<Capability>`: strip an optional `CAP_` prefix, uppercase, match against the variants enumerated in `all_capabilities()` (e.g. `NET_ADMIN`→`Capability::NetAdmin`); also accept `"ALL"` → the full set.
  - Add `fn apply_capabilities(spec, add, drop)`: when NOT privileged, start from the default process caps, insert each parsed `add`, remove each parsed `drop`, and set bounding/effective/permitted/inheritable. Call it in `generate_spec` after the process is built, gated `if !req.privileged` (privileged path keeps `apply_privileged`).
  - In `server.rs::create_container`, populate the two fields from `sec_ctx.and_then(|sc| sc.capabilities.as_ref())` → `add_capabilities`/`drop_capabilities`.
- [ ] **Step 4:** `cargo test -p runtime capabilities` → PASS; `make check`.
- [ ] **Step 5: Commit** `feat(cri): honor securityContext.capabilities add/drop in the OCI spec`.

## Task 3 — `kubectl logs`: create the CRI LogPath file before the RPC returns

**Files:** Modify `crates/cri/src/server.rs` (`create_container` log_path resolution ~944-954, and/or `start_container` ~1153). Test: `crates/cri/src/server.rs` `container_create_status_list_stop_remove` (~2585).

- [ ] **Step 1: Failing test** — extend/duplicate `container_create_status_list_stop_remove` (it uses `log_path: "c0.log"`): after `create_container` (and `start_container`), assert the resolved absolute log path (`sandbox.log_directory` + container `log_path`) **exists on disk**.
- [ ] **Step 2:** `cargo test -p cri log_path_exists_after_create` → FAIL (file created lazily only in `supervise_container`).
- [ ] **Step 3: Implement** — in `create_container`, right after computing the absolute `log_path` (~954), synchronously `std::fs::create_dir_all(parent)` then `std::fs::File::create(&log_path)` (ignore AlreadyExists). This guarantees the kubelet finds an (initially empty) file instead of ENOENT. Leave `supervise_container`'s existing open/write path intact (it appends).
- [ ] **Step 4:** `cargo test -p cri log_path_exists_after_create` → PASS; `make check`.
- [ ] **Step 5: Commit** `fix(cri): create container LogPath synchronously so kubectl logs doesn't ENOENT`.

## Task 4 — reap container process trees on stop (no leak)

**Files:** Modify `crates/cri/src/server.rs` (`stop_container` ~1083-1110, `reconcile` ~2010-2027) + `crates/runtime/src/runc.rs` (`kill` ~181, `delete` ~192). Test: `crates/cri/src/server.rs` `container_create_status_list_stop_remove` (~2585) + `crates/runtime/src/runc.rs` tests (~252).

- [ ] **Step 1: Failing tests** — (a) `runc.rs` tests: assert a SIGKILL-escalation kill builds `["--root", root, "kill", id, "KILL"]` and that stop's force path issues `delete --force` (mirror `update_args_maps_set_fields_only`); (b) `server.rs`: in the stop/remove transition test, assert `stop_container` does NOT unconditionally record `exit_code = 0` and that the force-delete primitive is invoked on stop (use the test harness's runc-call recorder if present; else assert state + that the recorded exit reflects the real wait, not a hardcoded 0).
- [ ] **Step 2:** `cargo test -p runtime kill ; cargo test -p cri stop_container` → FAIL.
- [ ] **Step 3: Implement**
  - `stop_container`: after `runc kill <id> SIGTERM`, wait up to the request timeout for the container to exit; on timeout escalate to `runc kill <id> KILL`, then `runc::delete(id, force=true)`. Stop hardcoding `exit_code = 0` — record the observed/forced exit. This lets the supervise task's `child.wait()` complete and reaps the tree.
  - `runc.rs`: ensure `kill` accepts an arbitrary signal name (`SIGTERM`/`KILL`) and `delete` supports `--force` (it does at ~192 — reuse).
  - `reconcile` (~2010): for each formerly-`Running` record, best-effort `runc::delete(id, force=true)` to clear trees orphaned across a daemon restart (in addition to the existing Running→Unknown marking).
  - (Optional, only if straightforward) spawn `runc run` in its own process group (`std::os::unix::process::CommandExt::process_group(0)`) in `supervise_container` so a stray reparented child can be swept; skip if it complicates stdio wiring.
- [ ] **Step 4:** `cargo test -p runtime kill ; cargo test -p cri stop_container` → PASS; `make check`.
- [ ] **Step 5: Commit** `fix(cri): reap container process trees on stop/reconcile (SIGTERM→KILL→delete --force)`.

## Task 5 — `kubectl exec` over WebSocket: send a coded Close on every exit (conformance blocker)

**Files:** Modify `crates/cri/src/streaming.rs` (`handle_exec` ~317-458, early-return branches ~332-360, success close ~457). Test: `crates/cri/src/server.rs` `streaming_exec_over_websocket` (~3032) + `streaming.rs` tests (~881).

**NOTE (flagged as possibly-architectural):** WS close 1005 = "no status received". The minimal fix is to send a proper coded Close frame on ALL exit paths (success + error early-returns), instead of bare `return`/`Close(None)`. BEFORE implementing, the implementer must CONFIRM whether the kubelet's exec to containerd-rs is WebSocket or SPDY here (check the exec URL handler + the `streaming_exec_over_websocket` test path). If it's purely SPDY, the 1005 originates in the SPDY upgrade/`goaway` path (`spdy_upgrade` ~210-267) and this becomes a deeper fix — report DONE_WITH_CONCERNS or BLOCKED with the wire evidence rather than guessing.

- [ ] **Step 1: Failing test** — extend `streaming_exec_over_websocket` to assert the client receives a WebSocket **Close frame carrying a code** (e.g. 1000 normal closure) on a successful exec, and add a case for the token-miss / exec-spawn-failure branch asserting a coded Close (not a bare drop).
- [ ] **Step 2:** `cargo test -p cri streaming_exec_over_websocket` → FAIL (current code sends `Close(None)` on success and bare `return` on errors → no/blank code).
- [ ] **Step 3: Implement** — in `handle_exec`: on success replace `sink.send(Message::Close(None))` with `Message::Close(Some(CloseFrame { code: 1000, reason: "".into() }))`; on the `take_exec` miss (~332-343) and the runc-exec-failure branch (~353-360), after emitting the CH_ERROR metav1.Status frame, send `Message::Close(Some(CloseFrame { code: 1000, reason: ... }))` before returning. (Use the `axum`/`tungstenite` `CloseFrame`/`CloseCode` types already in scope.)
- [ ] **Step 4:** `cargo test -p cri streaming_exec_over_websocket` → PASS; `make check`.
- [ ] **Step 5: Commit** `fix(cri): send coded WebSocket Close on all exec exit paths (kubectl exec 1005)`.

## Task 6 — version bump 0.1.2 + release-readiness

**Files:** Modify `Cargo.toml` (`[workspace.package] version`), refresh `Cargo.lock`.

- [ ] **Step 1:** Set `[workspace.package] version = "0.1.2"`; `cargo build` to refresh the lockfile.
- [ ] **Step 2:** Release-readiness: `make check` green + build the release musl binary (`cargo build --release --target x86_64-unknown-linux-musl -p containerd-rs`). Report the binary path + size. NO tag, NO push.
- [ ] **Step 3: Commit** `chore: bump workspace version to 0.1.2`.

---

## Self-Review
- **Coverage:** Gap 1 caps → Task 2; Gap 2 hostPath → Task 1; Gap 3a exec → Task 5; Gap 3b logs → Task 3; Gap 4 reap → Task 4; release → Task 6. ✅
- **Order:** ascending difficulty (hostPath, caps, logs, reap, exec), so the two conformance blockers (logs Task 3, exec Task 5) are covered; exec last as it's the riskiest.
- **Placeholders:** none — file:line + concrete fix shape + the exact existing test to extend are given per task (from the verified scoping). The one genuine unknown (exec SPDY-vs-WS) is handled by a confirm-first instruction + a DONE_WITH_CONCERNS/BLOCKED escape, not a TODO.
- **Type consistency:** `add_capabilities`/`drop_capabilities: Vec<String>` on `ContainerRequest` (Task 2) is the only new cross-file interface; Task 2 both defines and consumes it. `runc::delete(id, force=true)` / `runc::kill(id, signal)` reused in Task 4 match `runc.rs` ~181/192.
- **Risk:** Task 5 may exceed a localized fix (SPDY path) — flagged; implementer confirms wire protocol before coding.

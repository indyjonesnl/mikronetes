# M2c-1 — PHP DaemonSet + rhino-SQLite Durability (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a placeholder PHP website as a 3-replica DaemonSet (one pod per worker) behind a ClusterIP Service on the 4-node 512 MiB microVM cluster, with the control-plane store on the persistent STATE partition, and prove cluster state survives a node-1 restart — plus per-node/per-application memory reporting.

**Architecture:** Builds directly on M2c-0 (kube-proxy Services + native cluster DNS + system Services, all proven working). Node-1's rusternetes stores its rhino-SQLite DB on `/system/state` (the persistent install-disk partition machined provisions via image adoption) instead of the ephemeral `/var`. The workload becomes a PHP `DaemonSet` (schedules on the 3 workers; node-1's `NoSchedule` taint keeps it off the control plane — verified) fronted by a ClusterIP `Service`. A node-1-only kill+relaunch helper drives the durability test.

**Tech Stack:** rusternetes (rhino-SQLite storage), containerd-rs + crun, flannel host-gw, kube-proxy iptables, php:8.4-apache pod image, Cloud-Hypervisor.

## Global Constraints

- Every node caps at **512 MiB**; boot must not OOM. Report node-1 full control-plane RSS vs the cap.
- Git identity **Indy Jones <indyjonesnl@gmail.com>**; end commit messages with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Guest runtime is **containerd-rs + crun**; pod images are pulled from the local registry `10.88.0.1:5000` (mirror with `docker pull/tag/push`).
- CNI **flannel host-gw**, per-node podCIDRs `10.244.0/1/2/3.0/24`; cluster CIDR `10.244.0.0/16`; cluster DNS `10.96.0.10`; `kubernetes` Service pinned `10.96.0.1`.
- **No `kubectl exec`/`logs`** in gates — containerd-rs streaming is unwired; use command-based probe pods (phase + exitCode), the M2c-0 pattern.
- Durability is a **clean kill+relaunch** of node-1 (rhino runs WAL + `synchronous=NORMAL`, not power-loss FULL — that would need a rhino change, out of scope).
- Repos: mikronetes `/home/jones/PhpstormProjects/mikronetes`, rusternetes `/home/jones/PhpstormProjects/rusternetes`. Work on branch `experiment/m2a`.
- Persistent DB path: **`/system/state/rusternetes/state.db`** (STATE partition; survives kill+relaunch, only wiped by `machinectl reset`).

## Prerequisites (verified during planning)

- STATE partition is provisioned on `/dev/vda` (serial: `image disk: completing layout (appending STATE+EPHEMERAL)`) and mounted at `/system/state`.
- DaemonSet controller honors node-1's `node-role.kubernetes.io/control-plane:NoSchedule` taint → 3 pods on workers, 0 on node-1.
- In-cluster config, SA tokens, DNS, Services, kube-proxy all proven in M2c-0.

---

### Task 1: Move node-1's rhino-SQLite DB to the persistent STATE partition

**Files:**
- Modify: `scripts/m2b-generate-configs.sh` (node-1 rusternetes `--data-dir`)

**Interfaces:**
- Produces: node-1 opens its store at `/system/state/rusternetes/state.db`. Consumed by Task 5 (durability).

- [ ] **Step 1: Point --data-dir at the STATE partition**

In `scripts/m2b-generate-configs.sh`, in the node-1 `rusternetes` command, change:
```yaml
        - --data-dir
        - /var/lib/rusternetes/db
```
to:
```yaml
        - --data-dir
        - /system/state/rusternetes/state.db
```
(rhino/`RhinoStorage::new` treats `--data-dir` as the SQLite file path and `create_if_missing`s it; `/system/state` is a mounted persistent ext4 partition, so the parent dir is created by SQLite's open path. If rusternetes needs the parent dir pre-created, machined mounts `/system/state` read-write at boot — the api-server already persists PKI there.)

- [ ] **Step 2: Regenerate configs and verify the path**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && OUT=out/m2b bash scripts/m2b-generate-configs.sh
grep -A1 'data-dir' out/m2b/configs/node-1.yaml
```
Expected: `--data-dir` / `/system/state/rusternetes/state.db`.

- [ ] **Step 3: Rebuild + boot, confirm node-1 Ready with the new store**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes
bash scripts/m2b-down.sh || true
bash scripts/m2b-build-images.sh 2>&1 | tail -3
bash scripts/m2b-up-ch.sh 2>&1 | tail -8
```
Expected: all four nodes reach `Ready` (node-1's all-in-one opened the DB on `/system/state` without error — a bad path would fail-fast and node-1 would never be Ready).

- [ ] **Step 4: Commit**

```bash
git add scripts/m2b-generate-configs.sh
git commit -m "feat(m2c-1): store node-1 rhino-SQLite DB on the persistent STATE partition

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: PHP workload manifests (ConfigMap + DaemonSet + Service)

**Files:**
- Create: `deploy/m2c/php-daemonset.yaml`

**Interfaces:**
- Consumes: the local registry image `10.88.0.1:5000/php:8.4-apache` (mirrored in Task 4).
- Produces: a `php-web` DaemonSet (label `app=php-web`) + a `web` ClusterIP Service selecting it + a `php-index` ConfigMap. Consumed by Tasks 4, 5.

- [ ] **Step 1: Write the manifest**

Create `deploy/m2c/php-daemonset.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: php-index
  namespace: default
data:
  index.php: |
    <?php
    header('Content-Type: text/plain');
    echo "Hostname: " . gethostname() . "\n";
    echo "PodIP: " . ($_SERVER['SERVER_ADDR'] ?? 'unknown') . "\n";
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: php-web
  namespace: default
  labels: { app: php-web }
spec:
  selector:
    matchLabels: { app: php-web }
  template:
    metadata:
      labels: { app: php-web }
    spec:
      # No control-plane toleration => the DaemonSet skips tainted node-1,
      # landing exactly one pod on each of the three workers.
      containers:
      - name: php
        image: 10.88.0.1:5000/php:8.4-apache
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
        volumeMounts:
        - name: index
          mountPath: /var/www/html
      volumes:
      - name: index
        configMap:
          name: php-index
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: default
spec:
  type: ClusterIP
  selector: { app: php-web }
  ports:
  - name: http
    port: 80
    targetPort: 80
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && python3 -c "import yaml,sys; list(yaml.safe_load_all(open('deploy/m2c/php-daemonset.yaml'))); print('yaml OK')"
```
Expected: `yaml OK`.

- [ ] **Step 3: Commit**

```bash
git add deploy/m2c/php-daemonset.yaml
git commit -m "feat(m2c-1): PHP DaemonSet + web ClusterIP Service + index ConfigMap

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: node-1-only kill+relaunch helper

**Files:**
- Create: `scripts/m2c-restart-node1.sh`

**Interfaces:**
- Consumes: `out/m2b/node-1/ch.pid`, the boot artifacts under `out/m2b/boot`, and `out/m2b/node-1/{m2b.img,state.img}`.
- Produces: node-1's Cloud-Hypervisor VM killed and relaunched with identical args (same tap `mkn0`, MAC `52:55:00:88:00:02`, disks, serial, api-socket), then waits for the api-server to return. Consumed by Task 5.

This replicates `launch_ch()` from `scripts/m2b-up.sh` for node-1 only (m2b-up.sh cannot relaunch a single node — its `ensure_taps_free` check fails while the other three VMs hold their taps).

- [ ] **Step 1: Write the helper**

Create `scripts/m2c-restart-node1.sh`:
```bash
#!/usr/bin/env bash
# Kill and relaunch ONLY node-1's Cloud-Hypervisor VM (durability test): the
# rhino-SQLite store on /system/state must survive. Mirrors launch_ch() from
# m2b-up.sh for node-1; m2b-up.sh can't do a single node (tap-busy check).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${OUT:-$REPO_ROOT/out/m2b}"
CH_BIN="${CH_BIN:-/usr/local/bin/cloud-hypervisor}"
MEM="${CONTROL_PLANE_MEM:-${MEM:-512}}"
KERNEL="$OUT/boot/vmlinuz"; INITRD="$OUT/boot/initramfs.img"
CMDLINE="console=ttyS0 root=/dev/ram0 rw"
node_dir="$OUT/node-1"; serial="$node_dir/serial.log"

say() { printf '\n==> %s\n' "$*"; }

if [ -f "$node_dir/ch.pid" ]; then
  pid="$(cat "$node_dir/ch.pid")"
  if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
    say "killing node-1 CH pid $pid"
    kill "$pid" || true
    for _ in $(seq 1 30); do kill -0 "$pid" >/dev/null 2>&1 || break; sleep 1; done
  fi
fi

rm -f "$node_dir/ch.sock"
say "relaunching node-1 (mem=${MEM}MiB, tap=mkn0) — state.img + m2b.img persist on the host"
nohup setsid "$CH_BIN" \
  --kernel "$KERNEL" --initramfs "$INITRD" --cmdline "$CMDLINE" \
  --memory size="${MEM}M" --cpus boot=2 \
  --disk path="$node_dir/m2b.img" path="$node_dir/state.img" \
  --net "tap=mkn0,mac=52:55:00:88:00:02" \
  --serial tty --console off --api-socket "$node_dir/ch.sock" \
  >> "$serial" 2>&1 &
echo "$!" > "$node_dir/ch.pid"

say "waiting for node-1 API to return"
kc() { kubectl --server "https://10.88.0.2:6443" --insecure-skip-tls-verify --token dummy "$@"; }
ok=0
for _ in $(seq 1 96); do
  [ "$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && ok=1 && break
  sleep 5
done
[ "$ok" = 1 ] || { tail -30 "$serial"; echo "ERROR: node-1 did not return Ready" >&2; exit 1; }
say "node-1 back Ready"
```

- [ ] **Step 2: Make executable + syntax-check**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && chmod +x scripts/m2c-restart-node1.sh && bash -n scripts/m2c-restart-node1.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/m2c-restart-node1.sh
git commit -m "feat(m2c-1): node-1-only kill+relaunch helper for the durability test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: M2c-1 bootstrap — mirror PHP image + deploy the workload

**Files:**
- Create: `scripts/m2c1-bootstrap.sh`

**Interfaces:**
- Consumes: `scripts/m2c-bootstrap.sh` (system Services + DNS + whoami from M2c-0), `deploy/m2c/php-daemonset.yaml` (Task 2).
- Produces: `php:8.4-apache` mirrored to the local registry; the PHP DaemonSet (3 worker pods) + `web` Service applied. Consumed by Task 5.

- [ ] **Step 1: Write the bootstrap**

Create `scripts/m2c1-bootstrap.sh`:
```bash
#!/usr/bin/env bash
# M2c-1 bootstrap: M2c-0 (system Services + DNS) + a PHP DaemonSet workload.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VMIP="${VMIP:-10.88.0.2}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5000}"
PHP_IMAGE_SOURCE="${PHP_IMAGE_SOURCE:-php:8.4-apache}"
say() { printf '\n==> %s\n' "$*"; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

# M2c-0: system Services (kubernetes @.1, kube-dns @.10) + rusternetes-dns + whoami.
bash "$SCRIPT_DIR/m2c-bootstrap.sh"

say "mirroring $PHP_IMAGE_SOURCE into the local registry"
docker image inspect "$PHP_IMAGE_SOURCE" >/dev/null 2>&1 || docker pull "$PHP_IMAGE_SOURCE"
docker tag "$PHP_IMAGE_SOURCE" "localhost:${REGISTRY_HOST_PORT}/php:8.4-apache"
docker push "localhost:${REGISTRY_HOST_PORT}/php:8.4-apache" >/dev/null

say "applying PHP DaemonSet + web Service"
kc apply -f "$REPO_ROOT/deploy/m2c/php-daemonset.yaml"

say "waiting for 3 php-web pods Running (one per worker)"
ok=0
for _ in $(seq 1 60); do
  n=$(kc get pods -l app=php-web --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  [ "${n:-0}" -ge 3 ] && ok=1 && break
  sleep 5
done
[ "$ok" = 1 ] || { kc get pods -l app=php-web -o wide || true; echo "ERROR: php-web not at 3 Running" >&2; exit 1; }
say "waiting for web Service ClusterIP + endpoints"
for _ in $(seq 1 30); do
  cip=$(kc get svc web -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo)
  [ -n "$cip" ] && [ "$cip" != None ] && break
  sleep 2
done
say "web ClusterIP=$cip"
kc get pods -l app=php-web -o wide || true
say "m2c-1 bootstrap complete"
```

- [ ] **Step 2: Make executable + syntax-check**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && chmod +x scripts/m2c1-bootstrap.sh && bash -n scripts/m2c1-bootstrap.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/m2c1-bootstrap.sh
git commit -m "feat(m2c-1): bootstrap — mirror PHP image + deploy DaemonSet workload

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: M2c-1 smoke — DaemonSet placement, LB, durability, memory

**Files:**
- Create: `scripts/m2c1-smoke.sh`

**Interfaces:**
- Consumes: a cluster bootstrapped by `scripts/m2c1-bootstrap.sh`; `scripts/m2c-restart-node1.sh` (Task 3).
- Produces: the M2c-1 pass/fail gate.

- [ ] **Step 1: Write the smoke gate**

Create `scripts/m2c1-smoke.sh`:
```bash
#!/usr/bin/env bash
# M2c-1 smoke: PHP DaemonSet placement + Service LB + rhino-SQLite durability +
# per-node/per-application memory. No kubectl exec (containerd-rs streaming
# unwired) — in-cluster checks run as probe pods (phase + exitCode).
set -uo pipefail
VMIP="${VMIP:-10.88.0.2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

# Node -> expected podCIDR prefix, for the distinct-IP check.
prefix() { case "$1" in node-2) echo 10.244.1.;; node-3) echo 10.244.2.;; node-4) echo 10.244.3.;; esac; }

# Run a probe pod whose command is the assertion; echo its exit code.
lb_probe() { # $1=name $2=node
  kc delete pod "$1" --ignore-not-found --wait=false >/dev/null 2>&1 || true; sleep 1
  kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $1 }
spec:
  nodeName: $2
  restartPolicy: Never
  containers:
  - name: c
    image: 10.88.0.1:5000/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command:
    - sh
    - -c
    - |
      c=\$(for i in \$(seq 1 20); do wget -qO- --timeout=5 http://web.default.svc.cluster.local:80 | grep Hostname; done | sort -u | wc -l)
      echo "backends=\$c"; [ "\$c" -ge 2 ]
YAML
  local ph ec
  for _ in $(seq 1 60); do ph=$(kc get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null); { [ "$ph" = Succeeded ] || [ "$ph" = Failed ]; } && break; sleep 2; done
  ec=$(kc get pod "$1" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)
  kc delete pod "$1" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "${ec:-timeout}"
}

echo "=== 1. PHP DaemonSet: 3 pods, one per worker, none on node-1, distinct per-node IPs ==="
mapfile -t rows < <(kc get pods -l app=php-web -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.podIP}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null)
count=0; declare -A seen
[ "$(printf '%s\n' "${rows[@]}" | grep -c node-1)" = 0 ] && pass "no php-web pod on node-1 (taint honored)" || bad "php-web pod found on node-1"
for row in "${rows[@]}"; do
  set -- $row; node="$1"; ip="$2"; ph="$3"; [ -z "$node" ] && continue; count=$((count+1))
  [ "$ph" = Running ] || bad "$node php-web phase=$ph"
  case "$ip" in "$(prefix "$node")"*) pass "$node php-web $ip in podCIDR" ;; *) bad "$node php-web $ip not in $(prefix "$node")0/24" ;; esac
  [ -n "${seen[$ip]:-}" ] && bad "duplicate php-web IP $ip" || seen[$ip]="$node"
done
[ "$count" = 3 ] && pass "exactly 3 php-web pods" || bad "php-web pod count=$count (expected 3)"

echo "=== 2. web Service load-balances across >=2 PHP backends (probe pod, no exec) ==="
ec=$(lb_probe web-lb node-2)
[ "$ec" = 0 ] && pass "web Service load-balanced across >=2 PHP pods" || bad "web LB probe exitCode=$ec"

echo "=== 3. durability: snapshot -> restart node-1 -> state survives + LB still works ==="
before=$(kc get svc web -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
pods_before=$(kc get pods -l app=php-web -o jsonpath='{.items[*].metadata.uid}' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ',')
echo "pre-restart: web ClusterIP=$before ; php-web pod uids=$pods_before"
bash "$SCRIPT_DIR/m2c-restart-node1.sh" || bad "node-1 did not come back Ready after restart"
after=$(kc get svc web -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
pods_after=$(kc get pods -l app=php-web -o jsonpath='{.items[*].metadata.uid}' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ',')
[ -n "$after" ] && [ "$after" = "$before" ] && pass "web Service (ClusterIP $after) survived node-1 restart" || bad "web Service changed/lost across restart ('$before' -> '$after')"
[ "$pods_after" = "$pods_before" ] && pass "php-web pods (same uids) survived node-1 restart" || bad "php-web pod set changed across restart"
ec=$(lb_probe web-lb2 node-3)
[ "$ec" = 0 ] && pass "web Service still load-balances after node-1 restart" || bad "post-restart LB probe exitCode=$ec"

echo "=== 4. per-node / per-application memory (boot/idle) + node-1 CP total vs 512 ==="
bash "$SCRIPT_DIR/m2c1-memreport.sh" || bad "memory report failed"

echo "=== 5. no OOM / kernel panic ==="
for node in node-1 node-2 node-3 node-4; do
  grep -qaiE 'Out of memory|oom-kill|Kernel panic' "out/m2b/$node/serial.log" 2>/dev/null && bad "$node OOM/panic" || pass "$node no OOM/panic"
done

if [ "$fail" -eq 0 ]; then echo "=== M2c-1 SMOKE PASSED ==="; exit 0; else echo "=== M2c-1 SMOKE FAILED ===" >&2; exit 1; fi
```

- [ ] **Step 2: Write the memory reporter** (`scripts/m2c1-memreport.sh`), reusing M2b's memprobe pattern with an extended process-name set.

Create `scripts/m2c1-memreport.sh` by copying the `ensure_memprobe`/`print_memory_sample` machinery from `scripts/m2b-smoke.sh` (the ConfigMap `collect.sh` + the per-node `m2b-memprobe-*` hostPID/hostNetwork pods + the `print_memory_sample` table), changing exactly one thing — the tracked-process `case` list in `collect.sh` — from:
```
machined|containerd-rs|rusternetes|kubelet|flanneld|whoami|crun|runc|pause)
```
to:
```
machined|containerd-rs|rusternetes|kubelet|kube-proxy|flanneld|rusternetes-dns|whoami|apache2|php-fpm|httpd|crun|runc|pause)
```
and add, after the idle sample, a node-1 control-plane total line:
```bash
cp_total=$(awk -F, 'NR>1 && $1 ~ /rusternetes|containerd-rs|flanneld|crun|kube-proxy/ {s+=$2} END{printf "%.1f", s/1024}' "$OUT/m2b-memory-node-1-idle.csv")
printf "\nnode-1 control-plane total (idle): %s MiB / 512 MiB cap\n" "$cp_total"
```
Keep the table shape identical to M2b so the two milestones are comparable.

- [ ] **Step 3: Make executable + syntax-check both**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes && chmod +x scripts/m2c1-smoke.sh scripts/m2c1-memreport.sh && bash -n scripts/m2c1-smoke.sh && bash -n scripts/m2c1-memreport.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add scripts/m2c1-smoke.sh scripts/m2c1-memreport.sh
git commit -m "test(m2c-1): smoke — DaemonSet placement, Service LB, durability, memory

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Integration — build, boot, bootstrap, smoke

**Files:** none (acceptance run)

- [ ] **Step 1: Full clean run**

Run:
```bash
cd /home/jones/PhpstormProjects/mikronetes
bash scripts/m2b-down.sh || true
bash scripts/m2b-build-images.sh 2>&1 | tail -3
bash scripts/m2b-up-ch.sh 2>&1 | tail -5
bash scripts/m2c1-bootstrap.sh 2>&1 | tail -20
bash scripts/m2c1-smoke.sh 2>&1 | tee /tmp/m2c1-smoke.log
```
Expected: `=== M2c-1 SMOKE PASSED ===`, including 3 PHP pods one-per-worker with distinct per-node IPs, `web` Service load-balancing, cluster state (web Service + php-web pod uids) unchanged across a node-1 kill+relaunch, node-1 control-plane total reported under 512 MiB, and no OOM.

- [ ] **Step 2: If durability fails, distinguish the cause**

If step-3 of the smoke fails: check whether node-1 came back at all (`out/m2b/node-1/serial.log` tail — DB open error on `/system/state`?) vs the state being lost (rhino did not persist → the DB path/mount is wrong, revisit Task 1) vs pods restarting (kubelet re-created php-web pods with new uids — acceptable only if the DaemonSet controller re-adopted them; adjust the assertion to check pod *existence*/Running rather than uid identity if kubelet legitimately recreates on the CP restart).

- [ ] **Step 3: M2c-1 is complete when `m2c1-smoke.sh` exits 0 from a clean boot.**

---

## Self-Review

**Spec coverage** (M2c-1 scope of `2026-07-09-m2c-full-...-design.md`):
- rhino-SQLite on the persistent STATE partition → Task 1. ✓
- PHP DaemonSet, 3 workers, none on node-1, distinct per-node IPs → Tasks 2, 5(check 1). ✓
- ClusterIP Service load-balancing → Tasks 2, 5(check 2). ✓
- Durability (state survives node-1 restart) → Tasks 3, 5(check 3). ✓
- Per-node/per-application memory + node-1 CP total vs 512 → Task 5(check 4) + memreport. ✓
- No OOM → Task 5(check 5). ✓
- No `kubectl exec` in gates → all in-cluster checks are probe pods. ✓

**Placeholder scan:** the memreport (Task 5 Step 2) is specified as a copy of M2b's proven memprobe machinery with one named `case`-list change + one appended total line, rather than reproducing ~40 lines verbatim — the exact edit is given. No `TODO`/`TBD`.

**Type/name consistency:** workload label `app=php-web`, Service `web` (ns default), ConfigMap `php-index`, image `10.88.0.1:5000/php:8.4-apache`, DB path `/system/state/rusternetes/state.db`, restart helper `scripts/m2c-restart-node1.sh` — consistent across Tasks 1-6.

**Durability caveat to watch (Task 5 step 2 covers it):** the uid-identity assertion assumes the control-plane restart does not cause kubelet to recreate the php-web pods. On workers (which never restart) the pods keep running; their uids are stored in rhino and should reload unchanged. If rusternetes/kubelet legitimately re-creates pods on CP reconnect, relax to Running-existence.

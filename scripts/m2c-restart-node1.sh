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
  --disk path="$node_dir/m2b.img",image_type=raw path="$node_dir/state.img",image_type=raw \
  --net "tap=mkn0,mac=52:55:00:88:00:02" \
  --serial tty --console off --api-socket "$node_dir/ch.sock" \
  >> "$serial" 2>&1 &
newpid="$!"
echo "$newpid" > "$node_dir/ch.pid"
sleep 1
kill -0 "$newpid" >/dev/null 2>&1 || { tail -30 "$serial" >&2; echo "ERROR: node-1 CH exited during relaunch" >&2; exit 1; }

say "waiting for node-1 API to return"
kc() { kubectl --server "https://10.88.0.2:6443" --insecure-skip-tls-verify --token dummy "$@"; }
ok=0
for _ in $(seq 1 96); do
  [ "$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && ok=1 && break
  sleep 5
done
[ "$ok" = 1 ] || { tail -30 "$serial"; echo "ERROR: node-1 did not return Ready" >&2; exit 1; }
say "node-1 back Ready"

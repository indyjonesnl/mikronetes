#!/usr/bin/env bash
# Boot the four-node M2b microVM cluster under QEMU or Cloud Hypervisor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${OUT:-$REPO_ROOT/out/m2b}"
BACKEND="${BACKEND:-qemu}"
MEM="${MEM:-512}"
CONTROL_PLANE_MEM="${CONTROL_PLANE_MEM:-${CP_MEM:-$MEM}}"
if [ -z "${CH_BIN:-}" ] && [ -x /usr/local/bin/cloud-hypervisor ]; then
  CH_BIN="/usr/local/bin/cloud-hypervisor"
else
  CH_BIN="${CH_BIN:-$OUT/cloud-hypervisor}"
fi

KERNEL="$OUT/boot/vmlinuz"
INITRD="$OUT/boot/initramfs.img"
CMDLINE="console=ttyS0 root=/dev/ram0 rw"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$KERNEL" ] || die "kernel not found: $KERNEL; run scripts/m2b-build-images.sh"
[ -f "$INITRD" ] || die "initramfs not found: $INITRD; run scripts/m2b-build-images.sh"
for node in node-1 node-2 node-3 node-4; do
  [ -f "$OUT/$node/m2b.img" ] || die "image not found: $OUT/$node/m2b.img"
done

ensure_taps_free() {
  local busy=0
  local tap
  for tap in mkn0 mkn1 mkn2 mkn3; do
    if pgrep -af "qemu-system-x86_64 .*ifname=${tap}|cloud-hypervisor .*tap=${tap}" >/dev/null 2>&1; then
      echo "ERROR: tap $tap is already owned by a running VM:" >&2
      pgrep -af "qemu-system-x86_64 .*ifname=${tap}|cloud-hypervisor .*tap=${tap}" >&2 || true
      busy=1
    fi
  done
  [ "$busy" = 0 ] || die "stop the stale VM(s) before starting M2b"
}

ensure_taps_free

bash "$SCRIPT_DIR/m2b-net.sh"

launch_qemu() {
  local node="$1" tap="$2" mac="$3"
  local node_dir="$OUT/$node"
  local serial="$node_dir/serial.log"
  local mem="$MEM"
  [ "$node" = node-1 ] && mem="$CONTROL_PLANE_MEM"
  mkdir -p "$node_dir"
  [ -f "$node_dir/state.img" ] || truncate -s 2G "$node_dir/state.img"
  rm -f "$node_dir/ch.sock"
  : > "$serial"
  local kvm=""
  [ -w /dev/kvm ] && kvm="-enable-kvm -cpu host"
  say "launching $node with QEMU (mem=${mem}MiB, tap=$tap, serial=$serial)"
  # shellcheck disable=SC2086
  qemu-system-x86_64 $kvm \
    -m "$mem" -smp 2 -machine q35 \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "$CMDLINE" \
    -drive file="$node_dir/m2b.img",if=virtio,format=raw,index=0 \
    -drive file="$node_dir/state.img",if=virtio,format=raw,index=1 \
    -netdev tap,id=n0,ifname="$tap",script=no,downscript=no \
    -device virtio-net-pci,netdev=n0,mac="$mac" \
    -display none \
    -serial "file:$serial" \
    -daemonize
}

launch_ch() {
  local node="$1" tap="$2" mac="$3"
  local node_dir="$OUT/$node"
  local serial="$node_dir/serial.log"
  local mem="$MEM"
  [ "$node" = node-1 ] && mem="$CONTROL_PLANE_MEM"
  mkdir -p "$node_dir"
  [ -f "$node_dir/state.img" ] || truncate -s 2G "$node_dir/state.img"
  rm -f "$node_dir/ch.sock"
  : > "$serial"
  [ -w /dev/kvm ] || die "cloud-hypervisor requires /dev/kvm"
  if [ ! -x "$CH_BIN" ]; then
    say "downloading cloud-hypervisor v52.0 to $CH_BIN"
    curl -fsSL -o "$CH_BIN" \
      "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v52.0/cloud-hypervisor-static"
    chmod +x "$CH_BIN"
  fi
  say "launching $node with Cloud Hypervisor (mem=${mem}MiB, tap=$tap, serial=$serial)"
  nohup setsid "$CH_BIN" \
    --kernel "$KERNEL" \
    --initramfs "$INITRD" \
    --cmdline "$CMDLINE" \
    --memory size="${mem}M" \
    --cpus boot=2 \
    --disk path="$node_dir/m2b.img" path="$node_dir/state.img" \
    --net "tap=$tap,mac=$mac" \
    --serial tty \
    --console off \
    --api-socket "$node_dir/ch.sock" \
    >> "$serial" 2>&1 &
  local pid="$!"
  echo "$pid" > "$node_dir/ch.pid"
  sleep 1
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    tail -40 "$serial" >&2 || true
    die "$node Cloud Hypervisor exited during launch"
  fi
}

case "$BACKEND" in
  qemu)
    launch_qemu node-1 mkn0 52:55:00:88:00:02
    launch_qemu node-2 mkn1 52:55:00:88:00:03
    launch_qemu node-3 mkn2 52:55:00:88:00:04
    launch_qemu node-4 mkn3 52:55:00:88:00:05
    ;;
  ch)
    launch_ch node-1 mkn0 52:55:00:88:00:02
    launch_ch node-2 mkn1 52:55:00:88:00:03
    launch_ch node-3 mkn2 52:55:00:88:00:04
    launch_ch node-4 mkn3 52:55:00:88:00:05
    ;;
  *)
    die "unknown BACKEND '$BACKEND' (supported: qemu | ch)"
    ;;
esac

kc() { kubectl --server "https://10.88.0.2:6443" --insecure-skip-tls-verify --token dummy "$@"; }

say "waiting for node-1 API and Ready condition (up to ~8m)"
ok=0
for _ in $(seq 1 96); do
  st=$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo)
  if [ "$st" = True ]; then ok=1; break; fi
  sleep 5
done

if [ "$ok" != 1 ]; then
  tail -50 "$OUT/node-1/serial.log"
  die "node-1 not Ready after 8m"
fi

say "node-1 Ready; waiting for worker nodes to register"
for node in node-2 node-3 node-4; do
  ok=0
  for _ in $(seq 1 72); do
    st=$(kc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo)
    if [ "$st" = True ]; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] || die "$node not Ready"
done

kc get nodes -o wide
say "next: scripts/m2b-bootstrap.sh then scripts/m2b-smoke.sh"

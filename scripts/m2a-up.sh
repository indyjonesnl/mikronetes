#!/usr/bin/env bash
# M2a single-node microVM boot harness.
#
# Brings up the M2a image (machined as PID 1, supervising containerd-rs +
# rusternetes all-in-one) in a 512 MiB QEMU or cloud-hypervisor VM, then
# waits until node-1 reports Ready via the Kubernetes API.
#
# Usage:
#   bash scripts/m2a-up.sh              # BACKEND=qemu (default)
#   BACKEND=ch bash scripts/m2a-up.sh  # cloud-hypervisor
#
# Env overrides:
#   BACKEND   qemu | ch (default: qemu)
#   OUT       output dir (default: <repo-root>/out)
#   TAP       tap interface name (default: mkn0)
#   CH_BIN    path to cloud-hypervisor binary (default: OUT/cloud-hypervisor)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$(cd "$SCRIPT_DIR/.." && pwd)/out}"
BACKEND="${BACKEND:-qemu}"
TAP="${TAP:-mkn0}"

KERNEL="$OUT/boot/vmlinuz"
INITRD="$OUT/boot/initramfs.img"
IMG="$OUT/m2a.img"
SERIAL="$OUT/serial.log"
MAC="52:55:00:88:00:02"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Verify image artifacts exist before touching the network.
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL — run scripts/m2a-build-image.sh"
[ -f "$INITRD" ] || die "initramfs not found: $INITRD — run scripts/m2a-build-image.sh"
[ -f "$IMG"    ] || die "disk image not found: $IMG — run scripts/m2a-build-image.sh"

# Blank state disk (2 GiB sparse); machined provisions STATE + EPHEMERAL on vdb.
[ -f "$OUT/state.img" ] || truncate -s 2G "$OUT/state.img"

# Bridge + tap (idempotent).
bash "$SCRIPT_DIR/m2a-net.sh"

# Truncate the serial log for this run.
: > "$SERIAL"

# machined boots from the initramfs (machined is /init); it then scans block
# devices for the EFI-labeled GPT partition on vda and mounts it at /boot.
# root=/dev/ram0 is a no-op hint — the real root is the initramfs itself.
CMDLINE="console=ttyS0 root=/dev/ram0 rw"

case "$BACKEND" in
  qemu)
    KVM=""
    [ -w /dev/kvm ] && KVM="-enable-kvm -cpu host"
    say "launching QEMU (backend=qemu, KVM=$([ -n "$KVM" ] && echo on || echo off), serial=$SERIAL)"
    # shellcheck disable=SC2086  # KVM is an intentional word-split flag list.
    qemu-system-x86_64 $KVM \
      -m 512 -smp 2 -machine q35 \
      -kernel "$KERNEL" -initrd "$INITRD" \
      -append "$CMDLINE" \
      -drive file="$IMG",if=virtio,format=raw,index=0 \
      -drive file="$OUT/state.img",if=virtio,format=raw,index=1 \
      -netdev tap,id=n0,ifname="$TAP",script=no,downscript=no \
      -device virtio-net-pci,netdev=n0,mac="$MAC" \
      -display none \
      -serial "file:$SERIAL" \
      -daemonize
    ;;

  ch)
    [ -w /dev/kvm ] || die "cloud-hypervisor requires /dev/kvm"
    CH="${CH_BIN:-$OUT/cloud-hypervisor}"
    if [ ! -x "$CH" ]; then
      say "downloading cloud-hypervisor v52.0 to $CH"
      curl -fsSL -o "$CH" \
        "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v52.0/cloud-hypervisor-static"
      chmod +x "$CH"
    fi
    say "launching cloud-hypervisor (backend=ch, serial=$SERIAL)"
    "$CH" \
      --kernel "$KERNEL" \
      --initramfs "$INITRD" \
      --cmdline "$CMDLINE" \
      --memory size=512M \
      --cpus boot=2 \
      --disk path="$IMG" path="$OUT/state.img" \
      --net "tap=$TAP,mac=$MAC" \
      --serial tty \
      --console off \
      --api-socket "$OUT/ch.sock" \
      >> "$SERIAL" 2>&1 &
    echo "$!" > "$OUT/ch.pid"
    say "cloud-hypervisor PID $(cat "$OUT/ch.pid")"
    ;;

  *)
    die "unknown backend '$BACKEND' (supported: qemu | ch)"
    ;;
esac

# Convergence gate: poll until node-1 reports Ready via the Kubernetes API.
# api-server listens at https://10.88.0.2:6443; --skip-auth accepts any token.
VMIP=10.88.0.2
kc() { kubectl --server "https://$VMIP:6443" --insecure-skip-tls-verify --token dummy "$@"; }

say "waiting for node-1 Ready (up to ~8m; check $SERIAL for progress)"
ok=0
for _ in $(seq 1 96); do
  st=$(kc get node node-1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo)
  if [ "$st" = True ]; then ok=1; break; fi
  sleep 5
done

if [ "$ok" != 1 ]; then
  echo "---- serial tail (last 50 lines) ----"
  tail -50 "$SERIAL"
  die "node-1 not Ready after 8m (serial: $SERIAL)"
fi

say "node-1 Ready."
kc get node node-1 -o wide
say "next: scripts/m2a-smoke.sh"

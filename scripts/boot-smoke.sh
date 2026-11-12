#!/usr/bin/env bash
# Boot smoke test: boot the installed kernel in QEMU with a minimal
# initramfs and require a marker on the serial console. This proves the
# kernel image boots; it is not a full-OS boot.
set -u

BOOT_DIR=${BOOT_SMOKE_BOOT_DIR:-/boot}
QEMU=${BOOT_SMOKE_QEMU:-qemu-system-x86_64}
CC=${BOOT_SMOKE_CC:-cc}
TIMEOUT=${BOOT_SMOKE_TIMEOUT:-180}
VERSION=

usage() {
  cat <<'EOF'
Usage: boot-smoke.sh [options]

Boot the installed kernel in QEMU with a minimal initramfs and check for
BOOT_SMOKE_OK on the serial console.

  --version, -k VERSION  kernel version to boot (default: the only
                         /boot/vmlinuz-* in the boot directory)
  --timeout SECONDS      boot timeout (default: 180)
  --help, -h             show this help

Environment:
  BOOT_SMOKE_BOOT_DIR    directory containing vmlinuz-*/config-* (default: /boot)
  BOOT_SMOKE_QEMU        QEMU binary (default: qemu-system-x86_64)
  BOOT_SMOKE_CC          C compiler for the static init (default: cc)
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version | -k)
      [ $# -ge 2 ] || die "$1 requires a kernel version"
      VERSION=$2
      shift 2
      ;;
    --timeout)
      [ $# -ge 2 ] || die "--timeout requires a number of seconds"
      TIMEOUT=$2
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

case "$TIMEOUT" in
  '' | *[!0-9]*) die "--timeout must be a positive integer" ;;
esac
[ "$TIMEOUT" -gt 0 ] || die "--timeout must be greater than zero"

require_tool "$QEMU"
require_tool "$CC"
require_tool cpio
require_tool mknod

if [ -n "$VERSION" ]; then
  kernel="$BOOT_DIR/vmlinuz-$VERSION"
  config="$BOOT_DIR/config-$VERSION"
  [ -f "$kernel" ] || die "kernel not found: $kernel"
else
  mapfile -t kernels < <(find "$BOOT_DIR" -maxdepth 1 -type f -name 'vmlinuz-*' | sort)
  [ "${#kernels[@]}" -gt 0 ] || die "no kernel found in $BOOT_DIR (use --version)"
  [ "${#kernels[@]}" -eq 1 ] || die "multiple kernels found in $BOOT_DIR; use --version"
  kernel=${kernels[0]}
  VERSION=${kernel##*/vmlinuz-}
  config="$BOOT_DIR/config-$VERSION"
fi
[ -f "$config" ] || die "config not found: $config"

# The success marker is only visible on the serial console.
for opt in CONFIG_SERIAL_8250=y CONFIG_SERIAL_8250_CONSOLE=y CONFIG_BLK_DEV_INITRD=y; do
  grep -qx "$opt" "$config" || die "$config lacks $opt; cannot run the serial boot smoke"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/boot-smoke.XXXXXX") || die "could not create a temporary directory"
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

cat > "$work/init.c" <<'EOF'
#include <sys/mount.h>
#include <sys/reboot.h>
#include <unistd.h>
#include <stdio.h>

int main(void)
{
    mount("proc", "/proc", "proc", 0, 0);
    mount("sysfs", "/sys", "sysfs", 0, 0);
    mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
    puts("BOOT_SMOKE_OK");
    fflush(stdout);
    sleep(1);
    reboot(RB_POWER_OFF);
    for (;;) {
        pause();
    }
    return 0;
}
EOF

"$CC" -static -Os -o "$work/init" "$work/init.c" || die "could not build the static init"
mkdir -p "$work/root"/dev "$work/root"/proc "$work/root"/sys
cp "$work/init" "$work/root/init"
chmod 0755 "$work/root/init"
mknod -m 600 "$work/root/dev/console" c 5 1 || die "could not create /dev/console"
mknod -m 666 "$work/root/dev/null" c 1 3 || die "could not create /dev/null"
if ! ( cd "$work/root" && find . -print0 | cpio --null -o --format=newc ) > "$work/initramfs.cpio" 2>/dev/null; then
  die "could not build the initramfs"
fi

serial="$work/serial.log"
start=$(date +%s)
timeout "$TIMEOUT" "$QEMU" \
  -machine pc,accel=tcg \
  -cpu max \
  -m 1024 \
  -smp 2 \
  -kernel "$kernel" \
  -initrd "$work/initramfs.cpio" \
  -append "console=ttyS0,115200 earlycon=uart,io,0x3f8,115200n8 rdinit=/init panic=30" \
  -display none \
  -no-reboot \
  -monitor none \
  -serial "file:$serial" &
qemu_pid=$!

booted=0
for _ in $(seq 1 "$TIMEOUT"); do
  if grep -q "BOOT_SMOKE_OK" "$serial" 2>/dev/null; then
    booted=1
    break
  fi
  kill -0 "$qemu_pid" 2>/dev/null || break
  sleep 1
done

if [ "$booted" -eq 1 ]; then
  kill "$qemu_pid" 2>/dev/null || true
fi
wait "$qemu_pid" 2>/dev/null || true
elapsed=$(( $(date +%s) - start ))

if [ -f "$serial" ]; then
  cat "$serial"
fi
if [ "$booted" -ne 1 ]; then
  die "kernel $VERSION did not reach BOOT_SMOKE_OK within ${TIMEOUT}s"
fi
echo "Boot smoke OK: $VERSION (${elapsed}s)"

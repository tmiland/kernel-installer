#!/usr/bin/env bash
# Boot smoke harness: builds a minimal initramfs and runs QEMU. These tests
# fake only the host tools (cc, mknod, cpio, qemu) so the control flow and
# argument/config validation run for real.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/scripts/boot-smoke.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: scripts/boot-smoke.sh not found"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/boot"

# A tiny fake compiler: the real script only needs a file at -o <path>.
cat > "$work/bin/cc" <<'EOF'
#!/usr/bin/env bash
out=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
printf '#!/bin/sh\necho fake init\n' > "$out"
EOF
# Device nodes are only needed by the real kernel; the fake harness just
# needs the script to proceed without root.
cat > "$work/bin/mknod" <<'EOF'
#!/usr/bin/env bash
for last; do :; done
touch "$last"
EOF
# The test does not inspect the archive; the fake QEMU ignores it.
cat > "$work/bin/cpio" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
# Fake QEMU: write the marker to the -serial file and exit.
cat > "$work/bin/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
serial=
while [ $# -gt 0 ]; do
  case "$1" in
    -serial) serial=${2#file:}; shift 2 ;;
    *) shift ;;
  esac
done
printf 'BOOT_SMOKE_OK\n' > "$serial"
exit 0
EOF
chmod +x "$work/bin/cc" "$work/bin/mknod" "$work/bin/cpio" "$work/bin/qemu-system-x86_64"

printf 'CONFIG_SERIAL_8250=y\nCONFIG_SERIAL_8250_CONSOLE=y\nCONFIG_BLK_DEV_INITRD=y\n' > "$work/boot/config-6.12.112"
: > "$work/boot/vmlinuz-6.12.112"

run_boot() {
  PATH="$work/bin:$PATH" BOOT_SMOKE_BOOT_DIR="$work/boot" bash "$SCRIPT" "$@"
}

out=$(run_boot --version 6.12.112 --timeout 10 2>&1)
rc=$?
check "explicit version boots and reports success" test "$rc" -eq 0
check "success message includes the version" grep -q 'Boot smoke OK: 6.12.112' <<<"$out"

out=$(PATH="$work/bin:$PATH" BOOT_SMOKE_BOOT_DIR="$work/boot" bash "$SCRIPT" --timeout 10 2>&1)
check "single installed kernel is auto-detected" test "$?" -eq 0

out=$(run_boot --version 9.9.9 --timeout 10 2>&1)
check "missing kernel version fails" test "$?" -ne 0
check "missing kernel error is clear" grep -q 'not found' <<<"$out"

cp "$work/boot/vmlinuz-6.12.112" "$work/boot/vmlinuz-6.12.113"
out=$(PATH="$work/bin:$PATH" BOOT_SMOKE_BOOT_DIR="$work/boot" bash "$SCRIPT" --timeout 10 2>&1)
check "multiple kernels require --version" test "$?" -ne 0
check "multiple-kernel error is clear" grep -q 'multiple' <<<"$out"

out=$(PATH="$work/bin:$PATH" BOOT_SMOKE_BOOT_DIR="$work/boot" bash "$SCRIPT" --help 2>&1)
check "--help succeeds" test "$?" -eq 0
check "--help documents --version" grep -q -- '--version' <<<"$out"

exit "$fail"

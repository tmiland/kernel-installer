#!/usr/bin/env bash
# --kexec must load the new kernel (kexec -l) before `systemctl kexec`, which
# refuses to run without a loaded kernel on GRUB systems, and a kexec failure
# must not turn a successful install into "installation returned an error".
# Runs kexec_new_kernel from kernel_installer.sh against stub kexec/systemctl.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
# check <description> <command...>: the check passes when the command does
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

func=$(sed -n '/^kexec_new_kernel() {/,/^}/p' "$SCRIPT" | sed "s#/boot/#$work/boot/#g")
if [ -z "$func" ]; then
  echo "FAIL: kexec_new_kernel() not found in kernel_installer.sh"
  exit 1
fi

mkdir -p "$work/shim" "$work/boot"
for cmd in kexec systemctl; do
  cat > "$work/shim/$cmd" <<EOF
#!/bin/sh
echo "$cmd \$*" >> "$work/calls"
exit \${STUB_${cmd^^}_RC:-0}
EOF
  chmod +x "$work/shim/$cmd"
done

# run_case <distro group> <create initrd: 0|1> <kexec rc> <systemctl rc> [PATH]
run_case() {
  rm -f "$work/calls" "$work/log" "$work/boot/"*
  : > "$work/boot/vmlinuz-7.3.0-rc7"
  if [ "$2" = 1 ]; then
    if [ "$1" = RHEL ]; then : > "$work/boot/initramfs-7.3.0-rc7.img"; else : > "$work/boot/initrd.img-7.3.0-rc7"; fi
  fi
  (
    export PATH=${5:-"$work/shim:/usr/bin:/bin"} STUB_KEXEC_RC=$3 STUB_SYSTEMCTL_RC=$4
    # The globals and stubs below are used by the eval'd kexec_new_kernel
    # shellcheck disable=SC2034
    DISTRO_GROUP=$1
    # shellcheck disable=SC2034
    INSTALL="echo install"
    # shellcheck disable=SC2329
    log_info() { echo "INFO $1" >> "$work/log"; }
    # shellcheck disable=SC2329
    log_error() { echo "ERROR $1" >> "$work/log"; }
    # shellcheck disable=SC2329
    run_ok() { echo "run_ok $1" >> "$work/calls"; }
    eval "$func"
    kexec_new_kernel 7.3.0-rc7
  )
}
B=$work/boot

run_case Debian 1 0 0; rc=$?
check "Debian: returns 0" test "$rc" -eq 0
check "Debian: kexec -l loads the new image with its initrd.img and the current cmdline" \
  grep -qxF "kexec -l $B/vmlinuz-7.3.0-rc7 --reuse-cmdline --initrd=$B/initrd.img-7.3.0-rc7" "$work/calls"
check "Debian: kexec -l runs before systemctl kexec" \
  test "$(grep -E '^(kexec -l|systemctl kexec)' "$work/calls" | cut -d' ' -f1-2 | tr '\n' ' ')" = "kexec -l systemctl kexec "

run_case RHEL 1 0 0; rc=$?
check "RHEL: returns 0" test "$rc" -eq 0
check "RHEL: kexec -l uses initramfs-<release>.img" \
  grep -qxF "kexec -l $B/vmlinuz-7.3.0-rc7 --reuse-cmdline --initrd=$B/initramfs-7.3.0-rc7.img" "$work/calls"

run_case Debian 0 0 0
check "no initrd: kexec -l without --initrd" grep -qxF "kexec -l $B/vmlinuz-7.3.0-rc7 --reuse-cmdline" "$work/calls"

run_case Debian 1 1 0; rc=$?
check "kexec -l fails: still returns 0 (kernel is installed)" test "$rc" -eq 0
check "kexec -l fails: systemctl kexec is not called" not grep -q '^systemctl' "$work/calls"
check "kexec -l fails: tells the user to reboot" grep -q '^ERROR .*reboot to use it' "$work/log"

run_case Debian 1 0 1; rc=$?
check "systemctl kexec fails: still returns 0" test "$rc" -eq 0
check "systemctl kexec fails: reported" grep -q '^ERROR .*systemctl kexec failed' "$work/log"

mv "$work/shim/kexec" "$work/shim/kexec.real"
# (the stub run_ok installs nothing, so the following kexec call fails)
run_case Debian 1 0 0 "$work/shim:/usr/bin:/bin" 2>/dev/null
check "kexec missing: kexec-tools is installed first" grep -q '^run_ok echo install kexec-tools' "$work/calls"
mv "$work/shim/kexec.real" "$work/shim/kexec"

# Call site: install_kernel must use kexec_new_kernel, and nothing else may
# call systemctl kexec directly.
body=$(sed -n '/^install_kernel() {/,/^}/p' "$SCRIPT")
# shellcheck disable=SC2016  # matching the literal text "$LINUX_FULL_VER"
check 'install_kernel calls kexec_new_kernel "$LINUX_FULL_VER"' grep -qF 'kexec_new_kernel "$LINUX_FULL_VER"' <<<"$body"
calls_re='^[[:space:]]*(if ! )?systemctl kexec'
check "systemctl kexec is only called from kexec_new_kernel" \
  test "$(grep -cE "$calls_re" "$SCRIPT")" = "$(grep -cE "$calls_re" <<<"$func")"

exit "$fail"

#!/usr/bin/env bash
# --uninstall and the "already installed" check looked packages up by the
# kernel.org version (7.3-rc7), but packages are named after the kernel
# release (7.3.0-rc7; rpm version 7.3.0_rc7), so they never matched.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

funcs=$(sed -n -e '/^kernel_release() {/,/^}/p' -e '/^installed_kernel_pkg() {/,/^}/p' "$SCRIPT")
if ! grep -q '^kernel_release() {' <<<"$funcs" || ! grep -q '^installed_kernel_pkg() {' <<<"$funcs"; then
  echo "FAIL: kernel_release() / installed_kernel_pkg() not found in kernel_installer.sh"
  exit 1
fi
eval "$funcs"

# kernel.org version -> kernel release
while read -r version expected; do
  check "kernel_release $version = $expected" test "$(kernel_release "$version")" = "$expected"
done <<'EOF'
7.3-rc7 7.3.0-rc7
7.3 7.3.0
10.1 10.1.0
6.12.113 6.12.113
7.3.1-rc2 7.3.1-rc2
7.0.0-38-generic 7.0.0-38-generic
6.17.1-300.fc44.x86_64 6.17.1-300.fc44.x86_64
EOF

# installed_kernel_pkg against a fake package database
# PKGCHK and DISTRO_GROUP are read by the eval'd functions
# shellcheck disable=SC2329
fake_pkgchk() { grep -qxF "$1" "$work/installed"; }
# shellcheck disable=SC2034
PKGCHK=fake_pkgchk

# shellcheck disable=SC2034
DISTRO_GROUP=Debian
printf '%s\n' linux-image-7.3.0-rc7 linux-headers-7.3.0-rc7 linux-image-7.0.0-38-generic > "$work/installed"
check "Debian: linux-image for 7.3-rc7 is linux-image-7.3.0-rc7" \
  test "$(installed_kernel_pkg linux-image "$(kernel_release 7.3-rc7)")" = linux-image-7.3.0-rc7
check "Debian: linux-headers for 7.3-rc7 is linux-headers-7.3.0-rc7" \
  test "$(installed_kernel_pkg linux-headers "$(kernel_release 7.3-rc7)")" = linux-headers-7.3.0-rc7
check "Debian: distro kernel 7.0.0-38-generic still found" \
  test "$(installed_kernel_pkg linux-image "$(kernel_release 7.0.0-38-generic)")" = linux-image-7.0.0-38-generic
check "Debian: a kernel that is not installed is not found" \
  not installed_kernel_pkg linux-image "$(kernel_release 9.9.9)"

# shellcheck disable=SC2034
DISTRO_GROUP=RHEL
printf '%s\n' kernel-7.3.0_rc7 kernel-devel-7.3.0_rc7 kernel-6.17.1-300.fc44.x86_64 > "$work/installed"
check "RHEL: kernel for 7.3-rc7 is kernel-7.3.0_rc7 (binrpm-pkg version)" \
  test "$(installed_kernel_pkg kernel "$(kernel_release 7.3-rc7)")" = kernel-7.3.0_rc7
check "RHEL: kernel-devel for 7.3-rc7 is kernel-devel-7.3.0_rc7" \
  test "$(installed_kernel_pkg kernel-devel "$(kernel_release 7.3-rc7)")" = kernel-devel-7.3.0_rc7
check "RHEL: distro kernel 6.17.1-300.fc44.x86_64 still found with its - intact" \
  test "$(installed_kernel_pkg kernel "$(kernel_release 6.17.1-300.fc44.x86_64)")" = kernel-6.17.1-300.fc44.x86_64

# Call sites (patterns below are literal script text, hence single quotes)
# shellcheck disable=SC2016
uninstall=$(sed -n '/^if \[ "\$mode" = "uninstall" \]; then/,/^fi$/p' "$SCRIPT")
chk=$(sed -n '/^chk_kernel() {/,/^}/p' "$SCRIPT")
# shellcheck disable=SC2016
check "uninstall maps LINUX_VER with kernel_release" grep -qF 'kernel_release "$LINUX_VER"' <<<"$uninstall"
check "uninstall looks packages up with installed_kernel_pkg" grep -q 'installed_kernel_pkg' <<<"$uninstall"
# shellcheck disable=SC2016
check 'uninstall no longer builds package names from raw "${LINUX_VER}"' \
  not grep -qF -- '-"${LINUX_VER}"' <<<"$uninstall"
# shellcheck disable=SC2016
check "chk_kernel maps LINUX_VER with kernel_release" grep -qF 'kernel_release "$LINUX_VER"' <<<"$chk"
check "chk_kernel looks the image up with installed_kernel_pkg" grep -q 'installed_kernel_pkg' <<<"$chk"

exit "$fail"

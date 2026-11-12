#!/usr/bin/env bash
# Regression: a missing install-dir parent must be created 0700, not with the
# root umask (002 -> 0775), otherwise the installer creates it and then
# rejects its own directory.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fatal() { echo "FATAL: $*" >&2; exit 1; }
INSTALL_DIR_MARKER=.kernel_installer
func=$(sed -n '/^prepare_install_dir() {/,/^}/p' "$SCRIPT")
[ -n "$func" ] || { echo "FAIL: prepare_install_dir() not found"; exit 1; }
eval "$func"

INSTALL_DIR="$work/new/linux-kernel"
prepare_install_dir
check "new parent is created 0700" test "$(stat -c '%a' "$work/new")" = 700
check "install dir is created 0755" test "$(stat -c '%a' "$INSTALL_DIR")" = 755
check "install dir marker exists" test -f "$INSTALL_DIR/$INSTALL_DIR_MARKER"

mkdir -p "$work/unsafe"
chmod 0775 "$work/unsafe"
out=$( ( INSTALL_DIR="$work/unsafe/linux-kernel"; prepare_install_dir ) 2>&1 )
check "an existing 0775 parent is still rejected" test "$?" -ne 0
check "the rejection suggests chmod 700" grep -q 'chmod 700' <<<"$out"

exit "$fail"

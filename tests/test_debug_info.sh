#!/usr/bin/env bash
# With an Ubuntu/Mint config, "disable debug info" did not stick (#41): the
# script set DEBUG_INFO_NONE=y but left DEBUG_INFO_DWARF5=y, two members of
# the "Debug information" choice at y, and olddefconfig kept DWARF5.
# Runs disable_debug_info against the kernel's real scripts/config and checks
# that exactly one member of the choice is left at y: DEBUG_INFO_NONE.
# Single-quoted "$..." patterns below are literal script text.
# shellcheck disable=SC2016
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

funcs=$(sed -n -e '/^disable_debug_info() {/,/^}/p' -e '/^versionToInt() {/,/^}/p' "$SCRIPT")
if ! grep -q '^disable_debug_info() {' <<<"$funcs"; then
  echo "FAIL: disable_debug_info() not found in kernel_installer.sh"
  exit 1
fi

tree="$work/linux"
mkdir -p "$tree/scripts"
if ! curl -fsSL --retry 2 -o "$tree/scripts/config" \
  'https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/scripts/config?h=v6.12.113'; then
  echo "FAIL: could not fetch scripts/config from git.kernel.org"
  exit 1
fi
chmod +x "$tree/scripts/config"

members='DEBUG_INFO_NONE DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT DEBUG_INFO_DWARF4 DEBUG_INFO_DWARF5'
# Members of the choice that are y after the run, space separated
members_at_y() {
  local m out=''
  for m in $members; do
    grep -qx "CONFIG_$m=y" "$tree/.config" && out="$out$m "
  done
  echo "$out"
}
# run_case <kernel version> <.config contents>
run_case() {
  printf '%s\n' "$2" > "$tree/.config"
  ( cd "$tree" || exit 1; eval "$funcs"; disable_debug_info "$1" )
}

# .config as olddefconfig writes it from Ubuntu's /boot config
ubuntu='CONFIG_DEBUG_INFO=y
# CONFIG_DEBUG_INFO_NONE is not set
# CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT is not set
# CONFIG_DEBUG_INFO_DWARF4 is not set
CONFIG_DEBUG_INFO_DWARF5=y
CONFIG_DEBUG_INFO_BTF=y'

run_case 6.12.113 "$ubuntu"
check "Ubuntu config (DWARF5): only DEBUG_INFO_NONE is left at y" test "$(members_at_y)" = "DEBUG_INFO_NONE "

run_case 6.12.113 "${ubuntu/CONFIG_DEBUG_INFO_DWARF5=y/# CONFIG_DEBUG_INFO_DWARF5 is not set}
CONFIG_DEBUG_INFO_DWARF4=y"
check "DWARF4 config: only DEBUG_INFO_NONE is left at y" test "$(members_at_y)" = "DEBUG_INFO_NONE "

run_case 6.12.113 'CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y'
check "toolchain-default config: only DEBUG_INFO_NONE is left at y" test "$(members_at_y)" = "DEBUG_INFO_NONE "

run_case 7.3-rc7 "$ubuntu"
check "mainline version string (7.3-rc7) takes the >= 5.18 path" test "$(members_at_y)" = "DEBUG_INFO_NONE "

run_case 5.15.190 'CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF5=y'
check "< 5.18: DEBUG_INFO is set to n" grep -qx 'CONFIG_DEBUG_INFO=n' "$tree/.config"

# Call site: still guarded by ENABLE_DEBUG_INFO=0 and given the version
body=$(sed -n '/^install_kernel() {/,/^}/p' "$SCRIPT")
check "install_kernel calls disable_debug_info \"\$LINUX_VER\" when ENABLE_DEBUG_INFO=0" \
  grep -qzE 'if \[ "\$ENABLE_DEBUG_INFO" = "0" \]; then[[:space:]]+disable_debug_info "\$LINUX_VER"' <<<"$body"

exit "$fail"

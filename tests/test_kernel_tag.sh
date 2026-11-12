#!/usr/bin/env bash
# Auto localversion tags and the explicit override.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
func=$(sed -n '/^build_kernel_tag() {/,/^}/p' "$SCRIPT")
[ -n "$func" ] || { echo "FAIL: build_kernel_tag() not found"; exit 1; }
eval "$func"
tag_for() {
  export SOURCE=$1 PROFILE=$2 KERNEL_SCHED=$3 CPU=$4 LTO=$5 KERNEL_TAG=${6:-}
  export HZ_OVERRIDE=${7:-} BBR3=${8:-0} BINDER=${9:-0} SCHED_EXT=${10:-0}
  build_kernel_tag
  printf '%s' "$KERNEL_TAG"
}

check "cachyos BORE workstation native thin" test "$(tag_for cachyos workstation bore native thin)" = "-cachyos-workstation-bore-native-lto"
check "vanilla desktop" test "$(tag_for vanilla desktop eevdf generic none)" = "-vanilla-desktop"
check "vanilla default stays untagged" test -z "$(tag_for vanilla '' eevdf generic none)"
check "cachyos no profile" test "$(tag_for cachyos '' eevdf generic none)" = "-cachyos"
check "config flags extend the tag" \
  test "$(tag_for cachyos workstation bore generic thin '' 600 1 1 1)" = "-cachyos-workstation-bore-lto-hz600-bbr3-binder-sched-ext"
check "hz alone names the kernel" test "$(tag_for vanilla '' eevdf generic none '' 1000)" = "-hz1000"
check "binder and sched-ext extend the tag" \
  test "$(tag_for vanilla workstation eevdf generic none '' '' 0 1 1)" = "-vanilla-workstation-binder-sched-ext"
check "explicit tag wins" test "$(tag_for cachyos workstation bore native thin mybox)" = "mybox"

exit "$fail"

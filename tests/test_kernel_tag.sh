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
  build_kernel_tag
  printf '%s' "$KERNEL_TAG"
}

check "cachyos BORE workstation native thin" test "$(tag_for cachyos workstation bore native thin)" = "-cachyos-workstation-bore-native-lto"
check "vanilla desktop" test "$(tag_for vanilla desktop eevdf generic none)" = "-vanilla-desktop"
check "vanilla default stays untagged" test -z "$(tag_for vanilla '' eevdf generic none)"
check "cachyos no profile" test "$(tag_for cachyos '' eevdf generic none)" = "-cachyos"
check "explicit tag wins" test "$(tag_for cachyos workstation bore native thin mybox)" = "mybox"

exit "$fail"

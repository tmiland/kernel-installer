#!/usr/bin/env bash
# LTO directives: none/thin/full.
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
mkdir -p "$work/scripts"
cat > "$work/scripts/config" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LTO_TEST_LOG:?}"
SH
chmod +x "$work/scripts/config"
export LTO_TEST_LOG="$work/calls"
cd "$work" || exit 1
func=$(sed -n '/^configure_lto() {/,/^}/p' "$SCRIPT")
[ -n "$func" ] || { echo "FAIL: configure_lto() not found"; exit 1; }
eval "$func"
run_lto() { : > "$LTO_TEST_LOG"; export LTO=$1; configure_lto; }
has() { grep -qx -- "$1" "$LTO_TEST_LOG"; }

run_lto thin
check "thin enables LTO_CLANG_THIN" has '--enable LTO_CLANG_THIN'
check "thin disables LTO_NONE" has '--disable LTO_NONE'

run_lto full
check "full enables LTO_CLANG_FULL" has '--enable LTO_CLANG_FULL'

run_lto none
check "none enables LTO_NONE" has '--enable LTO_NONE'

exit "$fail"

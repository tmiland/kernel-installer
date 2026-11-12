#!/usr/bin/env bash
# CPU tuning directives: generic/native/zen4/x86-64-v3/v4.
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
printf '%s\n' "$*" >> "${CPU_TEST_LOG:?}"
SH
chmod +x "$work/scripts/config"
export CPU_TEST_LOG="$work/calls"
cd "$work" || exit 1
func=$(sed -n '/^configure_cpu() {/,/^}/p' "$SCRIPT")
[ -n "$func" ] || { echo "FAIL: configure_cpu() not found"; exit 1; }
eval "$func"
run_cpu() { : > "$CPU_TEST_LOG"; export CPU=$1; export SOURCE=$2; configure_cpu; }
has() { grep -qx -- "$1" "$CPU_TEST_LOG"; }

run_cpu native vanilla
check "native enables X86_NATIVE_CPU" has '--enable X86_NATIVE_CPU'
check "native disables GENERIC_CPU" has '--disable GENERIC_CPU'

run_cpu zen4 cachyos
check "zen4 enables MZEN4" has '--enable MZEN4'
check "zen4 disables X86_NATIVE_CPU" has '--disable X86_NATIVE_CPU'

run_cpu x86-64-v3 cachyos
check "v3 enables GENERIC_CPU" has '--enable GENERIC_CPU'
check "v3 sets X86_64_VERSION 3" has '--set-val X86_64_VERSION 3'

run_cpu x86-64-v4 cachyos
check "v4 sets X86_64_VERSION 4" has '--set-val X86_64_VERSION 4'

run_cpu generic cachyos
check "generic enables GENERIC_CPU" has '--enable GENERIC_CPU'
check "generic sets X86_64_VERSION 1" has '--set-val X86_64_VERSION 1'

exit "$fail"

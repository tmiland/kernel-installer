#!/usr/bin/env bash
# Optimization profiles: directive generation, validation, base-config
# handling, and the order in which they are applied.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

block=$(sed -n '/^# --- Optimization profiles ---$/,/^# --- End optimization profiles ---$/p' "$SCRIPT")
if [ -z "$block" ]; then
  echo "FAIL: optimization profile block not found in kernel_installer.sh"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
log="$work/calls"

# Stub the kernel's scripts/config and record the directives the profiles ask
# for. The real profile_cfg wrapper still runs, so the test covers its calls.
# profiles call `scripts/config` relative to the kernel tree, so run from a
# fake tree that has one.
mkdir -p "$work/kernel/scripts"
cat > "$work/kernel/scripts/config" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PROFILE_TEST_LOG:?}"
exit 0
EOF
chmod +x "$work/kernel/scripts/config"
export PROFILE_TEST_LOG="$log"
cd "$work/kernel" || exit 1

# Shell-library stubs used by the extracted block.
fatal() { echo "FATAL: $*" >&2; return 1; }
log_info() { :; }
log_debug() { :; }
log_warning() { :; }

verfunc=$(sed -n '/^versionToInt() {/,/^}/p' "$SCRIPT")
if [ -z "$verfunc" ]; then
  echo "FAIL: versionToInt() not found in kernel_installer.sh"
  exit 1
fi
eval "$verfunc"
eval "$block"

export LINUX_VER=7.3.4
run_profile() {
  export PROFILE=${1#profile_}
  : > "$log"
  "$1"
}
has_call() { grep -qx -- "$1" "$log"; }

run_profile profile_desktop
check "desktop sets HZ 1000" has_call '--set-val HZ 1000'
check "desktop enables HZ_1000" has_call '--enable HZ_1000'
check "desktop enables full preempt" has_call '--enable PREEMPT'
check "desktop uses THP madvise" has_call '--enable TRANSPARENT_HUGEPAGE_MADVISE'
check "desktop enables MGLRU" has_call '--enable LRU_GEN'
check "desktop enables zram" has_call '--enable ZRAM'
check "desktop uses O2" has_call '--enable CC_OPTIMIZE_FOR_PERFORMANCE'

run_profile profile_workstation
check "workstation enables PSI" has_call '--enable PSI'
check "workstation enables cgroup CFS bandwidth" has_call '--enable CFS_BANDWIDTH'
check "workstation enables BBR as default" has_call '--enable DEFAULT_BBR'
check "workstation sets BBR congestion control" has_call '--set-str DEFAULT_TCP_CONG bbr'

run_profile profile_gaming
check "gaming sets HZ 1000" has_call '--set-val HZ 1000'
check "gaming enables full preempt" has_call '--enable PREEMPT'
check "gaming uses O2" has_call '--enable CC_OPTIMIZE_FOR_PERFORMANCE'

run_profile profile_server
check "server sets HZ 250" has_call '--set-val HZ 250'
check "server uses relaxed preemption" has_call '--enable PREEMPT_LAZY'
check "server keeps O2" has_call '--enable CC_OPTIMIZE_FOR_PERFORMANCE'
check "server sets NR_CPUS 256" has_call '--set-val NR_CPUS 256'
check "server enables BBR as default" has_call '--enable DEFAULT_BBR'
check "server sets BBR congestion control" has_call '--set-str DEFAULT_TCP_CONG bbr'

run_profile profile_laptop
check "laptop sets HZ 300" has_call '--set-val HZ 300'
check "laptop uses relaxed preemption" has_call '--enable PREEMPT_LAZY'
check "laptop enables schedutil" has_call '--enable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL'
check "laptop enables AMD P-state" has_call '--enable X86_AMD_PSTATE'
check "laptop enables the energy model" has_call '--enable ENERGY_MODEL'
check "laptop keeps O2" has_call '--enable CC_OPTIMIZE_FOR_PERFORMANCE'

run_profile profile_lowlatency
check "lowlatency keeps HZ 1000" has_call '--set-val HZ 1000'
check "lowlatency enables LATENCYTOP" has_call '--enable LATENCYTOP'

check "known profile names are valid" profile_is_valid workstation
check "unknown profile names are rejected" not profile_is_valid does-not-exist
check "applying an unknown profile fails" not apply_profile does-not-exist 2>/dev/null

listed=$(list_profiles)
check "list_profiles mentions workstation" grep -q 'workstation' <<<"$listed"
check "list_profiles mentions server" grep -q 'server' <<<"$listed"
check "list_profiles mentions laptop" grep -q 'laptop' <<<"$listed"

# Base-config handling
printf 'CONFIG_HZ=1000\n' > "$work/base.config"
mkdir -p "$work/tree"
( 
  cd "$work/tree" || exit 1
  export CONFIG_OPTION=olddefconfig
  export BASE_CONFIG="$work/base.config"
  prepare_base_config
  cmp -s "$work/base.config" .config
)
check "prepare_base_config copies an explicit path" test "$?" -eq 0

(
  cd "$work/tree" || exit 1
  rm -f .config
  export CONFIG_OPTION=olddefconfig
  export BASE_CONFIG=none
  prepare_base_config
  test ! -f .config
)
check "prepare_base_config none leaves the tree alone" test "$?" -eq 0

(
  cd "$work/tree" || exit 1
  export CONFIG_OPTION=olddefconfig
  export BASE_CONFIG="$work/missing.config"
  prepare_base_config
) 2>/dev/null
check "prepare_base_config rejects a missing path" test "$?" -ne 0

# Wiring: base config before make, profile before user overrides, then
# olddefconfig and the profile assertions.
body=$(sed -n '/^install_kernel() {/,/^}/p' "$SCRIPT")
line_of() { grep -n -- "$1" <<<"$body" | head -1 | cut -d: -f1; }
prep_line=$(line_of 'prepare_base_config')
make_line=$(line_of 'make $CONFIG_OPTION')
apply_line=$(line_of 'apply_profile "$PROFILE"')
custom_line=$(line_of 'for custom_config_option')
olddef_line=$(line_of 'make olddefconfig')
assert_line=$(line_of 'assert_profile "$PROFILE"')
check "base config is prepared before make" test -n "$prep_line" -a -n "$make_line" -a "$prep_line" -lt "$make_line"
check "profile is applied before --custom-config" test -n "$apply_line" -a -n "$custom_line" -a "$apply_line" -lt "$custom_line"
check "olddefconfig runs before the profile assertions" test -n "$olddef_line" -a -n "$assert_line" -a "$olddef_line" -lt "$assert_line"

# CLI surface (these exit before the root check).
out=$(setsid bash "$SCRIPT" -h </dev/null 2>&1)
check "help lists --profile" grep -q -- '--profile' <<<"$out"
check "help lists --base-config" grep -q -- '--base-config' <<<"$out"
out=$(setsid bash "$SCRIPT" --list-profiles </dev/null 2>&1)
check "--list-profiles prints the profile names" grep -q 'workstation' <<<"$out"

exit "$fail"

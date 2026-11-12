#!/usr/bin/env bash
# Config-surface flags: --hz, --bbr3, --binder, --sched-ext.
# shellcheck disable=SC2317  # helpers are invoked through eval'd script text
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2317,SC2329  # invoked through check
not() { ! "$@"; }

# --- CLI validation (before the root check) ------------------------------
out=$(setsid bash "$SCRIPT" --hz 500 </dev/null 2>&1)
check "--hz 500 without a CachyOS source is rejected" \
  grep -q 'requires --source cachyos' <<<"$out"

out=$(setsid bash "$SCRIPT" --hz 999 </dev/null 2>&1)
check "an unknown --hz value is rejected" grep -q 'Unknown --hz' <<<"$out"

out=$(setsid bash "$SCRIPT" --bbr3 </dev/null 2>&1)
check "--bbr3 without a CachyOS source is rejected" \
  grep -q 'requires --source cachyos' <<<"$out"

out=$(setsid bash "$SCRIPT" --help </dev/null 2>&1)
check "help documents --hz" grep -q -- '--hz' <<<"$out"
check "help documents --bbr3" grep -q -- '--bbr3' <<<"$out"
check "help documents --binder" grep -q -- '--binder' <<<"$out"
check "help documents --sched-ext" grep -q -- '--sched-ext' <<<"$out"

# --- configure/assert functions ------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts"
cat > "$work/scripts/config" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CFG_LOG:?}"
if [ "$1" = "--state" ]; then
  case "$2" in
    HZ) echo "${FAKE_HZ:-1000}" ;;
    HZ_600) echo "${FAKE_HZ600:-y}" ;;
    TCP_CONG_BBR3 | DEFAULT_BBR3 | ANDROID_BINDER_IPC | ANDROID_BINDERFS | SCHED_CLASS_EXT | DEBUG_INFO_BTF) echo y ;;
    DEFAULT_TCP_CONG) echo bbr3 ;;
    *) echo undef ;;
  esac
fi
exit 0
SH
chmod +x "$work/scripts/config"
export CFG_LOG="$work/calls"
cd "$work" || exit 1
# shellcheck disable=SC2317,SC2329  # invoked by the eval'd functions
fatal() { echo "FATAL: $*" >&2; return 1; }
log_debug() { :; }
log_info() { :; }
log_warning() { :; }

funcs=$(sed -n \
  -e '/^versionToInt() {/,/^}/p' \
  -e '/^configure_hz() {/,/^}/p' \
  -e '/^configure_bbr3() {/,/^}/p' \
  -e '/^configure_binder() {/,/^}/p' \
  -e '/^configure_sched_ext() {/,/^}/p' \
  -e '/^assert_hz() {/,/^}/p' \
  -e '/^assert_bbr3() {/,/^}/p' \
  -e '/^assert_binder() {/,/^}/p' \
  -e '/^assert_sched_ext() {/,/^}/p' \
  -e '/^assert_profile() {/,/^}/p' "$SCRIPT")
for fn in versionToInt configure_hz configure_bbr3 configure_binder configure_sched_ext \
  assert_hz assert_bbr3 assert_binder assert_sched_ext assert_profile; do
  grep -q "^${fn}() {" <<<"$funcs" || {
    echo "FAIL: ${fn}() not found in kernel_installer.sh"
    exit 1
  }
done
# shellcheck disable=SC1090
eval "$funcs"
export LINUX_VER=7.3.4
has() { grep -qx -- "$1" "$CFG_LOG"; }

: > "$CFG_LOG"
export HZ_OVERRIDE=600
configure_hz
check "hz 600 sets HZ" has '--set-val HZ 600'
check "hz 600 enables HZ_600" has '--enable HZ_600'
check "hz 600 disables HZ_1000" has '--disable HZ_1000'
check "hz 600 disables HZ_250" has '--disable HZ_250'
unset HZ_OVERRIDE

: > "$CFG_LOG"
export BBR3=1
configure_bbr3
check "bbr3 enables TCP_CONG_BBR3" has '--enable TCP_CONG_BBR3'
check "bbr3 enables DEFAULT_BBR3" has '--enable DEFAULT_BBR3'
check "bbr3 disables DEFAULT_BBR" has '--disable DEFAULT_BBR'
check "bbr3 sets DEFAULT_TCP_CONG" has '--set-str DEFAULT_TCP_CONG bbr3'
unset BBR3

: > "$CFG_LOG"
export BINDER=1
configure_binder
check "binder enables ANDROID_BINDER_IPC" has '--enable ANDROID_BINDER_IPC'
check "binder enables ANDROID_BINDERFS" has '--enable ANDROID_BINDERFS'
check "binder sets the device list" has '--set-str ANDROID_BINDER_DEVICES binder,hwbinder,vndbinder'
unset BINDER

: > "$CFG_LOG"
export SCHED_EXT=1
configure_sched_ext
check "sched-ext disables DEBUG_INFO_NONE" has '--disable DEBUG_INFO_NONE'
check "sched-ext enables DWARF5" has '--enable DEBUG_INFO_DWARF5'
check "sched-ext enables DEBUG_INFO_BTF" has '--enable DEBUG_INFO_BTF'
check "sched-ext enables SCHED_CLASS_EXT" has '--enable SCHED_CLASS_EXT'
check "sched-ext enables BPF_SYSCALL" has '--enable BPF_SYSCALL'
unset SCHED_EXT

: > "$CFG_LOG"
export HZ_OVERRIDE=600 BBR3=1 BINDER=1 SCHED_EXT=1 FAKE_HZ=600
if assert_hz && assert_bbr3 && assert_binder && assert_sched_ext; then
  ok=1
else
  ok=0
fi
check "assertions accept the configured values" test "$ok" = 1

# --- profile assertions follow the explicit overrides ---------------------
# shellcheck disable=SC2317  # stub for the eval'd function
profile_assert() { printf '%s\n' "$@" > "$work/profile-expect"; }
profile_kernel_ge() { return 1; }
export HZ_OVERRIDE=600 BBR3=1
assert_profile workstation
check "profile assertion expects the overridden HZ" grep -qx 'HZ=600' "$work/profile-expect"
check "profile assertion expects the overridden HZ choice" grep -qx 'HZ_600=y' "$work/profile-expect"
check "profile assertion expects BBR3" grep -qx 'DEFAULT_BBR3=y' "$work/profile-expect"
check "profile assertion expects the BBR3 default" grep -qx 'DEFAULT_TCP_CONG=bbr3' "$work/profile-expect"
check "profile assertion drops the BBR default" not grep -qx 'DEFAULT_BBR=y' "$work/profile-expect"
assert_profile lowlatency
check "lowlatency keeps its own assertion set" \
  not grep -qx 'TRANSPARENT_HUGEPAGE_MADVISE=y' "$work/profile-expect"
check "lowlatency still gets the HZ override" grep -qx 'HZ=600' "$work/profile-expect"

# --- call order ----------------------------------------------------------
line_of() { grep -n "$1" "$SCRIPT" | head -1 | cut -d: -f1; }
hz_call=$(line_of '^      configure_hz$')
# shellcheck disable=SC2016  # script text, not shell expansion
profile_call=$(line_of '^        apply_profile "\$PROFILE"$')
custom_call=$(line_of '^      for custom_config_option in')
olddef_call=$(line_of 'make olddefconfig" "Finalizing')
assert_call=$(line_of '^      assert_hz$')
check "hz is applied after the profile" test "$hz_call" -gt "$profile_call"
check "custom config is applied after the flags" test "$custom_call" -gt "$hz_call"
check "assertions run after olddefconfig" test "$assert_call" -gt "$olddef_call"

exit "$fail"

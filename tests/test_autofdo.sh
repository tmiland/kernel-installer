#!/usr/bin/env bash
# AutoFDO: CLI validation, config wiring, profile/vmlinux plumbing.
# shellcheck disable=SC2317  # helpers are invoked through check
# shellcheck disable=SC2016  # script text is matched with single quotes
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}

out=$(setsid bash "$SCRIPT" --autofdo </dev/null 2>&1)
check "--autofdo requires an argument" grep -q 'requires an argument' <<<"$out"

out=$(setsid bash "$SCRIPT" --autofdo /no/such/profile </dev/null 2>&1)
check "--autofdo rejects a missing profile" grep -q 'profile not found' <<<"$out"

out=$(setsid bash "$SCRIPT" --autofdo /etc/hostname --autofdo-collect </dev/null 2>&1)
check "--autofdo and --autofdo-collect are exclusive" \
  grep -q 'cannot be combined' <<<"$out"

out=$(setsid bash "$SCRIPT" --help </dev/null 2>&1)
check "help documents --autofdo" grep -q -- '--autofdo' <<<"$out"
check "help documents --autofdo-collect" grep -q -- '--autofdo-collect' <<<"$out"

# --- configure_autofdo ----------------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts"
cat > "$work/scripts/config" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AFDO_LOG:?}"
if [ "$1" = "--state" ] && [ "$2" = "AUTOFDO_CLANG" ]; then
  echo "${FAKE_AUTOFDO_STATE:-n}"
fi
exit 0
SH
chmod +x "$work/scripts/config"
export AFDO_LOG="$work/calls"
cd "$work" || exit 1
fatal() { echo "FATAL: $*" >&2; return 1; }
func=$(sed -n '/^configure_autofdo() {/,/^}/p' "$SCRIPT")
[ -n "$func" ] || { echo "FAIL: configure_autofdo() not found"; exit 1; }
# shellcheck disable=SC1090
eval "$func"
export AUTOFDO_COLLECT=1 AUTOFDO_PROFILE=''
: > "$AFDO_LOG"
configure_autofdo
check "autofdo enables AUTOFDO_CLANG" grep -qx -- '--enable AUTOFDO_CLANG' "$AFDO_LOG"

# --- build plumbing -------------------------------------------------------
check "the build exports CLANG_AUTOFDO_PROFILE" \
  grep -q 'export CLANG_AUTOFDO_PROFILE' "$SCRIPT"
check "the profile path is resolved with realpath" \
  grep -q 'realpath -- "$AUTOFDO_PROFILE"' "$SCRIPT"
check "the collect build preserves vmlinux" \
  grep -q 'AutoFDO vmlinux saved to' "$SCRIPT"
check "the collect build names the saved vmlinux after the release" \
  grep -q 'vmlinux-${LINUX_FULL_VER}' "$SCRIPT"

exit "$fail"

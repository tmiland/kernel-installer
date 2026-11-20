#!/usr/bin/env bash
# BMQ scheduler: pinned patch, configure wiring.
# shellcheck disable=SC2317  # helpers are invoked through check
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}

out=$(setsid bash "$SCRIPT" --sched bmq </dev/null 2>&1)
check "bmq without a CachyOS source is rejected" \
  grep -q 'requires --source cachyos' <<<"$out"

out=$(setsid bash "$SCRIPT" --help </dev/null 2>&1)
check "help documents bmq" grep -q -- 'bmq' <<<"$out"

# --- pinned patch ---------------------------------------------------------
# shellcheck disable=SC2016  # script text, not shell expansion
check "BMQ patch is the pinned 7.3 PRJC patch" \
  grep -qF '7.3/sched/0001-prjc-cachy.patch' "$SCRIPT"
check "BMQ patch SHA256 is pinned" \
  grep -q '^CACHYOS_BMQ_PATCH_SHA256=0d3c61ec' "$SCRIPT"
apply=$(sed -n '/^apply_cachyos_bmq_patch() {/,/^}/p' "$SCRIPT")
check "apply_cachyos_bmq_patch verifies the checksum" \
  grep -q 'CACHYOS_BMQ_PATCH_SHA256' <<<"$apply"
check "apply_cachyos_bmq_patch applies with patch -p1" \
  grep -q 'patch -p1' <<<"$apply"
check "apply_cachyos_bmq_patch is defined before its call site" \
  test "$(grep -n '^apply_cachyos_bmq_patch() {' "$SCRIPT" | cut -d: -f1)" \
    -lt "$(grep -n '^      apply_cachyos_bmq_patch$' "$SCRIPT" | cut -d: -f1)"

# --- configure_cachyos_source --------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts"
cat > "$work/scripts/config" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BMQ_LOG:?}"
exit 0
SH
chmod +x "$work/scripts/config"
export BMQ_LOG="$work/calls"
cd "$work" || exit 1
func=$(sed -n '/^configure_cachyos_source() {/,/^}/p' "$SCRIPT")
[ -n "$func" ] || { echo "FAIL: configure_cachyos_source() not found"; exit 1; }
# shellcheck disable=SC1090
eval "$func"
has() { grep -qx -- "$1" "$BMQ_LOG"; }

: > "$BMQ_LOG"
export SOURCE=cachyos KERNEL_SCHED=bmq
configure_cachyos_source
check "bmq enables CACHY" has '--enable CACHY'
check "bmq enables SCHED_ALT" has '--enable SCHED_ALT'
check "bmq enables SCHED_BMQ" has '--enable SCHED_BMQ'
check "bmq disables SCHED_PDS" has '--disable SCHED_PDS'
check "bmq disables SCHED_BORE" has '--disable SCHED_BORE'

: > "$BMQ_LOG"
export KERNEL_SCHED=bore
configure_cachyos_source
check "bore enables SCHED_BORE" has '--enable SCHED_BORE'
check "bore disables SCHED_ALT" has '--disable SCHED_ALT'

exit "$fail"

#!/usr/bin/env bash
# CachyOS source/BORE CLI validation. These failures happen before the root
# check, so they can be exercised unprivileged.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}

out=$(setsid bash "$SCRIPT" --sched bore </dev/null 2>&1)
check "bore without a CachyOS source is rejected" grep -q 'requires --source cachyos' <<<"$out"

out=$(setsid bash "$SCRIPT" --base-config cachyos </dev/null 2>&1)
check "cachyos base config without the source is rejected" grep -q 'requires --source cachyos' <<<"$out"

out=$(setsid bash "$SCRIPT" --source cachyos --kernel 7.3.3 </dev/null 2>&1)
check "a different kernel version is rejected for the pinned source" grep -q 'pinned to 7.3.4' <<<"$out"

out=$(setsid bash "$SCRIPT" --sched is-not-a-scheduler </dev/null 2>&1)
check "an unknown scheduler is rejected" grep -q 'Unknown scheduler' <<<"$out"

out=$(setsid bash "$SCRIPT" --source is-not-a-source </dev/null 2>&1)
check "an unknown source is rejected" grep -q 'Unknown kernel source' <<<"$out"

out=$(setsid bash "$SCRIPT" --cpu zen4 </dev/null 2>&1)
check "zen4 without a CachyOS source is rejected" grep -q 'requires --source cachyos' <<<"$out"

out=$(setsid bash "$SCRIPT" --cpu is-not-a-cpu </dev/null 2>&1)
check "an unknown CPU tuning is rejected" grep -q 'Unknown CPU tuning' <<<"$out"

out=$(setsid bash "$SCRIPT" --lto is-not-lto </dev/null 2>&1)
check "an unknown LTO mode is rejected" grep -q 'Unknown LTO mode' <<<"$out"

out=$(setsid bash "$SCRIPT" --help </dev/null 2>&1)
check "help documents --source" grep -q -- '--source' <<<"$out"
check "help documents --sched" grep -q -- '--sched' <<<"$out"
check "help documents --cpu" grep -q -- '--cpu' <<<"$out"
check "help documents --lto" grep -q -- '--lto' <<<"$out"

exit "$fail"

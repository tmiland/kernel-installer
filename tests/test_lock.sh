#!/usr/bin/env bash
# #70: two runs used the same build folder and log; the second one deleted the
# first one's tree. An flock must stop the second run before it rotates the log
# or touches the build directory, and the lock failure must not go through
# fatal() (which would delete the first run's build folder).
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
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

func=$(sed -n '/^take_lock() {/,/^}/p' "$SCRIPT")
if [ -z "$func" ]; then
  echo "FAIL: take_lock() not found in kernel_installer.sh"
  exit 1
fi

# 1. One holder keeps the lock; a second caller must fail fast.
lock="$work/test.lock"
holder=$(mktemp)
bash -c '
  eval "$1"
  LOCK_FILE=$2
  take_lock
  echo held > "$3"
  sleep 3
' _ "$func" "$lock" "$holder" &
holder_pid=$!
for _ in $(seq 50); do [ -s "$holder" ] && break; sleep 0.05; done
check "the first run acquires the lock" test -s "$holder"

out=$(timeout 3 bash -c 'eval "$1"; LOCK_FILE=$2; take_lock' _ "$func" "$lock" 2>&1)
rc=$?
check "a second run is refused (rc=$rc)" test "$rc" -eq 1
check "the refusal is explained" grep -qiE 'another|in progress|already running' <<<"$out"
wait "$holder_pid"

# 2. After the holder exits, the lock can be taken again.
out=$(timeout 3 bash -c 'eval "$1"; LOCK_FILE=$2; take_lock; echo acquired' _ "$func" "$lock" 2>&1)
rc=$?
check "the lock can be acquired after the first run exits (rc=$rc)" test "$rc" -eq 0
check "the later run reports acquisition" grep -qx acquired <<<"$out"

# 3. The lock failure must not run fatal(): fatal deletes INSTALL_DIR.
check "take_lock does not call fatal" not grep -q 'fatal ' <<<"$func"

# 4. Call sites: uninstall locks, and install locks before rotating the log.
start=$(sed -n '/^# Start Script/,$p' "$SCRIPT")
uninstall=$(sed -n '/^if \[ "\$mode" = "uninstall" \]; then/,/^fi$/p' <<<"$start")
check "the uninstall path takes the lock" grep -q '^  take_lock$' <<<"$uninstall"
n_lock=$(grep -n '^take_lock$' <<<"$start" | head -1 | cut -d: -f1)
n_rotate=$(grep -n '^rotate_log$' <<<"$start" | head -1 | cut -d: -f1)
# shellcheck disable=SC2329
lock_before_rotate() { [ -n "$n_lock" ] && [ -n "$n_rotate" ] && [ "$n_lock" -lt "$n_rotate" ]; }
check "install takes the lock before rotating the log (${n_lock:-?} < ${n_rotate:-?})" lock_before_rotate
check "the lock is not taken for --list-installed" not grep -q 'LIST_INSTALLED.*take_lock' <<<"$start"

exit "$fail"

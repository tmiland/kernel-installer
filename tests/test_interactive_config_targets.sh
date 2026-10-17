#!/usr/bin/env bash
# Terminal-interactive --config targets (menuconfig, oldconfig, ...) used to
# run under run_ok with their output in the log, so the user saw nothing and
# the run hung. Without a terminal they must now be refused up front; other
# targets must be unaffected.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail=0

# setsid detaches from any controlling terminal, so /dev/tty cannot be opened
run_no_tty() { setsid bash "$REPO/kernel_installer.sh" "$@" </dev/null 2>&1; }

for target in menuconfig nconfig oldconfig config localmodconfig localyesconfig; do
  if run_no_tty -c "$target" | grep -q "needs an interactive terminal"; then
    echo "ok: --config $target is refused without a terminal"
  else
    echo "FAIL: --config $target was not refused without a terminal"
    fail=1
  fi
done

for target in olddefconfig defconfig; do
  if run_no_tty -c "$target" | grep -q "needs an interactive terminal"; then
    echo "FAIL: --config $target was refused although it is not interactive"
    fail=1
  else
    echo "ok: --config $target does not need a terminal"
  fi
done

exit "$fail"

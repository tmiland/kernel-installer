#!/usr/bin/env bash
# The root check must run before anything with side effects (#46): a regular
# user must not be prompted to install lsb-release (or have the distro
# detected) before being told that the script needs root.
# Runs unprivileged.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

if [ "$EUID" -eq 0 ]; then
  echo "FAIL: run as a regular user (the root check needs a non-root EUID)"
  exit 1
fi

# A fake lsb_release that claims the tool is missing: a run that got past the
# root check would print the lsb-release prompt and read an answer.
mkdir "$work/shim"
printf '#!/bin/sh\nexit 1\n' > "$work/shim/lsb_release"
chmod +x "$work/shim/lsb_release"

rc=0
# setsid detaches from any controlling terminal, </dev/null gives nothing to
# read: without the early root check the run would show the lsb-release prompt
out=$(PATH="$work/shim:$PATH" setsid bash "$SCRIPT" --list-installed </dev/null 2>&1) || rc=$?

check_out() { # desc, pattern
  if printf '%s' "$out" | grep -q "$2"; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    fail=1
  fi
}
check_out_not() { # desc, pattern
  if printf '%s' "$out" | grep -q "$2"; then
    echo "FAIL: $1"
    fail=1
  else
    echo "ok: $1"
  fi
}

check_out "a regular user is told the script must be run as root" 'must be run as root'
check_out_not "the lsb-release prompt is not reached without root" 'Do you want to download'
if [ "$rc" -ne 0 ]; then
  echo "ok: the run exits non-zero ($rc)"
else
  echo "FAIL: the run exits 0"
  fail=1
fi

exit "$fail"

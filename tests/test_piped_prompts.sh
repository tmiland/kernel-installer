#!/usr/bin/env bash
# When the script is piped in (curl | bash), its prompts must not read the
# rest of the script from stdin as the answer. Answers piped into a script
# that runs from a file must keep working.
# The root check runs before any prompt (#46), so both runs go through
# passwordless sudo (skipped when unavailable). Uses the lsb-release prompt
# with a failing lsb_release stub; the answer is read from the xtrace of
# `case $ANSWER in`.
# The single-quoted $ANSWER patterns below are literal script/trace text.
# shellcheck disable=SC2016
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

if ! sudo -n true 2>/dev/null; then
  echo "SKIP: passwordless sudo unavailable (the script requires root)"
  exit 0
fi

mkdir -p "$work/shim"
printf '#!/bin/sh\nexit 1\n' > "$work/shim/lsb_release"
chmod +x "$work/shim/lsb_release"
ps4='+[ANSWER=${ANSWER-<unset>}] '
answer_from_trace() { grep -m1 -F 'case $ANSWER in' "$1" | sed -E 's/^\+\[ANSWER=(.*)\] case .*/\1/'; }

# 1. Piped in, no terminal (setsid): the answer must be empty, not script text
{ printf 'PS4=%q\n' "$ps4"; cat "$SCRIPT"; } |
  setsid sudo -n env PATH="$work/shim:$PATH" LOGFILE="$work/piped.log" bash -x -s -- --list-installed >/dev/null 2>"$work/trace1"
if ! grep -qF 'case $ANSWER in' "$work/trace1"; then
  echo "FAIL: piped run never reached the lsb-release prompt"
  fail=1
else
  a=$(answer_from_trace "$work/trace1")
  if [ -z "$a" ]; then
    echo "ok: piped run without a terminal: answer is empty"
  else
    echo "FAIL: piped run read the script itself as the answer: [$a]"
    fail=1
  fi
fi

# 2. Run from a file with the answer piped in: the answer must arrive.
# PS4 through the environment is reset when bash starts as root via sudo
# (measured), so inject it through BASH_ENV, which bash sources at startup.
printf 'PS4=%q\n' "$ps4" > "$work/ps4env.sh"
printf 'n\n' | setsid sudo -n env BASH_ENV="$work/ps4env.sh" PATH="$work/shim:$PATH" LOGFILE="$work/piped.log" bash -x "$SCRIPT" --list-installed >/dev/null 2>"$work/trace2"
rc=$?
a=$(answer_from_trace "$work/trace2")
if [ "$a" = "n" ] && [ "$rc" -eq 1 ]; then
  echo "ok: answer piped into a file run still arrives (n -> exit 1)"
else
  echo "FAIL: answer piped into a file run: got [$a], exit $rc"
  fail=1
fi

exit "$fail"

#!/usr/bin/env bash
# #65: slib wrote unitest.txt and stopspinning into the directory the script
# was started from, as root. A real file with either name was overwritten or
# deleted. Unicode detection must be fileless and the spinner must use a
# private temporary directory that is cleaned up.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SLIB="$REPO/src/slib.sh"
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

# 1. Sourcing slib must not overwrite/delete a real unitest.txt in cwd.
mkdir "$work/cwd1"
printf 'keep-me\n' > "$work/cwd1/unitest.txt"
(
  cd "$work/cwd1" || exit 1
  # shellcheck disable=SC1090
  . "$SLIB"
) >/dev/null 2>&1
check "unitest.txt in cwd survives sourcing slib" grep -qx keep-me "$work/cwd1/unitest.txt"

# 2. shell_has_unicode must not create the file when called directly.
(
  cd "$work/cwd1" || exit 1
  # shellcheck disable=SC1090
  . "$SLIB"
  shell_has_unicode
) >/dev/null 2>&1
check "shell_has_unicode leaves unitest.txt alone" grep -qx keep-me "$work/cwd1/unitest.txt"

# 3. run_ok must not touch a real stopspinning file in cwd, and must clean up
#    the private spinner directory it uses instead.
mkdir "$work/cwd2" "$work/tmp"
printf 'not-ours\n' > "$work/cwd2/stopspinning"
(
  cd "$work/cwd2" || exit 1
  export TMPDIR="$work/tmp" TERM=xterm
  # shellcheck disable=SC1090
  . "$SLIB"
  INTERACTIVE_MODE=on
  RUN_LOG="$work/run.log"
  RUN_ERRORS_FATAL=''
  allpids=''
  run_ok true "Doing a thing"
) >"$work/out" 2>"$work/err"
check "run_ok succeeds" grep -q 'Doing a thing' "$work/out"
check "stopspinning in cwd survives run_ok" grep -qx not-ours "$work/cwd2/stopspinning"
check "run_ok does not create unitest.txt in cwd" not test -e "$work/cwd2/unitest.txt"
check "run_ok cleans up its private spinner directory" test -z "$(find "$work/tmp" -mindepth 1 -maxdepth 1 -print -quit)"

# 4. Static checks: the fixed primitives are in place.
check "shell_has_unicode no longer writes unitest.txt" not grep -q 'unitest.txt' "$SLIB"
check "run_ok creates the stop file with mktemp -d" grep -q 'mktemp -d' "$SLIB"
check "run_ok cleans the spinner directory" grep -q 'rm -rf "\$spinner_dir"' "$SLIB"

exit "$fail"

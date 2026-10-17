#!/usr/bin/env bash
# Logging and terminal output:
#  - slib.sh's terminal check was always true (#54), so output to a file or a
#    pipe got the spinner and color codes, and every tput call failed without
#    TERM; run_ok also wrote its own debug lines into the log (#55)
#  - LOGFILE could not be overridden (#56), and every run deleted the log of
#    the previous one, even --list-installed (#53)
#  - get_verified_tarball exited from inside run_ok, whose output goes to the
#    log, so a verification failure ended the run with nothing on screen (#50)
# Runs unprivileged; needs util-linux script(1) for the terminal case.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
SLIB="$REPO/src/slib.sh"
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2317,SC2329  # invoked through check
not() { ! "$@"; }

if [ "$EUID" -eq 0 ]; then
  echo "FAIL: run as a regular user (the root check and the read-only directory case need one)"
  exit 1
fi

# runner.sh: source slib.sh and run one command under run_ok
cat > "$work/runner.sh" <<'EOF'
. "$SLIB"
RUN_LOG=$RUNLOG
RUN_ERRORS_FATAL=''
run_ok "$CMD" "Doing a thing"
EOF

# 1. Output to a file, TERM unset: no tput errors
env -u TERM SLIB="$SLIB" RUNLOG="$work/log1" CMD=true \
  bash "$work/runner.sh" > "$work/out1" 2> "$work/err1"
check "not a terminal, TERM unset: no tput errors" not grep -q 'tput:' "$work/err1"

# 2. Output to a file, TERM set: no escape codes, no spinner, result still shown
env TERM=xterm SLIB="$SLIB" RUNLOG="$work/log2" CMD='sleep 0.5' \
  bash "$work/runner.sh" > "$work/out2" 2> "$work/err2"
check "not a terminal: no escape codes in the output" not grep -q $'\x1b' "$work/out2"
check "not a terminal: no spinner frames in the output" not grep -q '▒' "$work/out2"
check "not a terminal: the result is still printed" grep -q 'Doing a thing' "$work/out2"
check "run_ok does not log the spinner pid" not grep -q 'Spin pid is' "$work/log2"

# 3. A real terminal (script(1) gives the command a pty): colors are still used
if ! command -v script >/dev/null 2>&1; then
  echo "FAIL: script(1) not found (util-linux); cannot test terminal output"
  fail=1
else
  # The spinner cannot be told to stop when its done-file cannot be created
  # (read-only directory), so run_ok finds it still running every time; that
  # is the case that logged "Made it here...why?".
  mkdir "$work/ro"
  chmod a-w "$work/ro"
  (
    cd "$work/ro" || exit 1
    env TERM=xterm SLIB="$SLIB" RUNLOG="$work/log3" CMD='sleep 0.5' \
      script -qec "bash '$work/runner.sh'" /dev/null > "$work/out3" 2>&1
  )
  check "terminal: colors are still used" grep -q $'\x1b' "$work/out3"
  check "terminal: the spinner still runs" grep -qE '▒|\[>----\]' "$work/out3"
  check "terminal: run_ok does not log the spinner pid" not grep -q 'Spin pid is' "$work/log3"
  check "terminal: a surviving spinner is not logged as 'Made it here'" not grep -q 'Made it here' "$work/log3"
  check "terminal: the case above really had a surviving spinner (instrument check)" \
    grep -q 'stopspinning' "$work/out3"
fi

# 4. LOGFILE from the environment is used, and --list-installed keeps the
#    previous log (a regular user stops at the root check, which is logged)
printf 'OLD-BUILD-LOG\n' > "$work/ki.log"
LOGFILE="$work/ki.log" bash "$SCRIPT" --list-installed < /dev/null > "$work/out4" 2>&1
check "LOGFILE from the environment is used" grep -q 'must be run as root' "$work/ki.log"
check "--list-installed keeps the previous log" grep -q 'OLD-BUILD-LOG' "$work/ki.log"
check "--list-installed does not rotate the log" not test -e "$work/ki.log.1"

# 5. rotate_log keeps one previous log
func=$(sed -n '/^rotate_log() {/,/^}/p' "$SCRIPT")
if [ -z "$func" ]; then
  echo "FAIL: rotate_log() not found in kernel_installer.sh"
  fail=1
else
  eval "$func"
  LOGFILE="$work/r.log"
  printf 'first\n' > "$LOGFILE"
  rotate_log
  check "rotate_log: the log is moved away" not test -e "$LOGFILE"
  check "rotate_log: the previous log is kept as .1" grep -qx first "$LOGFILE.1"
  printf 'second\n' > "$LOGFILE"
  rotate_log
  check "rotate_log: .1 holds the most recent previous log" grep -qx second "$LOGFILE.1"
  rm -f "$LOGFILE.1"
  rotate_log
  check "rotate_log: no log yet, nothing is created" not test -e "$LOGFILE.1"
fi

# 6. get_verified_tarball reports failures to its caller instead of exiting
funcs=$(sed -n '/^verify_fail() {/,/^}/p; /^get_verified_tarball() {/,/^}/p' "$SCRIPT")
mkdir -p "$work/dir" "$work/bin-nogpg" "$work/bin-badgpg"
ln -s "$(command -v cut)" "$work/bin-nogpg/cut"
for tool in cut mktemp mkdir rm; do
  ln -s "$(command -v "$tool")" "$work/bin-badgpg/$tool"
done
printf '#!/bin/sh\nexit 1\n' > "$work/bin-badgpg/gpg"
printf '#!/bin/sh\nexit 0\n' > "$work/bin-badgpg/gpgv"
chmod +x "$work/bin-badgpg/gpg" "$work/bin-badgpg/gpgv"

# verify_case <LINUX_VER> <INSTALL_DIR> [PATH]: prints "returned rc=N error=..."
# only if get_verified_tarball returned; the real fatal() exits
verify_case() {
  (
    # shellcheck disable=SC2317,SC2329  # called by the eval'd functions
    log_debug() { :; }
    # shellcheck disable=SC2317,SC2329  # called by the eval'd functions
    fatal() { echo "fatal: $1"; exit 1; }
    # shellcheck disable=SC2034  # read by the eval'd functions
    INSTALL=false GNUPGHOME=''
    eval "$funcs"
    # shellcheck disable=SC2034  # read by the eval'd functions
    LINUX_VER=$1 INSTALL_DIR=$2
    [ -n "${3:-}" ] && PATH=$3
    get_verified_tarball > /dev/null 2>&1
    echo "returned rc=$? error=${VERIFY_ERROR:-}"
  )
}
out=$(verify_case 6.12.113 "$work/missing")
check "verify: missing directory returns 1 with the reason ($out)" \
  grep -qE '^returned rc=1 error=.*missing does not exist' <<<"$out"
out=$(verify_case 2.6.39 "$work/dir")
check "verify: unsupported version returns 1 with the reason ($out)" \
  grep -qE '^returned rc=1 error=.*v3' <<<"$out"
out=$(verify_case 6.12.113 "$work/dir" "$work/bin-nogpg")
check "verify: gpg cannot be installed, returns 1 with the reason ($out)" \
  grep -qE '^returned rc=1 error=.*gpg' <<<"$out"
out=$(verify_case 6.12.113 "$work/dir" "$work/bin-badgpg")
check "verify: signing keys cannot be fetched, returns 1 with the reason ($out)" \
  grep -qE '^returned rc=1 error=.*key' <<<"$out"
# shellcheck disable=SC2317,SC2329  # invoked through check
no_verify_dir() { ! compgen -G "$work/dir/linux-tarball-verify.*" > /dev/null; }
check "verify: the temporary verification directory is removed" no_verify_dir

exit "$fail"

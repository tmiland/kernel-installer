#!/usr/bin/env bash
# #64: /var/log is group-writable on Ubuntu/Mint, so the default log path was
# writable through a symlink by the syslog group. The log now lives in a
# root-only subdirectory, and a custom LOGFILE is validated before root appends
# to it or renames it to .1.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

func=$(sed -n '/^chk_logfile() {/,/^}/p' "$SCRIPT")
if [ -z "$func" ]; then
  echo "FAIL: chk_logfile() not found in kernel_installer.sh"
  exit 1
fi

# run_log <log path> <default path>: 0 when accepted, 1 when fatal() fires
run_log() {
  (
    # shellcheck disable=SC2329
    fatal() { echo "FATAL $1" >&2; exit 1; }
    eval "$func"
    LOGFILE=$1 DEFAULT_LOGFILE=$2
    chk_logfile "$1"
  ) >"$work/out" 2>&1
  echo $?
}

# 1. A private directory is accepted.
dir="$work/private"
mkdir -m 0700 "$dir"
check "private log directory accepted" test "$(run_log "$dir/ki.log" "$work/default/ki.log")" -eq 0

# 2. Symlink at the log path is refused.
ln -s "$dir/real.log" "$dir/link.log"
check "symlink log refused" test "$(run_log "$dir/link.log" "$work/default/ki.log")" -ne 0
check "the symlink refusal is explained" grep -qi 'symlink' "$work/out"

# 3. A non-regular log path is refused.
mkdir "$dir/dir.log"
check "directory at the log path refused" test "$(run_log "$dir/dir.log" "$work/default/ki.log")" -ne 0

# 4. A symlink at .1 is refused.
ln -s "$dir/real.log" "$dir/ki.log.1"
check "symlink at .1 refused" test "$(run_log "$dir/ki.log" "$work/default/ki.log")" -ne 0
rm -f "$dir/ki.log.1"

# 5. A non-sticky group-writable directory is refused; a sticky one is allowed.
shared="$work/shared"
mkdir -m 0777 "$shared"
check "group-writable non-sticky log dir refused" test "$(run_log "$shared/ki.log" "$work/default/ki.log")" -ne 0
chmod 1777 "$shared"
check "sticky shared log dir refused too" test "$(run_log "$shared/ki.log" "$work/default/ki.log")" -ne 0

# 6. The default directory is created 0700, and an existing 0755 default dir is
#    refused (group/other can read it).
def="$work/default/sub/ki.log"
check "default log directory created" test "$(run_log "$def" "$def")" -eq 0
check "default log directory is 0700" test "$(stat -c '%a' "$work/default/sub")" = "700"
chmod 0755 "$work/default/sub"
check "existing 0755 default dir refused" test "$(run_log "$def" "$def")" -ne 0

# 7. Call site and default path.
start=$(sed -n '/^chk_permissions$/,$p' "$SCRIPT")
n_perm=$(grep -n '^chk_permissions$' <<<"$start" | head -1 | cut -d: -f1)
n_log=$(grep -n '^chk_logfile' <<<"$start" | head -1 | cut -d: -f1)
# shellcheck disable=SC2329
log_after_root() { [ -n "$n_perm" ] && [ -n "$n_log" ] && [ "$n_perm" -lt "$n_log" ]; }
check "chk_logfile runs after the root check (${n_perm:-?} < ${n_log:-?})" log_after_root
check "the default log is in a root-only subdirectory" grep -q '^DEFAULT_LOGFILE=/var/log/kernel-installer/' "$SCRIPT"
check "LOGFILE still honours the environment" grep -q '^LOGFILE=${LOGFILE:-$DEFAULT_LOGFILE}$' "$SCRIPT"
check "rotate_log uses -- with mv" grep -q 'mv -f -- "$LOGFILE" "$LOGFILE.1"' "$SCRIPT"

exit "$fail"

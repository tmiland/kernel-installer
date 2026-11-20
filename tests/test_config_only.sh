#!/usr/bin/env bash
# --config-only: fast configuration validation.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}

out=$(setsid bash "$SCRIPT" --config-only --uninstall </dev/null 2>&1)
check "config-only rejects uninstall" grep -q 'cannot be combined' <<<"$out"

out=$(setsid bash "$SCRIPT" --help </dev/null 2>&1)
check "help documents --config-only" grep -q -- '--config-only' <<<"$out"

first=$(grep -n 'CONFIG_ONLY" = "1"' "$SCRIPT" | head -1 | cut -d: -f1)
compile=$(grep -n 'Compiling The Linux Kernel source code' "$SCRIPT" | head -1 | cut -d: -f1)
check "config-only exits before compilation" test "$first" -lt "$compile"

exit "$fail"

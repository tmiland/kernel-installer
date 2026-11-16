#!/usr/bin/env bash
# linux-hardened variant: pinned source, CLI validation, patch wiring.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}

out=$(setsid bash "$SCRIPT" --hardened --source cachyos </dev/null 2>&1)
check "hardened rejects the CachyOS source" \
  grep -q 'requires --source vanilla' <<<"$out"

out=$(setsid bash "$SCRIPT" --hardened -k 7.3.4 </dev/null 2>&1)
check "hardened rejects another kernel version" \
  grep -q 'pinned to 7.3.1' <<<"$out"

out=$(setsid bash "$SCRIPT" --help </dev/null 2>&1)
check "help documents --hardened" grep -q -- '--hardened' <<<"$out"

# --- pinned constants -----------------------------------------------------
check "hardened version is 7.3.1" grep -q '^HARDENED_VERSION=7.3.1$' "$SCRIPT"
check "hardened tag is v7.3.1-hardened1" grep -q '^HARDENED_TAG=v7.3.1-hardened1$' "$SCRIPT"
# shellcheck disable=SC2016  # script text, not shell expansion
check "hardened patch URL is the release asset" \
  grep -qF 'linux-hardened/releases/download/${HARDENED_TAG}/linux-hardened-${HARDENED_TAG}.patch' "$SCRIPT"
check "hardened patch SHA256 is pinned" \
  grep -q '^HARDENED_PATCH_SHA256=c79c8364' "$SCRIPT"

# --- apply wiring ---------------------------------------------------------
apply=$(sed -n '/^apply_hardened_patch() {/,/^}/p' "$SCRIPT")
check "apply_hardened_patch verifies the checksum" \
  grep -q 'HARDENED_PATCH_SHA256' <<<"$apply"
check "apply_hardened_patch applies with patch -p1" \
  grep -q 'patch -p1' <<<"$apply"
check "apply_hardened_patch is defined before its call site" \
  test "$(grep -n '^apply_hardened_patch() {' "$SCRIPT" | cut -d: -f1)" \
    -lt "$(grep -n '^      apply_hardened_patch$' "$SCRIPT" | cut -d: -f1)"
check "hardened assertion is called" \
  grep -q '^      assert_hardened$' "$SCRIPT"

exit "$fail"

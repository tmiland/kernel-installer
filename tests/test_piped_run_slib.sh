#!/usr/bin/env bash
# A piped run (curl | bash) must not source a src/slib.sh from the current
# directory or its parent; it must fetch the pinned, checksum-verified copy
# instead. (Which directory a naive check would pick depends on coreutils:
# readlink -f "" is empty with GNU, the current directory with uutils.)
# A run from a checkout must keep using the checkout's src/slib.sh.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# Planted copies that announce themselves: one in the directory the user runs
# from, one in its parent
plant() { mkdir -p "$1/src"; { cat "$REPO/src/slib.sh"; printf '\necho %s\n' "$2"; } > "$1/src/slib.sh"; }
plant "$work/parent" PLANTED_PARENT_SLIB_SOURCED
plant "$work/parent/cwd" PLANTED_CWD_SLIB_SOURCED

# Piped run from that directory, like `curl ... | bash`
out=$(cd "$work/parent/cwd" && cat "$REPO/kernel_installer.sh" | bash -s -- --help 2>&1)
if grep -q PLANTED_ <<<"$out"; then
  echo "FAIL: piped run sourced a planted slib.sh: $(grep -o 'PLANTED_[A-Z_]*' <<<"$out" | tr '\n' ' ')"
  fail=1
elif ! grep -q -- '--kernel' <<<"$out"; then
  echo "FAIL: piped run did not print the help (pinned slib.sh fetch failed?)"
  echo "$out"
  fail=1
else
  echo "ok: piped run ignored ./src/slib.sh and ../src/slib.sh and used the pinned copy"
fi

# Run from a checkout: a copy of the script next to a planted slib.sh
cp "$REPO/kernel_installer.sh" "$work/parent/cwd/kernel_installer.sh"
out=$(cd "$work" && bash parent/cwd/kernel_installer.sh --help 2>&1)
if grep -q PLANTED_CWD_SLIB_SOURCED <<<"$out"; then
  echo "ok: run from a checkout uses the checkout's src/slib.sh"
else
  echo "FAIL: run from a checkout did not use the checkout's src/slib.sh"
  fail=1
fi

exit "$fail"

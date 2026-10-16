#!/usr/bin/env bash
# A piped run (curl | bash) must not source src/slib.sh from the current
# directory; it must fetch the pinned, checksum-verified copy instead. A run
# from a checkout must keep using the checkout's src/slib.sh.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# A directory with a planted src/slib.sh that announces itself
mkdir -p "$work/planted/src"
{ cat "$REPO/src/slib.sh"; printf '\necho PLANTED_SLIB_SOURCED\n'; } > "$work/planted/src/slib.sh"

# Piped run from that directory, like `curl ... | bash`
out=$(cd "$work/planted" && cat "$REPO/kernel_installer.sh" | bash -s -- --help 2>&1)
if grep -q PLANTED_SLIB_SOURCED <<<"$out"; then
  echo "FAIL: piped run sourced ./src/slib.sh from the current directory"
  fail=1
elif ! grep -q -- '--kernel' <<<"$out"; then
  echo "FAIL: piped run did not print the help (pinned slib.sh fetch failed?)"
  echo "$out"
  fail=1
else
  echo "ok: piped run ignored ./src/slib.sh and used the pinned copy"
fi

# Run from a checkout: a copy of the script next to the planted slib.sh
cp "$REPO/kernel_installer.sh" "$work/planted/kernel_installer.sh"
out=$(cd "$work" && bash planted/kernel_installer.sh --help 2>&1)
if grep -q PLANTED_SLIB_SOURCED <<<"$out"; then
  echo "ok: run from a checkout uses the checkout's src/slib.sh"
else
  echo "FAIL: run from a checkout did not use the checkout's src/slib.sh"
  fail=1
fi

exit "$fail"

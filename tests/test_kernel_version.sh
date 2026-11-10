#!/usr/bin/env bash
# #63: a kernel version must be a plain version string, not a shell fragment.
# chk_version used to accept anything starting with digits.digits and the -k
# option only checked the first character; the version is later put through
# run_ok's eval. The whitelist must still allow the distro-style versions the
# script supports elsewhere (7.0.0-38-generic, 6.17.1-300.fc44.x86_64).
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

func=$(sed -n '/^valid_kernel_version() {/,/^}/p' "$SCRIPT")
if [ -z "$func" ]; then
  echo "FAIL: valid_kernel_version() not found in kernel_installer.sh"
  exit 1
fi
eval "$func"

while read -r version; do
  check "valid: $version" valid_kernel_version "$version"
done <<'EOF'
6.17.8
6.17
7.3-rc7
7.3.0-rc7
7.0.0-38-generic
6.17.1-300.fc44.x86_64
6.12.113-test
6.12.113+foo
6.12.113~rc1
6.12.113_1
EOF

while read -r version; do
  check "rejected: ${version:-<empty>}" not valid_kernel_version "$version"
done <<'EOF'

6
v6.17.8
6.17.8;junk
6.17x y
6.17.8/../../etc
6.17.8$(echo injected)
6.17.8`id`
6.17.8|cat
6.17.8>file
6.17.8&sleep
EOF

# chk_version and the -k parser must both use the shared whitelist
chk=$(sed -n '/^chk_version() {/,/^}/p' "$SCRIPT")
check "chk_version uses valid_kernel_version" grep -q 'valid_kernel_version "\$LINUX_VER"' <<<"$chk"
check "chk_version no longer uses the unanchored prefix regex" not grep -q '\^\[0-9\]\+\\\.\[0-9\]\+' <<<"$chk"
parse=$(sed -n '/--kernel | -k)/,/;;/p' "$SCRIPT")
check "-k uses valid_kernel_version" grep -q 'valid_kernel_version "\$2"' <<<"$parse"
check "-k no longer checks only the first character" not grep -q '\^\[0-9\]\$\|\[\[ ! \$2 =~ \^\[0-9\]' <<<"$parse"

exit "$fail"

#!/usr/bin/env bash
# Building with a config copied from an Ubuntu/Mint /boot failed twice (#39):
# SYSTEM_TRUSTED_KEYS/SYSTEM_REVOCATION_KEYS point at debian/*.pem files that
# are not in a kernel.org tree, and CONFIG_BUILTIN_MODULE_RANGES needs gawk.
# Runs clear_missing_cert_keys against the kernel's real scripts/config.
# Single-quoted "$..." patterns below are literal script text.
# shellcheck disable=SC2016
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

func=$(sed -n '/^clear_missing_cert_keys() {/,/^}/p' "$SCRIPT")
if [ -z "$func" ]; then
  echo "FAIL: clear_missing_cert_keys() not found in kernel_installer.sh"
  exit 1
fi

# A minimal kernel tree with the real scripts/config
tree="$work/linux"
mkdir -p "$tree/scripts" "$tree/certs"
if ! curl -fsSL --retry 2 -o "$tree/scripts/config" \
  'https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/scripts/config?h=v6.12.113'; then
  echo "FAIL: could not fetch scripts/config from git.kernel.org"
  exit 1
fi
chmod +x "$tree/scripts/config"

# run_case <.config contents>: run the function in the tree, then report the
# resulting values and the warnings it logged
run_case() {
  printf '%s\n' "$1" > "$tree/.config"
  (
    cd "$tree" || exit 1
    # shellcheck disable=SC2329
    log_warning() { echo "WARNING $1" >> "$work/warnings"; }
    eval "$func"
    clear_missing_cert_keys
  )
}
value() { "$tree/scripts/config" --file "$tree/.config" --state "$1"; }
reset_warnings() { : > "$work/warnings"; }

# 1. Ubuntu's values, files missing: both cleared, with a warning each
reset_warnings
run_case 'CONFIG_SYSTEM_TRUSTED_KEYS="debian/canonical-certs.pem"
CONFIG_SYSTEM_REVOCATION_KEYS="debian/canonical-revoked-certs.pem"'
check "Ubuntu config: SYSTEM_TRUSTED_KEYS cleared" test "$(value SYSTEM_TRUSTED_KEYS)" = ""
check "Ubuntu config: SYSTEM_REVOCATION_KEYS cleared" test "$(value SYSTEM_REVOCATION_KEYS)" = ""
check "Ubuntu config: both clearings are reported" test "$(grep -c 'is not in the kernel source; clearing it' "$work/warnings")" = 2
check "Ubuntu config: the .config line is really empty" grep -qx 'CONFIG_SYSTEM_TRUSTED_KEYS=""' "$tree/.config"

# 2. A certificate that exists (relative to the tree, or absolute) is kept
: > "$tree/certs/mine.pem"
: > "$work/abs.pem"
reset_warnings
run_case "CONFIG_SYSTEM_TRUSTED_KEYS=\"certs/mine.pem\"
CONFIG_SYSTEM_REVOCATION_KEYS=\"$work/abs.pem\""
check "existing relative certificate kept" test "$(value SYSTEM_TRUSTED_KEYS)" = "certs/mine.pem"
check "existing absolute certificate kept" test "$(value SYSTEM_REVOCATION_KEYS)" = "$work/abs.pem"
check "nothing reported for existing certificates" test ! -s "$work/warnings"

# 3. Empty, not set, or absent: left alone, nothing reported
reset_warnings
run_case 'CONFIG_SYSTEM_TRUSTED_KEYS=""
# CONFIG_SYSTEM_REVOCATION_KEYS is not set'
check "empty value left alone" grep -qx 'CONFIG_SYSTEM_TRUSTED_KEYS=""' "$tree/.config"
check "unset value left alone" grep -qx '# CONFIG_SYSTEM_REVOCATION_KEYS is not set' "$tree/.config"
check "nothing reported for empty/unset" test ! -s "$work/warnings"
reset_warnings
run_case 'CONFIG_SOMETHING_ELSE=y'
check "absent options are not added" not grep -q 'SYSTEM_TRUSTED_KEYS' "$tree/.config"

# Call site: after the --custom-config loop (so user certificates win) and
# before compilation
body=$(sed -n '/^install_kernel() {/,/^}/p' "$SCRIPT")
line_of() { grep -nE -m1 "$1" <<<"$body" | cut -d: -f1; }
n_custom=$(line_of 'eval "\$custom_config_option"')
n_clear=$(line_of '^      clear_missing_cert_keys$')
n_build=$(line_of 'Phase 5 of 6: Compilation')
# shellcheck disable=SC2329  # invoked through check
in_order() { [ -n "$n_custom" ] && [ -n "$n_clear" ] && [ -n "$n_build" ] && [ "$n_custom" -lt "$n_clear" ] && [ "$n_clear" -lt "$n_build" ]; }
check "install_kernel calls clear_missing_cert_keys after --custom-config, before compilation (lines ${n_custom:-?} < ${n_clear:-?} < ${n_build:-?})" in_order

# gawk is installed on both families
check "gawk is in the Debian INSTALL_PKGS" grep -qE '^  INSTALL_PKGS="wget curl git rsync fakeroot.* gawk ' "$SCRIPT"
check "gawk is in the RHEL INSTALL_PKGS" grep -qE '^    INSTALL_PKGS="wget curl git rsync ca-certificates.* gawk ' "$SCRIPT"

exit "$fail"

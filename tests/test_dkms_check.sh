#!/usr/bin/env bash
# DKMS release check: warn when no modules are built for the installed release.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/dkms" <<'SH'
#!/usr/bin/env bash
if [ "${DKMS_HAS:-0}" = 1 ]; then
  printf 'nct6687d/1, %s, x86_64: installed\n' "${3:-}"
fi
SH
chmod +x "$work/bin/dkms"
export PATH="$work/bin:$PATH"
warnings="$work/warnings"
log_warning() { printf '%s\n' "$1" >> "$warnings"; }
log_info() { :; }
func=$(sed -n '/^check_dkms_release() {/,/^}/p' "$SCRIPT")
[ -n "$func" ] || { echo "FAIL: check_dkms_release() not found"; exit 1; }
eval "$func"

: > "$warnings"
DKMS_HAS=0 check_dkms_release "7.3.4-cachyos-workstation-bore"
check "missing DKMS build is reported" grep -q 'dkms autoinstall -k 7.3.4-cachyos-workstation-bore' "$warnings"

: > "$warnings"
DKMS_HAS=1 check_dkms_release "7.3.4-cachyos-workstation-bore"
check "existing DKMS build is not warned about" test ! -s "$warnings"

exit "$fail"

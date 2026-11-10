#!/usr/bin/env bash
# #71: the Debian/Ubuntu path installed headers and image in two apt calls; a
# failure in the second left headers for a kernel that was never installed.
# Both package names must go to one package-manager invocation (the RHEL path
# already did this).
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

block=$(sed -n '/# Install$/,/log_success "Installation finished"/p' "$SCRIPT")
if [ -z "$block" ]; then
  echo "FAIL: install block not found in kernel_installer.sh"
  exit 1
fi

# Run the block with a fake run_ok that records the command it was given.
run_case() {
  local distro=$1 ver=$2 dir=$3
  (
    cd "$dir" || exit 1
    # shellcheck disable=SC2329
    run_ok() { printf '%s\n' "$1" >> "$work/calls"; }
    # shellcheck disable=SC2329
    log_success() { :; }
    # shellcheck disable=SC2329
    log_error() { :; }
    # shellcheck disable=SC2329
    fatal() { echo "fatal: $1" >&2; exit 1; }
    DISTRO_GROUP=$distro LINUX_VER=$ver LINUX_FULL_VER=$ver INSTALL='apt-get install -y'
    eval "$block"
  )
}

# Debian/Ubuntu: one invocation carrying both package globs.
deb="$work/deb"
mkdir -p "$deb"
touch "$deb/linux-headers-6.12.113_1_amd64.deb" "$deb/linux-image-6.12.113_1_amd64.deb"
: > "$work/calls"
run_case Debian 6.12.113 "$deb" || fail=1
call_count=$(wc -l < "$work/calls")
calls=$(tr -d '"' < "$work/calls")
check "Debian: exactly one package-manager call ($call_count)" test "$call_count" -eq 1
check "Debian: the call installs the headers" grep -q 'linux-headers-6\.12\.113' <<<"$calls"
check "Debian: the call installs the image" grep -q 'linux-image-6\.12\.113' <<<"$calls"
check "Debian: both are in the same call" grep -q 'linux-headers-.*linux-image-\|linux-image-.*linux-headers-' <<<"$calls"

# RHEL: still one dnf/package-manager call with both rpms.
rpm="$work/rpm"
mkdir -p "$rpm/linux-6.12.113/rpmbuild/RPMS/x86_64"
touch "$rpm/linux-6.12.113/rpmbuild/RPMS/x86_64/kernel-6.12.113-1.x86_64.rpm" \
  "$rpm/linux-6.12.113/rpmbuild/RPMS/x86_64/kernel-devel-6.12.113-1.x86_64.rpm"
: > "$work/calls"
run_case RHEL 6.12.113 "$rpm" || fail=1
call_count=$(wc -l < "$work/calls")
calls=$(tr -d '"' < "$work/calls")
check "RHEL: exactly one package-manager call ($call_count)" test "$call_count" -eq 1
check "RHEL: the call installs kernel and kernel-devel" grep -q 'kernel-6\.12\.113.*kernel-devel-6\.12\.113' <<<"$calls"

# The two-call pattern must be gone from the source.
check "no separate headers-only install call" not grep -qE 'run_ok "\$\{INSTALL\} \./linux-headers-[^"]*" "Installing Kernel headers' "$SCRIPT"
check "no separate image-only install call" not grep -qE 'run_ok "\$\{INSTALL\} \./linux-image-[^"]*" "Installing Kernel image' "$SCRIPT"

exit "$fail"

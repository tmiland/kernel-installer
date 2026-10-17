#!/usr/bin/env bash
# The README's dependency lists drifted from the packages the script installs:
# gawk (#40) and elfutils-devel (d9f98c4) were added to INSTALL_PKGS only.
# Checks that each README list names exactly the packages in the matching
# INSTALL_PKGS line.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
README="$REPO/README.md"
fail=0

# Active (uncommented) INSTALL_PKGS lines, in file order: Debian, then RHEL
mapfile -t script_lists < <(sed -n 's/^[[:space:]]*INSTALL_PKGS="\([^"]*\)".*/\1/p' "$SCRIPT")
if [ "${#script_lists[@]}" -ne 2 ]; then
  echo "FAIL: expected 2 INSTALL_PKGS lines in kernel_installer.sh, found ${#script_lists[@]}"
  exit 1
fi

# readme_list <heading>: the line after "# <heading>" in the README
readme_list() {
  awk -v h="# $1" '$0 == h { getline; print; exit }' "$README"
}

# compare <name> <script list> <readme list>
compare() {
  local name=$1 script=$2 readme=$3 missing extra
  if [ -z "$script" ] || [ -z "$readme" ]; then
    echo "FAIL: $name: empty list (script: '${script}', README: '${readme}')"
    fail=1
    return
  fi
  missing=$(comm -23 <(tr ' ' '\n' <<<"$script" | sort -u) <(tr ' ' '\n' <<<"$readme" | sort -u) | tr '\n' ' ')
  extra=$(comm -13 <(tr ' ' '\n' <<<"$script" | sort -u) <(tr ' ' '\n' <<<"$readme" | sort -u) | tr '\n' ' ')
  if [ -z "$missing$extra" ]; then
    echo "ok: $name: README lists the packages the script installs"
  else
    [ -n "$missing" ] && echo "FAIL: $name: missing from README: $missing"
    [ -n "$extra" ] && echo "FAIL: $name: in README but not installed: $extra"
    fail=1
  fi
}

compare "Debian/Ubuntu" "${script_lists[0]}" "$(readme_list 'Debian/Ubuntu')"
compare "Fedora/RHEL" "${script_lists[1]}" "$(readme_list 'Fedora/RHEL')"

exit "$fail"

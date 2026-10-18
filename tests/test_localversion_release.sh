#!/usr/bin/env bash
# A kernel built with CONFIG_LOCALVERSION is installed as <release><suffix>
# (6.12.113-test) while --kernel only knows the kernel.org version, so the
# install path has to ask the configured tree for the release it builds, and
# --uninstall has to offer the suffixed packages instead of failing (#49).
# shellcheck disable=SC2016  # script text is matched with single quotes on purpose
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
# shellcheck disable=SC2317  # invoked through check
not() { ! "$@"; }

funcs=$(sed -n \
  -e '/^kernel_release() {/,/^}/p' \
  -e '/^built_kernelrelease() {/,/^}/p' \
  -e '/^get_linux_full_ver() {/,/^}/p' \
  -e '/^installed_kernel_pkgs_localversion() {/,/^}/p' "$SCRIPT")
for fn in kernel_release built_kernelrelease get_linux_full_ver installed_kernel_pkgs_localversion; do
  grep -q "^${fn}() {" <<<"$funcs" || {
    echo "FAIL: ${fn}() not found in kernel_installer.sh"
    exit 1
  }
done
# shellcheck disable=SC1090
eval "$funcs"

# --- built_kernelrelease: ask the configured tree -------------------------
mkdir -p "$work/bin" "$work/tree"
touch "$work/tree/Makefile"
cat > "$work/bin/make" <<'SHIM'
#!/usr/bin/env bash
printf '%s %s\n' "$PWD" "$*" >> "$MAKE_LOG"
printf '%s\n' "${FAKE_KERNELRELEASE-6.12.113-test}"
SHIM
chmod +x "$work/bin/make"
PATH="$work/bin:$PATH"
export MAKE_LOG="$work/make.log"
export FAKE_KERNELRELEASE=6.12.113-test

check "built_kernelrelease returns the tree release (localversion included)" \
  test "$(built_kernelrelease "$work/tree")" = 6.12.113-test
check "built_kernelrelease runs 'make -s kernelrelease' inside the tree" \
  grep -qF "$work/tree -s kernelrelease" "$MAKE_LOG"

export FAKE_KERNELRELEASE=""
check "built_kernelrelease reports failure when the tree answers nothing" \
  not built_kernelrelease "$work/tree"
check "built_kernelrelease reports failure for a missing tree" \
  not built_kernelrelease "$work/no-such-tree"
unset FAKE_KERNELRELEASE MAKE_LOG

# --- get_linux_full_ver: Makefile fallback, without the localversion ------
cat > "$work/Makefile.plain" <<'EOF'
VERSION = 6
PATCHLEVEL = 12
SUBLEVEL = 113
EXTRAVERSION =
NAME = Baby Opossum Posse
EOF
cat > "$work/Makefile.rc" <<'EOF'
VERSION = 7
PATCHLEVEL = 3
SUBLEVEL = 0
EXTRAVERSION = -rc7
NAME = Baby Opossum Posse
EOF
check "get_linux_full_ver ignores an empty EXTRAVERSION" \
  test "$(get_linux_full_ver "$work/Makefile.plain")" = 6.12.113
check "get_linux_full_ver keeps -rc suffixes" \
  test "$(get_linux_full_ver "$work/Makefile.rc")" = 7.3.0-rc7
check "kernel_release turns the Makefile version into the release" \
  test "$(kernel_release "$(get_linux_full_ver "$work/Makefile.plain")")" = 6.12.113

# --- installed_kernel_pkgs_localversion: find suffixed packages -----------
export DISTRO_GROUP=Debian
# shellcheck disable=SC2317,SC2329  # shim for the helper, invoked indirectly
dpkg-query() {
  printf '%s\n' linux-image-6.12.113 linux-image-6.12.113-test \
    linux-headers-6.12.113-test linux-image-6.12.113-2-test \
    linux-image-6.12.1131 linux-image-6.11.0-amd64
}
check "Debian: the -test kernel and headers are matched" \
  test "$(installed_kernel_pkgs_localversion linux-image 6.12.113)" = "$(printf 'linux-image-6.12.113\nlinux-image-6.12.113-2-test\nlinux-image-6.12.113-test' | sort -u)"
check "Debian: headers are matched by their own name" \
  test "$(installed_kernel_pkgs_localversion linux-headers 6.12.113)" = linux-headers-6.12.113-test
check "Debian: a longer version (6.12.1131) is not a suffix" \
  not grep -q '6.12.1131' < <(installed_kernel_pkgs_localversion linux-image 6.12.113)
check "Debian: an unrelated kernel is not matched" \
  not grep -q '6.11.0' < <(installed_kernel_pkgs_localversion linux-image 6.12.113)
check "Debian: no match yields no output" \
  test -z "$(installed_kernel_pkgs_localversion linux-image 9.9.9)"

DISTRO_GROUP=RHEL
# shellcheck disable=SC2317,SC2329  # shim for the helper, invoked indirectly
rpm() {
  printf '%s\n' kernel-6.12.113_test kernel-devel-6.12.113_test \
    kernel-6.12.113-200.fc44.x86_64 kernel-6.12.1131
}
check "RHEL: the _-rewritten rpm version is matched" \
  test "$(installed_kernel_pkgs_localversion kernel 6.12.113)" = "$(printf 'kernel-6.12.113-200.fc44.x86_64\nkernel-6.12.113_test' | sort -u)"
check "RHEL: kernel-devel is matched by its own name" \
  test "$(installed_kernel_pkgs_localversion kernel-devel 6.12.113)" = kernel-devel-6.12.113_test

# --- call sites ----------------------------------------------------------
phase6=$(awk '/Grab version numbers from Makefile/,/log_info "Kernel release: /' "$SCRIPT")
chk=$(sed -n '/^chk_kernel() {/,/^}/p' "$SCRIPT")
# shellcheck disable=SC2016
uninstall=$(sed -n '/^if \[ "\$mode" = "uninstall" \]; then/,/^fi$/p' "$SCRIPT")

check "phase 6 asks the configured tree for the release it builds" \
  grep -qF 'built_kernelrelease "$INSTALL_DIR/linux-${LINUX_VER}"' <<<"$phase6"
check "phase 6 uses the tree release over the Makefile one" \
  grep -qF 'LINUX_FULL_VER=$BUILT_KERNELRELEASE' <<<"$phase6"
check "phase 6 falls back to the Makefile release when the tree cannot answer" \
  grep -qF 'LINUX_FULL_VER=$(kernel_release "$LINUX_FULL_VER")' <<<"$phase6"
check "built_kernelrelease is defined before its call site" \
  test "$(grep -n '^built_kernelrelease() {' "$SCRIPT" | cut -d: -f1)" \
    -lt "$(grep -n 'built_kernelrelease "$INSTALL_DIR' "$SCRIPT" | cut -d: -f1)"

check "uninstall offers localversion packages when the exact name is missing" \
  grep -qF 'installed_kernel_pkgs_localversion "$name" "$uninstall_release"' <<<"$uninstall"
check "uninstall removes them only after the user confirms" \
  grep -q 'ask YESNO' <<<"$uninstall"
# shellcheck disable=SC2016
check "uninstall still errors out when the user does not confirm" \
  grep -q 'log_error "No installed kernel packages found for ${LINUX_VER}' <<<"$uninstall"

# chk_kernel stays on exact names: a prefix match would also catch unrelated
# distribution kernels and abort a build that installs next to them.
check "chk_kernel does not prefix-match installed kernels" \
  not grep -q 'installed_kernel_pkgs_localversion' <<<"$chk"

exit "$fail"

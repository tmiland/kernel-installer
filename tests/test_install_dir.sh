#!/usr/bin/env bash
# #62: --dir in a shared folder could leave the build in a folder owned by
# another user (mkdir -p accepts an existing/symlinked path) and an existing
# tarball was trusted without verification.
# #69: deleting the build tree could remove the marker first (btrfs), so an
# interrupted cleanup left a folder the next run refused to reuse.
# Runs unprivileged; ownership/symlink cases use only paths the test can make.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

funcs=$(sed -n -e '/^is_safe_install_dir() {/,/^}/p' \
  -e '/^remove_install_dir() {/,/^}/p' \
  -e '/^prepare_install_dir() {/,/^}/p' "$SCRIPT")
for name in is_safe_install_dir remove_install_dir prepare_install_dir; do
  if ! grep -q "^${name}() {" <<<"$funcs"; then
    echo "FAIL: ${name}() not found in kernel_installer.sh"
    exit 1
  fi
done
eval "$funcs"
INSTALL_DIR_MARKER=.kernel_installer

# 1. Normal cleanup removes the whole tree, marker included.
d="$work/normal"
mkdir -p "$d/sub/deeper"
touch "$d/$INSTALL_DIR_MARKER" "$d/sub/file" "$d/sub/deeper/file"
check "cleanup removes the tree" remove_install_dir "$d"
check "cleanup removed the directory" not test -e "$d"

# 2. An interrupted delete keeps the marker, so the next run can retry: a
#    failing find must not be followed by removing the marker.
d="$work/interrupted"
mkdir -p "$d"
touch "$d/$INSTALL_DIR_MARKER" "$d/file"
out=$(
  # shellcheck disable=SC2329
  find() { return 1; }
  eval "$funcs"
  INSTALL_DIR_MARKER=.kernel_installer
  remove_install_dir "$d" >/dev/null 2>&1
  echo "rc=$?"
)
check "interrupted cleanup reports failure ($out)" grep -q 'rc=1' <<<"$out"
check "interrupted cleanup keeps the marker" test -e "$d/$INSTALL_DIR_MARKER"

# 3. prepare_install_dir creates a fresh directory with the marker.
parent="$work/fresh"
mkdir -p "$parent"
chmod 0755 "$parent"
( fatal() { echo "FATAL $1"; exit 1; }; eval "$funcs"; INSTALL_DIR_MARKER=.kernel_installer; INSTALL_DIR="$parent/linux-kernel"; prepare_install_dir ) >"$work/fresh.out" 2>&1
check "fresh directory created" test -d "$parent/linux-kernel"
check "fresh directory has the marker" test -e "$parent/linux-kernel/$INSTALL_DIR_MARKER"
check "fresh directory is not group/other writable" test "$(find "$parent/linux-kernel" -maxdepth 0 -perm /022 -print)" = ""

# 4. A symlink at the build path is refused, and its target is untouched.
victim="$work/victim"
mkdir -p "$victim"
printf 'keep\n' > "$victim/file"
parent="$work/symlink-parent"
mkdir -p "$parent"
chmod 0755 "$parent"
ln -s "$victim" "$parent/linux-kernel"
( fatal() { echo "FATAL $1"; exit 1; }; eval "$funcs"; INSTALL_DIR_MARKER=.kernel_installer; INSTALL_DIR="$parent/linux-kernel"; prepare_install_dir ) >"$work/symlink.out" 2>&1
rc=$?
check "symlink build path is refused (rc=$rc)" test "$rc" -ne 0
check "symlink target was not touched" grep -qx keep "$victim/file"

# 5. A non-empty folder without the marker is refused (existing behaviour).
parent="$work/notempty"
mkdir -p "$parent/linux-kernel"
chmod 0755 "$parent"
touch "$parent/linux-kernel/someone-elses-file"
( fatal() { echo "FATAL $1"; exit 1; }; eval "$funcs"; INSTALL_DIR_MARKER=.kernel_installer; INSTALL_DIR="$parent/linux-kernel"; prepare_install_dir ) >"$work/notempty.out" 2>&1
rc=$?
check "non-empty unmarked folder is refused (rc=$rc)" test "$rc" -ne 0
check "non-empty unmarked folder was not deleted" test -e "$parent/linux-kernel/someone-elses-file"

# 6. A group-writable, non-sticky parent is refused; a sticky shared parent is
#    allowed (the build folder itself is root/user-owned and 0755).
parent="$work/shared"
mkdir -p "$parent"
chmod 0777 "$parent"
( fatal() { echo "FATAL $1"; exit 1; }; eval "$funcs"; INSTALL_DIR_MARKER=.kernel_installer; INSTALL_DIR="$parent/linux-kernel"; prepare_install_dir ) >"$work/shared.out" 2>&1
rc=$?
check "group-writable non-sticky parent is refused (rc=$rc)" test "$rc" -ne 0
chmod 1777 "$parent"
( fatal() { echo "FATAL $1"; exit 1; }; eval "$funcs"; INSTALL_DIR_MARKER=.kernel_installer; INSTALL_DIR="$parent/linux-kernel"; prepare_install_dir ) >"$work/sticky.out" 2>&1
rc=$?
check "sticky shared parent is allowed (rc=$rc)" test "$rc" -eq 0
check "sticky parent build directory exists" test -d "$parent/linux-kernel"

# 7. The install path must not create the directory with mkdir -p, and the
#    installer must use the helpers at every delete site.
body=$(sed -n '/^install_kernel() {/,/^}/p' "$SCRIPT")
check "install_kernel uses prepare_install_dir" grep -q '^  prepare_install_dir$' <<<"$body"
check "install_kernel no longer runs mkdir -p on INSTALL_DIR" not grep -q 'mkdir -p "\$INSTALL_DIR"' <<<"$body"
check "fatal() uses remove_install_dir" grep -qF 'remove_install_dir "$INSTALL_DIR"' "$SCRIPT"
check "end-of-run cleanup uses remove_install_dir" grep -qF 'remove_install_dir "$INSTALL_DIR"' "$SCRIPT"

# 8. An existing tarball must never be treated as already verified.
verify=$(sed -n '/^get_verified_tarball() {/,/^}/p' "$SCRIPT")
check "get_verified_tarball no longer skips an existing tarball" not grep -q 'Skipping download' <<<"$verify"
check "get_verified_tarball has no early return for an existing file" not grep -q 'already exists' <<<"$verify"

exit "$fail"

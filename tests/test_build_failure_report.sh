#!/usr/bin/env bash
# A failed kernel build must point at the first real error in the build
# output, not at the tail of make's generic "Error 2" lines (issue #12: a gcc
# crash at line 95826 of the log was never shown, so it was blamed on amdgpu
# and on disk space). Runs report_build_failure against synthetic logs.
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
has() { grep -qF -- "$1" "$work/out"; }
# shellcheck disable=SC2329  # invoked through check
not_has() { ! has "$1"; }
# shellcheck disable=SC2329  # invoked through check
not() { ! "$@"; }

func=$(sed -n '/^report_build_failure() {/,/^}/p' "$SCRIPT")
if [ -z "$func" ]; then
  echo "FAIL: report_build_failure() not found in kernel_installer.sh"
  exit 1
fi

# report <log file> <build start line>: run the function, output in $work/out
report() {
  (
    # shellcheck disable=SC2034  # read by the eval'd function
    RUN_LOG=$1 INSTALL_DIR=/opt/linux-kernel
    # shellcheck disable=SC2329
    log_error() { echo "[ERROR] $1"; }
    eval "$func"
    report_build_failure "$2"
  ) > "$work/out" 2>&1
  cat "$work/out" >> "$work/all"
}

# The tail of every failing build: make and dpkg-buildpackage noise only
tail_noise() {
  cat <<'EOF'
  AR      drivers/gpu/built-in.a
make[4]: *** [scripts/Makefile.build:500: drivers] Error 2
make[3]: *** [Makefile:1992: .] Error 2
make[2]: *** [debian/rules:7: build-arch] Error 2
dpkg-buildpackage: error: debian/rules binary subprocess returned exit status 2
make[1]: *** [scripts/Makefile.package:86: bindeb-pkg] Error 2
make: *** [Makefile:1636: bindeb-pkg] Error 2
EOF
}
# Lines before the build (download/unpack); includes error-like text that
# must be ignored because it is before the build start
{
  echo "--2023-01-10 15:47:43--  https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.4.tar.xz"
  echo "earlier.c:1:1: error: this is before the build and must be ignored"
} > "$work/pre"
pre_lines=$(wc -l < "$work/pre")

# 1. Issue #12: gcc crash buried in the middle of a parallel build
{
  cat "$work/pre"
  for i in $(seq 200); do echo "  CC [M]  drivers/net/wireless/file$i.o"; done
  echo "during GIMPLE pass: fre"
  echo "drivers/media/pci/cx18/cx18-i2c.c: In function 'init_cx18_i2c':"
  echo "drivers/media/pci/cx18/cx18-i2c.c:300:1: internal compiler error: Segmentation fault"
  echo "  300 | }"
  for i in $(seq 200); do echo "  CC [M]  drivers/gpu/drm/amd/amdgpu/file$i.o"; done
  tail_noise
} > "$work/ice.log"
ice_line=$(grep -n 'internal compiler error' "$work/ice.log" | cut -d: -f1)
report "$work/ice.log" "$pre_lines"
check "ICE: reports the compiler crash with its log line" has "line ${ice_line}):"
check "ICE: shows the crash line itself" has "cx18-i2c.c:300:1: internal compiler error: Segmentation fault"
check "ICE: shows the 'In function' context above it" has "In function 'init_cx18_i2c'"
check "ICE: explains that the compiler crashed" has "The compiler itself crashed"
check "ICE: does not report make's tail as the error" not_has "make[4]: *** [scripts/Makefile.build:500: drivers] Error 2"
check "ICE: says the build tree is kept" has "build tree is kept in /opt/linux-kernel"

# 2. Missing trusted-keys certificate (Ubuntu-family configs)
{
  cat "$work/pre"
  echo "  CC      kernel/fork.o"
  echo "make[6]: *** No rule to make target 'debian/canonical-certs.pem', needed by 'certs/x509_certificate_list'.  Stop."
  tail_noise
} > "$work/certs.log"
report "$work/certs.log" "$pre_lines"
check "certs: shows the missing certificate" has "No rule to make target 'debian/canonical-certs.pem'"
check "certs: suggests clearing SYSTEM_TRUSTED_KEYS" has "--set-str SYSTEM_TRUSTED_KEYS"

# 3. Disk full
{
  cat "$work/pre"
  echo "  CC      fs/ext4/inode.o"
  echo "fs/ext4/inode.c:6200:1: fatal error: error writing to /tmp/ccA1b2.s: No space left on device"
  tail_noise
} > "$work/disk.log"
report "$work/disk.log" "$pre_lines"
check "disk: shows the write error" has "No space left on device"
check "disk: says the disk is full" has "is full"

# 4. Ordinary compile error: shown, no misleading hint
{
  cat "$work/pre"
  echo "drivers/foo/bar.c:12:5: error: 'baz' undeclared (first use in this function)"
  tail_noise
} > "$work/plain.log"
report "$work/plain.log" "$pre_lines"
check "plain: shows the compile error" has "drivers/foo/bar.c:12:5: error: 'baz' undeclared"
check "plain: no hint for an ordinary error" not_has "Hint:"
check "plain: the error before the build start is ignored" not_has "this is before the build"
check "plain: the report runs to the end" has "build tree is kept in /opt/linux-kernel"

# 5. Only make/dpkg noise: say so instead of quoting the noise as the error
{ cat "$work/pre"; tail_noise; } > "$work/none.log"
report "$work/none.log" "$pre_lines"
check "none: says no error message was found" has "no error message was found"
check "none: the report runs to the end" has "build tree is kept in /opt/linux-kernel"
check "no case printed a shell error" not grep -qE 'unbound variable|syntax error|command not found' "$work/all"

# run_ok's own log lines, appended after the build output (real shape)
script_lines() {
  cat <<'EOF'
Compiling The Linux Kernel source code...: [2026-10-16 14:43:48 PDT] [ERROR] Failed with error: 2
[2026-10-16 14:43:48 PDT] [ERROR] Kernel build failed. First error in the build output (x, line 1):
EOF
}

# 6. Missing program, as with gawk on Ubuntu (dash), bash, and make exec
for variant in '/bin/sh: 1: gawk: not found' '/bin/sh: line 1: gawk: command not found' 'make[5]: gawk: No such file or directory'; do
  {
    cat "$work/pre"
    echo "  GEN     modules.builtin.ranges"
    echo "$variant"
    echo "make[5]: *** [scripts/Makefile.vmlinux:51: modules.builtin.ranges] Error 127"
    tail_noise
    script_lines
  } > "$work/missing.log"
  report "$work/missing.log" "$pre_lines"
  check "missing program ($variant): shown" has "$variant"
  check "missing program ($variant): hint says it is not installed" has "is not installed"
done

# 7. Missing header: shown, but it is not a missing program
{
  cat "$work/pre"
  echo "drivers/foo/bar.c:3:10: fatal error: linux/nope.h: No such file or directory"
  tail_noise
} > "$work/header.log"
report "$work/header.log" "$pre_lines"
check "missing header: shown" has "fatal error: linux/nope.h: No such file or directory"
check "missing header: no missing-program hint" not_has "is not installed"

# 8. Only make noise followed by run_ok's own lines ("Failed with error: 2"
#    contains "error:"): must not be quoted as the build error
{ cat "$work/pre"; tail_noise; script_lines; } > "$work/self.log"
report "$work/self.log" "$pre_lines"
check "script's own log lines are not reported as the error" has "no error message was found"

# 9. A TMPDIR that vanished mid-build: mktemp fails, and make's tail must not
#    be quoted instead (#48, the local-TMPDIR regression)
{
  cat "$work/pre"
  echo "  CC      kernel/fork.o"
  echo "mktemp: failed to create file via template '/tmp/ki-tmpdir-test/linux-kernel/linux-tarball-verify.XXXXXX.untrusted/cpiolist.XXXXXX': No such file or directory"
  echo "make[6]: *** [usr/Makefile:76: usr/initramfs_data.cpio] Error 1"
  tail_noise
  script_lines
} > "$work/mktemp.log"
mktemp_line=$(grep -n "failed to create file via template" "$work/mktemp.log" | cut -d: -f1)
report "$work/mktemp.log" "$pre_lines"
check "mktemp: reports the failed mktemp with its log line" has "line ${mktemp_line}):"
check "mktemp: shows the mktemp line itself" has "failed to create file via template"
check "mktemp: does not quote make's final tail as the error" not_has "bindeb-pkg] Error 2"

# Call sites
body=$(sed -n '/^install_kernel() {/,/^}/p' "$SCRIPT")
# shellcheck disable=SC2016  # literal script text
check "the build failure is handled by report_build_failure" grep -qF 'report_build_failure "$build_log_start"' <<<"$body"
check "a failed build subshell ends the run" grep -qE '^    \) \|\| exit 1' <<<"$body"
check "the tarball is unpacked without -v" not grep -q 'tar xvf' <<<"$body"
check "install_kernel logs the diagnostics header" grep -q '^  log_diagnostics$' <<<"$body"

exit "$fail"

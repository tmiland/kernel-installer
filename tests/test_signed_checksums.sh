#!/usr/bin/env bash
# #67: gpgv reports a good signature for a clearsigned sha256sums.asc even
# when text is appended after the signature block. The script grepped the raw
# file, so an appended, unsigned checksum line could be used. It must read the
# checksum from gpgv's verified output only.
# Offline: curl, gpg and gpgv are fakes; sha256sum and the tarball bytes are
# real, and the "appended" line carries a wrong hash for the same file name.
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

mkdir -p "$work/bin" "$work/dir" "$work/can"
# Real tarball bytes; the signed line gets their real hash, the unsigned line
# gets a deliberately wrong one.
printf 'not really an xz stream\n' > "$work/can/linux-6.12.113.tar.xz"
good=$(sha256sum "$work/can/linux-6.12.113.tar.xz" | cut -d' ' -f1)
bad=0000000000000000000000000000000000000000000000000000000000000000
printf '%s  linux-6.12.113.tar.xz\n' "$good" > "$work/can/signed.txt"
cp "$work/can/signed.txt" "$work/can/sha256sums.asc"
printf '%s  linux-6.12.113.tar.xz\n' "$bad" >> "$work/can/sha256sums.asc"
: > "$work/can/tar.asc"

# Fake curl: copy the canned file selected by the URL to the -o destination.
cat > "$work/bin/curl" <<'EOF'
#!/bin/sh
dest=''; url=''
while [ $# -gt 0 ]; do
  case $1 in
    -o) dest=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case $url in
  *sha256sums.asc) cp "$CAN/sha256sums.asc" "$dest" ;;
  *linux-6.12.113.tar.sign) cp "$CAN/tar.asc" "$dest" ;;
  *linux-6.12.113.tar.xz) cp "$CAN/linux-6.12.113.tar.xz" "$dest" ;;
  *) exit 1 ;;
esac
EOF

# Fake gpgv: always report a good signature; when --output is given, write
# only the signed content (the real gpgv does exactly that).
cat > "$work/bin/gpgv" <<'EOF'
#!/bin/sh
out=''
while [ $# -gt 0 ]; do
  case $1 in
    --output) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '[GNUPG:] GOODSIG 0000000000000000 Test\n'
printf '[GNUPG:] VALIDSIG 0000000000000000 2026-01-01\n'
if [ -n "$out" ]; then cat "$SIGNED_CONTENT" > "$out"; fi
exit 0
EOF
cat > "$work/bin/gpg" <<'EOF'
#!/bin/sh
# Fingerprint selection is exercised by test_gpg_key_selection.sh; here the
# fake only needs to return one primary fingerprint for each exact address.
case " $* " in
  *" --list-keys "*) printf 'pub:u:1:1:0:0:0:0:0:0:0:::::\nfpr:::::::::0000000000000000000000000000000000000000:\n' ;;
  *) : ;;
esac
exit 0
EOF
# Fake xz so the signature pipeline has a sane producer (its output is ignored).
cat > "$work/bin/xz" <<'EOF'
#!/bin/sh
for last; do :; done
cat "$last"
EOF
# get_verified_tarball prefers gpg2/gpgv2. CI images have real ones, so point
# those names at the fakes too instead of falling through to the host tools.
cp "$work/bin/gpg" "$work/bin/gpg2"
cp "$work/bin/gpgv" "$work/bin/gpgv2"
chmod +x "$work/bin/curl" "$work/bin/gpg" "$work/bin/gpgv" "$work/bin/xz" "$work/bin/gpg2" "$work/bin/gpgv2"

# Point the function's hard-coded helpers at the fakes.
funcs=$(sed -n -e '/^key_fingerprints() {/,/^}/p' -e '/^verify_fail() {/,/^}/p' -e '/^get_verified_tarball() {/,/^}/p' "$SCRIPT" |
  sed "s|/usr/bin/curl|$work/bin/curl|g; s|/usr/bin/xz|$work/bin/xz|g")
for name in key_fingerprints verify_fail get_verified_tarball; do
  grep -q "^${name}() {" <<<"$funcs" || { echo "FAIL: ${name}() not found"; exit 1; }
done

out=$(
  (
    export PATH="$work/bin:$PATH"
    export CAN="$work/can" SIGNED_CONTENT="$work/can/signed.txt"
    # shellcheck disable=SC2329
    log_debug() { :; }
    # shellcheck disable=SC2329
    log_success() { :; }
    # shellcheck disable=SC2329
    INSTALL=false GNUPGHOME='' USEKEYRING=''
    eval "$funcs"
    LINUX_VER=6.12.113 INSTALL_DIR="$work/dir"
    get_verified_tarball
    echo "rc=$? error=${VERIFY_ERROR:-}"
  ) 2>&1
)
rc_line=$(grep -o 'rc=[0-9]*' <<<"$out" | tail -1)
check "verification succeeds with only the signed checksum line ($out)" test "$rc_line" = "rc=0"
check "the verified tarball was installed" test -s "$work/dir/linux-6.12.113.tar.xz"
check "the unsigned appended line was never used" not grep -q "$bad" "$work/dir/linux-6.12.113.tar.xz"

# The raw file really does contain both lines (test instrument check).
check "the test fixture has the unsigned line" grep -q "$bad" "$work/can/sha256sums.asc"
# The source reads gpgv's output file, not the raw clearsigned file.
check "the checksum grep reads the signed output" grep -q 'grep .*"\${SHAFILE_SIGNED}"' "$SCRIPT"
check "gpgv writes the signed content to SHAFILE_SIGNED" grep -q -- '--output "\${SHAFILE_SIGNED}"' "$SCRIPT"
check "the raw SHAFILE is not grepped for the checksum" not grep -q 'grep .*linux-\${LINUX_VER}.tar.xz"\s*\${SHAFILE}' "$SCRIPT"

exit "$fail"

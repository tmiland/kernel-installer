#!/usr/bin/env bash
# Secure Boot auto-signing: CLI, key detection, image signing, DKMS wiring.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
# shellcheck disable=SC2317  # invoked through check
not() { ! "$@"; }

out=$(setsid bash "$SCRIPT" --help </dev/null 2>&1)
check "help documents --no-sign" grep -q -- '--no-sign' <<<"$out"

out=$(setsid bash "$SCRIPT" --no-sign --help </dev/null 2>&1)
check "--no-sign is accepted by the parser" grep -q 'Usage:' <<<"$out"

# --- defaults -------------------------------------------------------------
# shellcheck disable=SC2016  # script text, not shell expansion
check "auto-signing is on by default" grep -q '^NO_SIGN=${NO_SIGN:-0}$' "$SCRIPT"
# shellcheck disable=SC2016  # script text, not shell expansion
check "default key is the shim MOK private key" \
  grep -q '^SIGNING_KEY=${SIGNING_KEY:-/var/lib/shim-signed/mok/MOK.priv}$' "$SCRIPT"
# shellcheck disable=SC2016  # script text, not shell expansion
check "default certificate is the MOK DER (what update-secureboot-policy writes)" \
  grep -q '^SIGNING_CERT=${SIGNING_CERT:-/var/lib/shim-signed/mok/MOK.der}$' "$SCRIPT"

no_sign=$(sed -n '/--no-sign)/,/;;/p' "$SCRIPT")
check "--no-sign sets NO_SIGN=1" grep -q 'NO_SIGN=1' <<<"$no_sign"

# --- detection ------------------------------------------------------------
detect=$(sed -n '/^detect_signing() {/,/^}/p' "$SCRIPT")
check "detect_signing reads the key and certificate" \
  grep -q 'SIGNING_KEY' <<<"$detect"
check "detect_signing refuses non-RSA keys (shim cannot verify ECDSA)" \
  grep -q 'rsaEncryption' <<<"$detect"
check "detect_signing checks for sbsign and sbverify" \
  grep -q 'command -v sbsign' <<<"$detect"
check "detect_signing stops when Secure Boot is on and tools are missing" \
  grep -q 'sbsign/sbverify are missing' <<<"$detect"
check "detect_signing is called before the build" \
  test "$(grep -nE '^[[:space:]]*detect_signing$' "$SCRIPT" | head -1 | cut -d: -f1)" \
    -lt "$(grep -n 'build_target=bindeb-pkg' "$SCRIPT" | head -1 | cut -d: -f1)"

# --- signing --------------------------------------------------------------
sign=$(sed -n '/^sign_kernel_image() {/,/^}/p' "$SCRIPT")
check "signer strips an existing signature first" \
  grep -q 'sbattach --remove' <<<"$sign"
check "signer invokes sbsign with key, cert and output" \
  grep -q 'sbsign --key' <<<"$sign"
check "signer verifies the result with sbverify --cert" \
  grep -q 'sbverify --cert' <<<"$sign"
check "signer is called after the kernel package is installed" \
  test "$(grep -n 'sign_installed_kernel ' "$SCRIPT" | head -1 | cut -d: -f1)" \
    -gt "$(grep -n 'Installing Kernel image and headers' "$SCRIPT" | tail -1 | cut -d: -f1)"

# --- DKMS -----------------------------------------------------------------
dkms=$(sed -n '/^ensure_dkms_signing_conf() {/,/^}/p' "$SCRIPT")
check "DKMS drop-in uses the framework.conf.d directory" \
  grep -q '/etc/dkms/framework.conf.d' <<<"$dkms"
check "DKMS drop-in is named secure-boot.conf" grep -q 'secure-boot.conf' <<<"$dkms"
check "DKMS drop-in checks whether dkms reads framework.conf.d" \
  grep -q '/usr/sbin/dkms' <<<"$dkms"
check "DKMS drop-in does not require the dkms command" \
  not grep -q 'command -v dkms' <<<"$dkms"
check "DKMS drop-in sets mok_signing_key" grep -q 'mok_signing_key' <<<"$dkms"
check "DKMS drop-in sets mok_certificate" grep -q 'mok_certificate' <<<"$dkms"
check "DKMS drop-in is ensured before the packages are installed" \
  test "$(grep -nE '^[[:space:]]*ensure_dkms_signing_conf$' "$SCRIPT" | head -1 | cut -d: -f1)" \
    -lt "$(grep -n 'Installing Kernel image and headers' "$SCRIPT" | tail -1 | cut -d: -f1)"

# --- behavior: DKMS drop-in ----------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/dkms"
chmod +x "$tmp/bin/dkms"
ensure_fn=$(sed -n '/^ensure_dkms_signing_conf() {/,/^}/p' "$SCRIPT")
if grep -q 'DKMS_CONF_DIR' <<<"$ensure_fn"; then
  run_ensure() {
    (
      # shellcheck disable=SC2034  # consumed by the extracted function
      SIGNING_ACTIVE=1 SIGNING_KEY=/keys/MOK.priv SIGNING_CERT=/keys/MOK.pem
      DKMS_CONF_DIR="$tmp/dkms"
      PATH="$tmp/bin:$PATH"
      export PATH DKMS_CONF_DIR
      # shellcheck disable=SC2317
      log_debug() { :; }
      # shellcheck disable=SC2317
      log_warning() { :; }
      # shellcheck disable=SC2317
      log_info() { :; }
      eval "$ensure_fn"
      ensure_dkms_signing_conf
    )
  }
  run_ensure
  conf="$tmp/dkms/secure-boot.conf"
  check "DKMS drop-in is created" test -f "$conf"
  check "DKMS drop-in names the signing key" \
    grep -q '^mok_signing_key="/keys/MOK.priv"$' "$conf"
  check "DKMS drop-in names the certificate" \
    grep -q '^mok_certificate="/keys/MOK.pem"$' "$conf"
  before=$(sha256sum "$conf")
  run_ensure
  check "DKMS drop-in is idempotent" test "$before" = "$(sha256sum "$conf")"
  printf 'user-managed\n' >"$conf"
  run_ensure
  check "a different existing drop-in is left untouched" \
    grep -q '^user-managed$' "$conf"
else
  echo "FAIL: ensure_dkms_signing_conf does not honour DKMS_CONF_DIR"
  fail=1
fi

# --- behavior: kernel image signing --------------------------------------
collect_fn=$(sed -n '/^collect_kernel_images() {/,/^}/p' "$SCRIPT")
sign_fn=$(sed -n '/^sign_kernel_image() {/,/^}/p' "$SCRIPT")
wrapper_fn=$(sed -n '/^sign_installed_kernel() {/,/^}/p' "$SCRIPT")
check "collector covers conventional and BLS images" \
  grep -q 'loader/entries' <<<"$collect_fn"
if grep -q 'BOOT_DIR' <<<"$wrapper_fn" &&
  [ -f "/boot/vmlinuz-$(uname -r)" ] &&
  command -v sbsign >/dev/null && command -v sbverify >/dev/null; then
  mkdir -p "$tmp/boot"
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -sha256 \
    -subj "/CN=test-sign" -keyout "$tmp/test.key" -out "$tmp/test.pem" 2>/dev/null
  cp "/boot/vmlinuz-$(uname -r)" "$tmp/boot/vmlinuz-test-sign"
  (
    # shellcheck disable=SC2034  # consumed by the extracted function
    SIGNING_ACTIVE=1 BOOT_DIR="$tmp/boot" SIGNING_KEY="$tmp/test.key" SIGNING_CERT="$tmp/test.pem"
    export BOOT_DIR
    # shellcheck disable=SC2317
    log_success() { :; }
    # shellcheck disable=SC2317
    log_error() { :; }
    eval "$collect_fn"
    eval "$sign_fn"
    eval "$wrapper_fn"
    sign_installed_kernel test-sign
  )
  check "kernel image is signed" \
    sbverify --cert "$tmp/test.pem" "$tmp/boot/vmlinuz-test-sign"
  check "kernel image carries exactly one signature" \
    test "$(sbverify --list "$tmp/boot/vmlinuz-test-sign" | grep -c '^signature')" -eq 1

  # DER certificate (the default): sbsign needs PEM, so the signer converts.
  openssl x509 -in "$tmp/test.pem" -outform DER -out "$tmp/test.der"
  cp "/boot/vmlinuz-$(uname -r)" "$tmp/boot/vmlinuz-test-sign"
  (
    # shellcheck disable=SC2034  # consumed by the extracted function
    SIGNING_ACTIVE=1 BOOT_DIR="$tmp/boot" SIGNING_KEY="$tmp/test.key" SIGNING_CERT="$tmp/test.der"
    export BOOT_DIR
    # shellcheck disable=SC2317
    log_success() { :; }
    # shellcheck disable=SC2317
    log_error() { :; }
    eval "$collect_fn"
    eval "$sign_fn"
    eval "$wrapper_fn"
    sign_installed_kernel test-sign
  )
  check "a DER certificate is accepted" \
    sbverify --cert "$tmp/test.pem" "$tmp/boot/vmlinuz-test-sign"

  # A failed signing must leave the original image byte-identical.
  cp "/boot/vmlinuz-$(uname -r)" "$tmp/boot/vmlinuz-test-sign"
  before=$(sha256sum "$tmp/boot/vmlinuz-test-sign")
  (
    # shellcheck disable=SC2034  # consumed by the extracted function
    SIGNING_ACTIVE=1 BOOT_DIR="$tmp/boot" SIGNING_KEY="$tmp/missing.key" SIGNING_CERT="$tmp/test.pem"
    export BOOT_DIR
    # shellcheck disable=SC2317
    log_success() { :; }
    # shellcheck disable=SC2317
    log_error() { :; }
    eval "$collect_fn"
    eval "$sign_fn"
    eval "$wrapper_fn"
    sign_installed_kernel test-sign
  )
  rc=$?
  check "a signing failure returns non-zero" test "$rc" -ne 0
  check "a signing failure leaves the image untouched" \
    test "$before" = "$(sha256sum "$tmp/boot/vmlinuz-test-sign")"

  # A BLS entry points at its own copy of the kernel; that copy must be signed.
  mkdir -p "$tmp/boot/loader/entries"
  cp "/boot/vmlinuz-$(uname -r)" "$tmp/boot/vmlinuz-test-blscopy"
  printf 'title test\nlinux /vmlinuz-test-blscopy\n' >"$tmp/boot/loader/entries/test-sign.conf"
  (
    # shellcheck disable=SC2034  # consumed by the extracted function
    SIGNING_ACTIVE=1 BOOT_DIR="$tmp/boot" SIGNING_KEY="$tmp/test.key" SIGNING_CERT="$tmp/test.pem"
    export BOOT_DIR
    # shellcheck disable=SC2317
    log_success() { :; }
    # shellcheck disable=SC2317
    log_error() { :; }
    eval "$collect_fn"
    eval "$sign_fn"
    eval "$wrapper_fn"
    sign_installed_kernel test-sign
  )
  check "a BLS entry's kernel is signed" \
    sbverify --cert "$tmp/test.pem" "$tmp/boot/vmlinuz-test-blscopy"
else
  echo "skip: kernel image signing (needs BOOT_DIR support, /boot image and sbsigntool)"
fi

# --- behavior: Secure Boot state handling --------------------------------
sb_fn=$(sed -n '/^secure_boot_enabled() {/,/^}/p' "$SCRIPT")
detect_fn=$(sed -n '/^detect_signing() {/,/^}/p' "$SCRIPT")
if grep -q 'EFIVARS_DIR' <<<"$sb_fn" && grep -q 'secure_boot_enabled' <<<"$detect_fn"; then
  mkdir -p "$tmp/efivars"
  sbvar="$tmp/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  run_detect() {
    (
      # shellcheck disable=SC2034  # consumed by the extracted functions
      EFIVARS_DIR="$tmp/efivars" NO_SIGN="$1" SIGNING_KEY="$tmp/missing.key" SIGNING_CERT="$tmp/missing.der"
      export RED='' BALLOT_X='' NORMAL=''
      # shellcheck disable=SC2317
      log_info() { :; }
      # shellcheck disable=SC2317
      log_debug() { :; }
      # shellcheck disable=SC2317
      log_warning() { :; }
      # shellcheck disable=SC2317
      fatal() { exit 1; }
      eval "$sb_fn"
      eval "$detect_fn"
      detect_signing
    )
  }
  printf '\x06\x00\x00\x00\x01' >"$sbvar"
  run_detect 0
  rc=$?
  check "Secure Boot on + missing key fails instead of skipping" test "$rc" -ne 0
  run_detect 1
  rc=$?
  check "--no-sign bypasses the Secure Boot key requirement" test "$rc" -eq 0
  printf '\x06\x00\x00\x00\x00' >"$sbvar"
  run_detect 0
  rc=$?
  check "Secure Boot off + missing key is a quiet skip" test "$rc" -eq 0
else
  echo "FAIL: detect_signing does not expose EFIVARS_DIR"
  fail=1
fi

# --- error status ---------------------------------------------------------
tail_block=$(sed -n '/The following errors occurred/,$p' "$SCRIPT")
check "installation errors exit non-zero" grep -q '^  exit 1$' <<<"$tail_block"

# --- syntax ---------------------------------------------------------------
check "kernel_installer.sh parses" bash -n "$SCRIPT"

exit "$fail"

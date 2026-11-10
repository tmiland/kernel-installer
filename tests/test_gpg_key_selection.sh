#!/usr/bin/env bash
# #68: gpg --export torvalds@kernel.org matches any UID containing that text,
# and --locate-keys accepts a matching key already in the keyring. Keys must be
# selected by exact address and exported by fingerprint; the default must be a
# throwaway keyring instead of root's ~/.gnupg.
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

if ! command -v gpg >/dev/null 2>&1; then
  echo "skip: gpg not installed"
  exit 0
fi

func=$(sed -n '/^key_fingerprints() {/,/^}/p' "$SCRIPT")
if [ -z "$func" ]; then
  echo "FAIL: key_fingerprints() not found in kernel_installer.sh"
  exit 1
fi
eval "$func"

export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Signer <signer@example.invalid>' default default 0 2>/dev/null
gpg --batch --quiet --passphrase '' --quick-gen-key 'Other <notsigner@example.invalid>' default default 0 2>/dev/null

exact=$(gpg --batch --with-colons --list-keys '<signer@example.invalid>' 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
substring=$(gpg --batch --with-colons --list-keys '<notsigner@example.invalid>' 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
check "test keys are distinct" test -n "$exact" -a -n "$substring" -a "$exact" != "$substring"

gpg --batch --export > "$work/all.gpg"
got=$(key_fingerprints "$(command -v gpg)" "$work/all.gpg" signer@example.invalid)
check "the exact address is selected" grep -qx "$exact" <<<"$got"
check "the substring address is not selected" not grep -qx "$substring" <<<"$got"

got_other=$(key_fingerprints "$(command -v gpg)" "$work/all.gpg" notsigner@example.invalid)
check "the longer address still selects its own key" grep -qx "$substring" <<<"$got_other"

# Static checks: throwaway keyring by default, and final keyrings built from
# exact fingerprints rather than bare addresses.
check "GNUPGHOME defaults to empty (throwaway keyring)" grep -qF 'GNUPGHOME=${GNUPGHOME-}' "$SCRIPT"
check "get_verified_tarball selects fingerprints" grep -qF 'key_fingerprints "${GPGBIN}"' "$SCRIPT"
check "the temporary keyring is exported from GNUPGHOME" grep -qF -- '--homedir "${GNUPGHOME}" --export' "$SCRIPT"
check "SHA keyring is exported by fingerprint" grep -q -- '--export "\${SHA_FPRS\[@\]}"' "$SCRIPT"
check "DEV keyring is exported by fingerprint" grep -q -- '--export "\${DEV_FPRS\[@\]}"' "$SCRIPT"

exit "$fail"

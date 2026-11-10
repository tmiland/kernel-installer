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

func=$(sed -n -e '/^key_fingerprints() {/,/^}/p' -e '/^check_kernel_key_fingerprints() {/,/^}/p' "$SCRIPT")
if [ -z "$func" ]; then
  echo "FAIL: key_fingerprints() not found in kernel_installer.sh"
  exit 1
fi
eval "$func"
# shellcheck disable=SC1091
source <(grep -E '^(TORVALDS_FPR|GREGKH_FPR|AUTOSIGNER_FPR)=' "$SCRIPT")

export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Signer <signer@example.invalid>' default default 0 2>/dev/null
gpg --batch --quiet --passphrase '' --quick-gen-key 'Other <notsigner@example.invalid>' default default 0 2>/dev/null

exact=$(gpg --batch --with-colons --list-keys '<signer@example.invalid>' 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
substring=$(gpg --batch --with-colons --list-keys '<notsigner@example.invalid>' 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
check "test keys are distinct" test -n "$exact" -a -n "$substring" -a "$exact" != "$substring"

gpg --batch --export > "$work/all.gpg"
got=$(key_fingerprints "$(command -v gpg)" "$GNUPGHOME" signer@example.invalid)
check "the exact address is selected" grep -qx "$exact" <<<"$got"
check "the substring address is not selected" not grep -qx "$substring" <<<"$got"

got_other=$(key_fingerprints "$(command -v gpg)" "$GNUPGHOME" notsigner@example.invalid)
check "the longer address still selects its own key" grep -qx "$substring" <<<"$got_other"

# A custom USEKEYRING is imported into a private homedir before selection.
imported="$work/imported"
mkdir -m 0700 "$imported"
gpg --batch --homedir "$imported" --import "$work/all.gpg" 2>/dev/null
got_imported=$(key_fingerprints "$(command -v gpg)" "$imported" signer@example.invalid)
check "an imported keyring keeps the exact-address selection" grep -qx "$exact" <<<"$got_imported"

# The bundled kernel.org keys match the pinned fingerprints.
bundle="$REPO/src/keys/kernel.org.asc"
check "the bundled keyring exists" test -f "$bundle"
check "the bundled keyring has no private keys" not grep -q 'BEGIN PGP PRIVATE' "$bundle"
bundle_home="$work/bundle-home"
mkdir -m 0700 "$bundle_home"
gpg --batch --homedir "$bundle_home" --import "$bundle" 2>/dev/null
check "the bundled keys match the pinned fingerprints" check_kernel_key_fingerprints "$(command -v gpg)" "$bundle_home"
empty_home="$work/empty-home"
mkdir -m 0700 "$empty_home"
check "an empty homedir does not pass the pin check" not check_kernel_key_fingerprints "$(command -v gpg)" "$empty_home"

# Static checks: throwaway keyring by default, and final keyrings built from
# exact fingerprints rather than bare addresses.
check "GNUPGHOME defaults to empty (throwaway keyring)" grep -qF 'GNUPGHOME=${GNUPGHOME-}' "$SCRIPT"
check "get_verified_tarball selects fingerprints" grep -qF 'key_fingerprints "${GPGBIN}" "${keyring_home}"' "$SCRIPT"
check "the trusted keyring is exported from its homedir" grep -qF -- '--homedir "${keyring_home}"' "$SCRIPT"
check "custom USEKEYRING is imported into a homedir" grep -qF -- '--import "${USEKEYRING}"' "$SCRIPT"
check "key selection lists from a homedir, not a keyring file" grep -qF -- '--homedir "${homedir}" --with-colons --list-keys' "$SCRIPT"
check "checkout runs use the bundled keyring" grep -qF -- '-f "${SCRIPT_DIR}/${KERNEL_KEYRING_FILE}"' "$SCRIPT"
check "the pinned fingerprints are checked" grep -qF 'check_kernel_key_fingerprints "${GPGBIN}" "${keyring_home}"' "$SCRIPT"
check "SHA keyring is exported by fingerprint" grep -q -- '--export "\${SHA_FPRS\[@\]}"' "$SCRIPT"
check "DEV keyring is exported by fingerprint" grep -q -- '--export "\${DEV_FPRS\[@\]}"' "$SCRIPT"

exit "$fail"

#!/usr/bin/env bash
# #66: --update replaced the script with whatever the first release asset was,
# without a checksum; v1.3.0 has no assets at all.
# #72: the download went to /tmp and was moved across filesystems, so an
# interrupted update could leave a truncated script. A piped run has no file to
# replace and must be refused.
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

helpers=$(sed -n -e '/^release_asset_url() {/,/^}/p' \
  -e '/^checksum_for_asset() {/,/^}/p' \
  -e '/^verify_sha256() {/,/^}/p' "$SCRIPT")
for name in release_asset_url checksum_for_asset verify_sha256; do
  grep -q "^${name}() {" <<<"$helpers" || { echo "FAIL: ${name}() not found"; exit 1; }
done
eval "$helpers"

json='[
  {"browser_download_url": "https://github.com/tmiland/kernel-installer/releases/download/v1.3.1/SHA256SUMS"},
  {"browser_download_url": "https://github.com/tmiland/kernel-installer/releases/download/v1.3.1/kernel_installer.sh"}
]'
url=$(release_asset_url "$json" '\.sh"')
check "the .sh asset is selected, not the first URL ($url)" test "$url" = "https://github.com/tmiland/kernel-installer/releases/download/v1.3.1/kernel_installer.sh"
sums_url=$(release_asset_url "$json" '(SHA256SUMS|sha256sums)')
check "the checksum asset is selected ($sums_url)" test "$sums_url" = "https://github.com/tmiland/kernel-installer/releases/download/v1.3.1/SHA256SUMS"
check "a missing asset yields an empty URL" test -z "$(release_asset_url "$json" '\.rpm"')"

printf 'hello\n' > "$work/file"
real=$(sha256sum "$work/file" | cut -d' ' -f1)
sums="$real  kernel_installer.sh
deadbeef  linux-1.0.tar.xz"
check "the checksum for the script is found" test "$(checksum_for_asset "$sums" kernel_installer.sh)" = "$real"
check "the *binary* checksum form is found" test "$(checksum_for_asset "abc  *kernel_installer.sh" kernel_installer.sh)" = abc
check "a missing file name yields nothing" test -z "$(checksum_for_asset "$sums" other.sh)"
check "a correct hash verifies" verify_sha256 "$work/file" "$real"
check "a wrong hash is rejected" not verify_sha256 "$work/file" deadbeef

func=$(sed -n '/^update_updater () {/,/^}/p' "$SCRIPT")
if [ -z "$func" ]; then
  echo "FAIL: update_updater() not found"
  exit 1
fi

# A piped run has no script file to replace and must be refused before network.
out=$( ( log_error() { echo "$1"; }; self=''; SCRIPT_FILENAME=''; eval "$func"; update_updater ) 2>&1 )
rc=$?
check "piped --update is refused (rc=$rc)" test "$rc" -eq 1
check "the piped refusal is explained" grep -qi 'not a file\|piped' <<<"$out"

# The new script is created next to the script (same filesystem) and checked
# before it is moved over the running file.
check "the update temp file is next to the script" grep -qF '${SCRIPT_DIR}/.${SCRIPT_FILENAME}.XXXXXX' <<<"$func"
check "download_file uses the mktemp template" grep -qF 'mktemp "$template"' <<<"$func"
check "the update requires a checksum file" grep -q 'CHECKSUMS_URL' <<<"$func"
n_verify=$(grep -n 'verify_sha256' <<<"$func" | head -1 | cut -d: -f1)
n_move=$(grep -n 'mv -f -- "\$tmpfile"' <<<"$func" | head -1 | cut -d: -f1)
# shellcheck disable=SC2329
verify_before_move() { [ -n "$n_verify" ] && [ -n "$n_move" ] && [ "$n_verify" -lt "$n_move" ]; }
check "the checksum is verified before the move (${n_verify:-?} < ${n_move:-?})" verify_before_move
check "the new file is made executable" grep -q 'chmod 0755 "\$tmpfile"' <<<"$func"

# The release workflow must publish both assets (this also backfills v1.3.0).
wf="$REPO/.github/workflows/release.yml"
check "the release workflow exists" test -f "$wf"
check "the release workflow uploads the script and checksums" grep -q 'kernel_installer.sh SHA256SUMS' "$wf"

exit "$fail"

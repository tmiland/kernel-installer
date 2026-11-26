#!/usr/bin/env bash
# --cachyos-latest: flag validation and latest stable release resolution.
# shellcheck disable=SC2317  # helpers are invoked through check
# shellcheck disable=SC2016  # script text is matched with single quotes
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/kernel_installer.sh"
fail=0
check() {
  local desc=$1; shift
  if "$@"; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}

out=$(setsid bash "$SCRIPT" --cachyos-latest --source vanilla </dev/null 2>&1)
check "latest requires the CachyOS source" \
  grep -q 'requires --source cachyos' <<<"$out"

out=$(setsid bash "$SCRIPT" --help </dev/null 2>&1)
check "help documents --cachyos-latest" \
  grep -q -- '--cachyos-latest' <<<"$out"

# --- resolve_cachyos_latest ----------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/curl" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"tag_name": "cachyos-7.4-rc4-1"}
{"tag_name": "cachyos-7.3.6-2"}
{"tag_name": "cachyos-7.3.5-1"}
{"tag_name": "cachyos-6.18.65-1"}
JSON
SH
chmod +x "$work/curl"
func=$(sed -n '/^resolve_cachyos_latest() {/,/^}/p' "$SCRIPT")
[ -n "$func" ] || { echo "FAIL: resolve_cachyos_latest() not found"; exit 1; }
# shellcheck disable=SC1090
eval "$func"
fatal() { echo "FATAL: $*" >&2; return 1; }
log_info() { :; }
CACHYOS_LATEST=1 CURLBIN="$work/curl" resolve_cachyos_latest
check "latest picks the highest stable release" test "$CACHYOS_VERSION" = 7.3.6
check "latest parses the tag release" test "$CACHYOS_TAGREL" = 2
check "latest names the source tag" test "$CACHYOS_SRCNAME" = cachyos-7.3.6-2
check "latest source URL uses the tag" \
  grep -q 'cachyos-7.3.6-2.tar.gz' <<<"$CACHYOS_SOURCE_URL"
check "latest derives the 7.3 patch path" \
  grep -q '/7.3/sched/0001-bore-cachy.patch' <<<"$CACHYOS_BORE_PATCH_URL"
check "latest derives the BMQ patch path" \
  grep -q '/7.3/sched/0001-prjc-cachy.patch' <<<"$CACHYOS_BMQ_PATCH_URL"
check "latest leaves the config SHA unpinned" test -z "$CACHYOS_CONFIG_SHA256"
check "latest leaves the BORE SHA unpinned" test -z "$CACHYOS_BORE_PATCH_SHA256"
check "latest leaves the BMQ SHA unpinned" test -z "$CACHYOS_BMQ_PATCH_SHA256"

exit "$fail"

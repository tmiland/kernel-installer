#!/usr/bin/env bash
#------------------------------------------------------------------------------
# update-slib.sh - vendor a new src/slib.sh and update the pinned fallback
#
# kernel_installer.sh sources src/slib.sh when running from a checkout and
# otherwise falls back to a pinned, checksum-verified copy (SLIB_REV and
# SLIB_SHA256 in kernel_installer.sh). Updating slib is a two-phase process:
#
#   Phase 1 (vendor):
#     scripts/update-slib.sh
#     Fetches slib.sh, re-applies the local log tweak when possible and writes
#     src/slib.sh. Commit and push src/slib.sh (or merge the PR).
#
#   Phase 2 (pin):
#     scripts/update-slib.sh --finalize <commit>
#     <commit> is the pushed commit containing the new src/slib.sh. Points
#     SLIB_REV at it and refreshes SLIB_SHA256. Commit and push
#     kernel_installer.sh.
#
# Until phase 2 lands on main, the "slib pin" CI job fails (by design).
#
# Note: src/slib.sh is a curated subset of virtualmin/slib. Sources fetched
# from the fork or upstream contain extra Virtualmin-only helpers, so review
# `git diff src/slib.sh` before committing.
#------------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname -- "$SCRIPT_DIR")
SLIB_FILE="$REPO_DIR/src/slib.sh"
INSTALLER="$REPO_DIR/kernel_installer.sh"

SOURCE="tmiland/slib"
REF="master"
APPLY_PATCH=1
FINALIZE=""
TMPFILE=""

die() { echo "error: $*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

cleanup() {
  if [ -n "$TMPFILE" ]; then
    rm -f "$TMPFILE" "$TMPFILE.bak"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: scripts/update-slib.sh [options]

Vendors src/slib.sh and updates the pinned fallback (SLIB_REV, SLIB_SHA256)
in kernel_installer.sh.

Options:
  -s, --source <owner/repo>   Source repository (default: tmiland/slib)
  -r, --ref <ref>             Branch, tag or commit (default: master)
      --no-patch              Do not re-apply the local log tweak
      --finalize <commit>     Phase 2: pin SLIB_REV to <commit> and refresh
                              SLIB_SHA256 from the current src/slib.sh
  -h, --help                  Show this help

Two-phase update:
  Phase 1: scripts/update-slib.sh
           git add src/slib.sh && git commit && git push
  Phase 2: scripts/update-slib.sh --finalize <commit>
           git add kernel_installer.sh && git commit && git push
EOF
}

file_sha() { sha256sum "$1" | cut -d' ' -f1; }

set_installer_value() {
  local key=$1 value=$2 count
  count=$(grep -cE "^${key}=\"" "$INSTALLER" || true)
  [ "$count" -eq 1 ] || die "expected exactly one ${key}=\"...\" line in kernel_installer.sh, found $count"
  sed -i.bak -E "s|^${key}=\".*\"\$|${key}=\"${value}\"|" "$INSTALLER"
  rm -f "$INSTALLER.bak"
}

finalize() {
  local commit=$1 repo local_sha remote_sha url actual
  git -C "$REPO_DIR" rev-parse --verify --quiet "${commit}^{commit}" >/dev/null \
    || die "commit '$commit' not found in this repository (fetch or push it first)"

  local_sha=$(file_sha "$SLIB_FILE")
  remote_sha=$(git -C "$REPO_DIR" show "${commit}:src/slib.sh" | sha256sum | cut -d' ' -f1) \
    || die "src/slib.sh does not exist in commit $commit"
  [ "$local_sha" = "$remote_sha" ] \
    || die "src/slib.sh in commit $commit differs from the working tree; run phase 1 first"

  repo=$(grep -E '^REPO_NAME=' "$INSTALLER" | cut -d'"' -f2)
  url="https://raw.githubusercontent.com/${repo}/${commit}/src/slib.sh"
  info "Verifying $url"
  TMPFILE=$(mktemp) || die "mktemp failed"
  if curl -sSLf "$url" -o "$TMPFILE"; then
    actual=$(file_sha "$TMPFILE")
    [ "$actual" = "$local_sha" ] \
      || die "remote copy has sha256 $actual, expected $local_sha — was '$commit' pushed to GitHub?"
    info "Remote copy serves the expected checksum"
  else
    echo "warning: could not fetch $url — push '$commit' to GitHub first" >&2
  fi

  info "Pinning SLIB_REV=$commit and SLIB_SHA256=$local_sha"
  set_installer_value SLIB_REV "$commit"
  set_installer_value SLIB_SHA256 "$local_sha"

  echo
  echo "Phase 2 next steps:"
  echo "  git diff kernel_installer.sh"
  echo "  git add kernel_installer.sh && git commit -m 'chore: bump slib pin'"
  echo "  git push"
}

vendor() {
  local url old_sha new_sha shebang
  url="https://raw.githubusercontent.com/${SOURCE}/${REF}/slib.sh"

  if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "$REPO_DIR" diff --quiet -- src/slib.sh \
      || ! git -C "$REPO_DIR" diff --cached --quiet -- src/slib.sh; then
      die "src/slib.sh has uncommitted changes; commit or discard them first"
    fi
  fi

  info "Fetching $url"
  TMPFILE=$(mktemp) || die "mktemp failed"
  if command -v curl >/dev/null 2>&1; then
    curl -sSLf "$url" -o "$TMPFILE" || die "download failed: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMPFILE" "$url" || die "download failed: $url"
  else
    die "curl or wget is required"
  fi

  [ -s "$TMPFILE" ] || die "downloaded file is empty"
  grep -q 'run_ok' "$TMPFILE" || die "downloaded file does not look like slib.sh"
  bash -n "$TMPFILE" || die "downloaded file has syntax errors"

  local shebang
  shebang=$(head -n 1 "$TMPFILE")
  if [ "$shebang" != '#!/usr/bin/env bash' ]; then
    echo "warning: fetched file starts with '$shebang' but the vendored copy uses" >&2
    echo "warning: '#!/usr/bin/env bash' (shellcheck dialect); adjust if keeping bashisms." >&2
  fi

  if [ "$APPLY_PATCH" -eq 1 ]; then
    # shellcheck disable=SC2016  # "$LOG_PATH" is matched literally, not expanded
    if grep -Fq 'prepare_log_for_nonterminal 2>/dev/null >> "$LOG_PATH"' "$TMPFILE"; then
      info "Local log tweak already present in the source; nothing to patch"
    elif grep -Fq 'prepare_log_for_nonterminal >> "$LOG_PATH"' "$TMPFILE"; then
      info "Re-applying local log tweak (2>/dev/null)"
      # shellcheck disable=SC2016
      sed 's|prepare_log_for_nonterminal >> "$LOG_PATH"|prepare_log_for_nonterminal 2>/dev/null >> "$LOG_PATH"|' \
        "$TMPFILE" > "$TMPFILE.bak"
      mv "$TMPFILE.bak" "$TMPFILE"
    else
      echo "warning: local log tweak target not found in the new slib.sh (expected for" >&2
      echo "warning: upstream/fork sources); verify kernel_installer.log for stderr noise." >&2
    fi
  fi

  if command -v shellcheck >/dev/null 2>&1; then
    info "Running shellcheck on the fetched file"
    if ! shellcheck "$TMPFILE"; then
      echo "warning: shellcheck reported findings above; CI lints src/slib.sh, so fix" >&2
      echo "warning: them or update the lint configuration before committing." >&2
    fi
  fi

  old_sha=$(file_sha "$SLIB_FILE")
  new_sha=$(file_sha "$TMPFILE")
  if [ "$old_sha" = "$new_sha" ]; then
    info "src/slib.sh is already identical (sha256 $new_sha); nothing to do"
    return 0
  fi

  cp "$TMPFILE" "$SLIB_FILE"
  info "Wrote src/slib.sh (sha256 $new_sha)"
  echo
  echo "Phase 1 next steps:"
  echo "  git diff --stat src/slib.sh   # review: sources may include extra helpers"
  echo "  git add src/slib.sh && git commit -m 'chore: update vendored slib.sh'"
  echo "  git push   # or merge the PR"
  echo "Then pin the pushed commit:"
  echo "  scripts/update-slib.sh --finalize <commit>"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--source)
      [ $# -ge 2 ] || die "missing value for $1"
      SOURCE=$2
      shift 2
      ;;
    -r|--ref)
      [ $# -ge 2 ] || die "missing value for $1"
      REF=$2
      shift 2
      ;;
    --no-patch) APPLY_PATCH=0; shift ;;
    --finalize)
      [ $# -ge 2 ] || die "missing value for $1"
      FINALIZE=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -f "$SLIB_FILE" ] || die "src/slib.sh not found at $SLIB_FILE"
[ -f "$INSTALLER" ] || die "kernel_installer.sh not found at $INSTALLER"

if [ -n "$FINALIZE" ]; then
  finalize "$FINALIZE"
else
  vendor
fi

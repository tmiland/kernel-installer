#!/usr/bin/env bash
# Refresh the pinned CachyOS source/config/patch revisions from the latest
# stable CachyOS release. Used by .github/workflows/pin-cachyos.yml.
#
#   ./scripts/update-cachyos-pin.sh            # update the pin
#   ./scripts/update-cachyos-pin.sh --check    # exit 0 if current, 1 if not
#   ./scripts/update-cachyos-pin.sh --dry-run  # print the resolved pin
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

mode=update
case "${1:-}" in
  --check) mode=check ;;
  --dry-run) mode=dry-run ;;
  --help | -h)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '')
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 2
    ;;
esac

for cmd in curl git python3 sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: $cmd is required" >&2
    exit 2
  }
done

# Latest stable release from the public Atom feed (no API token/quota).
feed=$(curl -fsSL --retry 3 "https://github.com/CachyOS/linux/releases.atom" 2>/dev/null) || {
  echo "Error: could not fetch the CachyOS releases feed" >&2
  exit 2
}
tag=$(printf '%s\n' "$feed" | grep -o 'Repository/[0-9]*/cachyos-[^<]*' |
  sed 's#.*/##' |
  grep -E '^cachyos-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' | sort -V | tail -1)
[ -n "$tag" ] || {
  echo "Error: could not find a stable CachyOS release" >&2
  exit 2
}

srcname=$tag
version=${tag#cachyos-}
tagrel=${version##*-}
version=${version%-*}
major_minor=${version%.*}

# Current CachyOS repository heads for the config and scheduler patches.
pkgbuild_rev=$(git ls-remote https://github.com/CachyOS/linux-cachyos.git HEAD | awk '{print $1}')
patches_rev=$(git ls-remote https://github.com/cachyos/kernel-patches.git HEAD | awk '{print $1}')
if [ -z "$pkgbuild_rev" ] || [ -z "$patches_rev" ]; then
  echo "Error: could not resolve the CachyOS repository revisions" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/config" \
  "https://raw.githubusercontent.com/CachyOS/linux-cachyos/${pkgbuild_rev}/linux-cachyos/config"
curl -fsSL --retry 3 -o "$tmp/bore.patch" \
  "https://raw.githubusercontent.com/cachyos/kernel-patches/${patches_rev}/${major_minor}/sched/0001-bore-cachy.patch"
curl -fsSL --retry 3 -o "$tmp/bmq.patch" \
  "https://raw.githubusercontent.com/cachyos/kernel-patches/${patches_rev}/${major_minor}/sched/0001-prjc-cachy.patch"

config_sha=$(sha256sum "$tmp/config" | cut -d' ' -f1)
bore_sha=$(sha256sum "$tmp/bore.patch" | cut -d' ' -f1)
bmq_sha=$(sha256sum "$tmp/bmq.patch" | cut -d' ' -f1)

cur_version=$(grep -m1 '^CACHYOS_VERSION=' kernel_installer.sh | cut -d= -f2)
cur_tagrel=$(grep -m1 '^CACHYOS_TAGREL=' kernel_installer.sh | cut -d= -f2)
cur_pkgbuild=$(grep -m1 '^CACHYOS_PKGBUILD_REV=' kernel_installer.sh | cut -d= -f2)
cur_config_sha=$(grep -m1 '^CACHYOS_CONFIG_SHA256=' kernel_installer.sh | cut -d= -f2)
cur_patches=$(grep -m1 '^CACHYOS_PATCHES_REV=' kernel_installer.sh | cut -d= -f2)
cur_bore_sha=$(grep -m1 '^CACHYOS_BORE_PATCH_SHA256=' kernel_installer.sh | cut -d= -f2)
cur_bmq_sha=$(grep -m1 '^CACHYOS_BMQ_PATCH_SHA256=' kernel_installer.sh | cut -d= -f2)

changed=0
[ "$cur_version" = "$version" ] || changed=1
[ "$cur_tagrel" = "$tagrel" ] || changed=1
[ "$cur_pkgbuild" = "$pkgbuild_rev" ] || changed=1
[ "$cur_config_sha" = "$config_sha" ] || changed=1
[ "$cur_patches" = "$patches_rev" ] || changed=1
[ "$cur_bore_sha" = "$bore_sha" ] || changed=1
[ "$cur_bmq_sha" = "$bmq_sha" ] || changed=1

if [ "$mode" = "check" ]; then
  if [ "$changed" = "0" ]; then
    echo "Pinned CachyOS is current: ${version}-${tagrel}"
    exit 0
  fi
  echo "CachyOS pin update available: ${cur_version}-${cur_tagrel} -> ${version}-${tagrel}"
  exit 1
fi

echo "Latest stable CachyOS: ${version}-${tagrel} (${srcname})"
echo "  PKGBUILD rev: ${pkgbuild_rev}"
echo "  config sha256: ${config_sha}"
echo "  patches rev:  ${patches_rev}"
echo "  BORE sha256:  ${bore_sha}"
echo "  BMQ sha256:   ${bmq_sha}"

if [ "$mode" = "dry-run" ]; then
  echo "Dry run: no files changed."
  exit 0
fi

if [ "$changed" = "0" ]; then
  echo "Pinned CachyOS is already current; nothing to do."
  exit 0
fi

python3 - "$version" "$tagrel" "$pkgbuild_rev" "$config_sha" "$patches_rev" \
  "$bore_sha" "$bmq_sha" "$cur_version" "$cur_tagrel" <<'PY'
import re
import sys
from pathlib import Path

(new_version, new_tagrel, new_pkg, new_cfg, new_patches, new_bore, new_bmq,
 old_version, old_tagrel) = sys.argv[1:10]

p = Path("kernel_installer.sh")
s = p.read_text()
for name, value in (
    ("CACHYOS_VERSION", new_version),
    ("CACHYOS_TAGREL", new_tagrel),
    ("CACHYOS_PKGBUILD_REV", new_pkg),
    ("CACHYOS_CONFIG_SHA256", new_cfg),
    ("CACHYOS_PATCHES_REV", new_patches),
    ("CACHYOS_BORE_PATCH_SHA256", new_bore),
    ("CACHYOS_BMQ_PATCH_SHA256", new_bmq),
):
    s = re.sub(rf"^{name}=.*$", f"{name}={value}", s, count=1, flags=re.M)
p.write_text(s)


def replace(path, pairs):
    p = Path(path)
    s = p.read_text()
    for old, new in pairs:
        s = s.replace(old, new)
    p.write_text(s)


replace("tests/test_cachyos_cli.sh", [
    (f"pinned to {old_version}", f"pinned to {new_version}"),
])
replace(".github/workflows/test-install.yml", [
    (f"{old_version}-cachyos-", f"{new_version}-cachyos-"),
    (f"CachyOS {old_version}", f"CachyOS {new_version}"),
])
replace("README.md", [
    (f"{old_version}-cachyos-", f"{new_version}-cachyos-"),
    (f"CachyOS {old_version}-{old_tagrel}", f"CachyOS {new_version}-{new_tagrel}"),
    (f"**{old_version}-{old_tagrel}**", f"**{new_version}-{new_tagrel}**"),
    (f"pinned {old_version} source", f"pinned {new_version} source"),
    (f"kernel.org {old_version} tree", f"kernel.org {new_version} tree"),
])
PY

git diff --stat

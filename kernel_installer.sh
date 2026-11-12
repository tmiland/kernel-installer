#!/usr/bin/env bash
# shellcheck disable=SC2221,SC2222,SC2181,SC2174,SC2086,SC2046,SC2005,SC2317

## Author: Tommy Miland (@tmiland) - Copyright (c) 2025


######################################################################
####                    Kernel Installer.sh                       ####
####               Automatic kernel install script                ####
####                   Maintained by @tmiland                     ####
######################################################################


VERSION='1.5.0'

#------------------------------------------------------------------------------#
#
# MIT License
#
# Copyright (c) 2025 Tommy Miland
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#------------------------------------------------------------------------------#
## Uncomment for debugging purpose
#set -o errexit
#set -o pipefail
#set -o nounset
#set -o xtrace
# Set update check
UPDATE_SCRIPT=0
# Operation mode: install or uninstall
mode=install
# Get script filename and directory (resolves symlinks). BASH_SOURCE[0] is
# empty when the script is piped in (curl | bash); keep $self empty then,
# because readlink -f "" prints nothing with GNU coreutils but the current
# directory with uutils coreutils (Ubuntu 26.04).
self=""
if [[ -n ${BASH_SOURCE[0]} ]]; then
  self=$(readlink -f "${BASH_SOURCE[0]}")
fi
SCRIPT_FILENAME=$(basename "$self")
SCRIPT_DIR=$(dirname "$self")
# Bundled kernel.org signing keys (public) and their pinned primary
# fingerprints. Checkout runs import the bundle; piped runs fall back to WKD.
KERNEL_KEYRING_FILE=src/keys/kernel.org.asc
TORVALDS_FPR=ABAF11C65A2970B130ABE3C479BE3E4300411886
GREGKH_FPR=647F28654894E3BD457199BE38DBBDC86092693E
AUTOSIGNER_FPR=B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1
# CachyOS source + BORE pins. The source tree already carries the CachyOS
# base patchset (CONFIG_CACHY); the BORE scheduler is an additional patch.
# Bump these together with src/keys/cachyos.asc when moving to a new source.
CACHYOS_VERSION=7.3.4
CACHYOS_TAGREL=1
CACHYOS_SRCNAME="cachyos-${CACHYOS_VERSION}-${CACHYOS_TAGREL}"
CACHYOS_SOURCE_URL="https://github.com/CachyOS/linux/releases/download/${CACHYOS_SRCNAME}/${CACHYOS_SRCNAME}.tar.gz"
CACHYOS_PKGBUILD_REV=8e308d0a3895dbc741381fb61b9a9a8603be793d
CACHYOS_CONFIG_URL="https://raw.githubusercontent.com/CachyOS/linux-cachyos/${CACHYOS_PKGBUILD_REV}/linux-cachyos/config"
CACHYOS_CONFIG_SHA256=81fb56fe326612a0dc4705fc5ec309d04bcfffb487db0cb5843918fe92951927
CACHYOS_PATCHES_REV=21d721415790e6717b2ece16e82e08eb98d16c00
CACHYOS_BORE_PATCH_URL="https://raw.githubusercontent.com/cachyos/kernel-patches/${CACHYOS_PATCHES_REV}/7.3/sched/0001-bore-cachy.patch"
CACHYOS_BORE_PATCH_SHA256=d2eaa8e8dbf1f56bfb304f8b437a7dc30a65408f90a93701367baf8adc2173b4
CACHYOS_KEYRING_FILE=src/keys/cachyos.asc
CACHYOS_KEY_FINGERPRINTS=(
  E18447AC260021D31F3FF6C4C8A2A4774B8B63C4
  E8B9AA39F054E30E8290D492C3C4820857F654FE
)
# Original command-line arguments (diagnostics and the "run as root" hint)
SCRIPT_ARGS="$*"
# Logfile (the previous install's log is kept as $LOGFILE.1)
# /var/log itself is group-writable on Ubuntu/Mint; the log lives in a
# root-only subdirectory instead of next to entries the syslog group can
# replace (#64).
DEFAULT_LOGFILE=/var/log/kernel-installer/kernel_installer.log
LOGFILE=${LOGFILE:-$DEFAULT_LOGFILE}
# One installer at a time: two runs would share the build folder and log (#70)
LOCK_FILE=${LOCK_FILE:-/run/kernel_installer.lock}
# Default processing units (all available)
NPROC=${NPROC:-$(nproc)}
# Console output level; ignore debug level messages.
VERBOSE=${VERBOSE:-0}
# Disable debug info since it's enabled by default to speed up kernel compilation
ENABLE_DEBUG_INFO=${ENABLE_DEBUG_INFO:-0}
# Low latency (Default off)
LOWLATENCY=${LOWLATENCY:-0}
# Optimization profile (empty = no profile)
PROFILE=${PROFILE:-}
# Base config for profile builds: running, a path, or none (empty = none)
BASE_CONFIG=${BASE_CONFIG:-}
# get-verified-tarball (Default: yes; set GET_VERIFIED_TARBALL=0 to skip verification)
GET_VERIFIED_TARBALL=${GET_VERIFIED_TARBALL:-1}
# Show banners (Default: yes)
BANNERS=${BANNERS:-1}
# List installed kernels and exit (Default: no)
LIST_INSTALLED=${LIST_INSTALLED:-0}
# Default Install dir (Default: /opt/linux)
INSTALL_DIR=${INSTALL_DIR:-/opt/linux-kernel}
INSTALL_DIR_MARKER=".kernel_installer"
# kernel.org version banner, fetched once for all the lookups below and with
# short timeouts: fetching it per lookup (3 x 4 attempts x 20s) made every
# run, even --help, hang for over 4 minutes when kernel.org was unreachable.
KERNEL_BANNER=$(curl -fsSL --connect-timeout 5 --max-time 10 --retry 1 --retry-delay 1 \
  https://www.kernel.org/finger_banner 2>/dev/null)
# https://stackoverflow.com/a/51068988
latest_kernel() {
  printf '%s\n' "$KERNEL_BANNER" | grep -m1 "$1" | sed -r 's/^.+: +([^ ]+)( .+)?$/\1/'
}
# Default Kernel version
STABLE_VER=$(latest_kernel stable)
# Mainline kernel version (set MAINLINE_VER to pin a specific -rc, e.g. in CI)
MAINLINE_VER=${MAINLINE_VER:-$(latest_kernel mainline)}
# Lonterm kernel version
LONGTERM_VER=$(latest_kernel longterm)
# Default kernel version without arguments
LINUX_VER=${LINUX_VER:-$STABLE_VER}
# Default linux version name
LINUX_VER_NAME=Stable
# Set to 1 when the kernel version is explicitly chosen by the user
VER_SELECTED=${VER_SELECTED:-0}
# Installed kernel
CURRENT_VER=$(uname -r)
# Default kexec option
KEXEC=${KEXEC:-0}
# Default compression - zstd
DEFAULT_COMPRESSION=${DEFAULT_COMPRESSION:-zstd}
DEF_COM=${DEF_COM:-ZSTD}
DEF_COM_NUM=${DEF_COM_NUM:-5}
# Repo name for this script
REPO_NAME="tmiland/kernel-installer"
# Pinned slib.sh revision for the remote fallback (used when running outside a
# checkout, e.g. curl | bash). The file is fetched from an immutable commit and
# verified against its sha256 before being sourced.
# When src/slib.sh changes: run scripts/update-slib.sh (phase 1: vendor and
# commit the file), then scripts/update-slib.sh --finalize <commit> (phase 2:
# pin SLIB_REV to the pushed commit and refresh SLIB_SHA256). The "slib pin"
# CI job fails on main while the pin does not match src/slib.sh.
SLIB_REV="e6d7da7"
SLIB_SHA256="694784527d354eb264df24e399a693124fe0df6cb5037a7af218677772cf47c5"
# Functions url
SLIB_URL=https://raw.githubusercontent.com/$REPO_NAME/$SLIB_REV/src/slib.sh
# Set default configuration target
CONFIG_OPTION=${CONFIG_OPTION:-olddefconfig}
# Kernel source: vanilla (kernel.org) or cachyos (pinned CachyOS source)
SOURCE=${SOURCE:-vanilla}
# Scheduler selection for the CachyOS source: eevdf or bore
KERNEL_SCHED=${KERNEL_SCHED:-eevdf}
# CPU tuning: generic (portable), native, zen4, x86-64-v3, x86-64-v4
CPU=${CPU:-generic}
# Link-time optimization: none, thin, or full (requires clang/lld)
LTO=${LTO:-none}
MAKE_LLVM=${MAKE_LLVM:-}
# Timer frequency override (100/250/300/1000; 500/600/750 on CachyOS)
HZ_OVERRIDE=${HZ_OVERRIDE:-}
# BBRv3 default TCP congestion control (CachyOS source only)
BBR3=${BBR3:-0}
# Android Binder IPC and binderfs (Waydroid)
BINDER=${BINDER:-0}
# sched_ext and BTF for userspace BPF schedulers
SCHED_EXT=${SCHED_EXT:-0}
# Optional custom localversion suffix (without or with a leading hyphen)
KERNEL_TAG=${KERNEL_TAG:-}

# Include functions
# Only trust src/slib.sh next to the script when the script itself is a file.
# When it is piped in (curl | bash), $self is empty and SCRIPT_DIR would be
# the current directory, so a src/slib.sh there must not be sourced.
if [[ -n $self && -f $SCRIPT_DIR/src/slib.sh ]]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/src/slib.sh"
else
  # Running outside a checkout (e.g. curl | bash): fetch the pinned slib.sh
  # revision and verify its checksum before sourcing it.
  slib_tmp=$(mktemp) || {
    echo -e "Could not create a temporary file.\nProcess aborted"
    exit 1
  }
  if [[ $(command -v 'curl') ]]; then
    curl -sSLf "$SLIB_URL" > "$slib_tmp"
  elif [[ $(command -v 'wget') ]]; then
    wget -qO "$slib_tmp" "$SLIB_URL"
  else
    rm -f "$slib_tmp"
    echo -e "${RED}${BALLOT_X} This script requires curl or wget.\nProcess aborted${NORMAL}"
    exit 1
  fi
  if ! echo "$SLIB_SHA256  $slib_tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$slib_tmp"
    echo -e "Checksum verification of slib.sh failed, refusing to execute it.\nProcess aborted"
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$slib_tmp"
  rm -f "$slib_tmp"
fi

# Setup slog
# shellcheck disable=SC2034
LOG_PATH="$LOGFILE"
# Setup run_ok
# shellcheck disable=SC2034
RUN_LOG="$LOGFILE"
# Exit on any failure during shell stage
# shellcheck disable=SC2034
RUN_ERRORS_FATAL=1

# Console output level; ignore debug level messages.
if [ "$VERBOSE" = "1" ]; then
  # shellcheck disable=SC2034
  LOG_LEVEL_STDOUT="DEBUG"
else
  # shellcheck disable=SC2034
  LOG_LEVEL_STDOUT="INFO"
fi
# Log file output level; catch literally everything.
# shellcheck disable=SC2034
LOG_LEVEL_LOG="DEBUG"

# log_fatal calls log_error
log_fatal() {
  log_error "$1"
}

fatal() {
  echo
  log_fatal "Fatal Error Occurred: $1"
  printf "%s \\n" "${RED}Cannot continue installation.${NORMAL}"
  if [ -d "$INSTALL_DIR" ] && is_safe_install_dir "$INSTALL_DIR"; then
    log_warning "Removing temporary directory and files."
    remove_install_dir "$INSTALL_DIR" || log_warning "Could not completely remove $INSTALL_DIR."
  elif [ -d "$INSTALL_DIR" ]; then
    log_warning "Not removing $INSTALL_DIR: it may contain files not created by this installer."
  fi
  log_fatal "If you are unsure of what went wrong, you may wish to review the log"
  log_fatal "in $LOGFILE"
  exit 1
}

# Make sure an option that takes a value actually got one
require_arg() {
  # $1 = option name, $2 = value
  if [[ -z $2 ]]; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Option $1 requires an argument"
  fi
}

# Record the build environment at the top of the log, so a failure report
# carries what is needed to diagnose it.
log_diagnostics() {
  local dir=$INSTALL_DIR
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do
    dir=$(dirname "$dir")
  done
  log_debug "Diagnostics: ${SCRIPT_FILENAME:-kernel_installer.sh} ${VERSION}, args: ${SCRIPT_ARGS}"
  log_debug "Diagnostics: distro: ${DISTRO} (${DISTRO_GROUP}), running kernel: $(uname -srm)"
  log_debug "Diagnostics: target: ${LINUX_VER_NAME} ${LINUX_VER}, source: ${SOURCE}, sched: ${KERNEL_SCHED}, cpu: ${CPU}, lto: ${LTO}, tag: ${KERNEL_TAG:-auto}, config: ${CONFIG_OPTION}, profile: ${PROFILE:-none}, base config: ${BASE_CONFIG:-none}, custom directives: ${#CUSTOM_CONFIG_OPTIONS[@]}, verified tarball: ${GET_VERIFIED_TARBALL}, jobs: ${NPROC}"
  log_debug "Diagnostics: running kernel's config: $(ls /boot/config-"$(uname -r)" 2>/dev/null || echo "none")"
  log_debug "Diagnostics: $(gcc --version 2>/dev/null | head -n 1 || echo 'gcc: not found'); $(make --version 2>/dev/null | head -n 1); $(ld --version 2>/dev/null | head -n 1)"
  log_debug "Diagnostics: memory: $(awk '/^MemTotal:|^MemAvailable:/ {printf "%s %d MiB  ", $1, $2 / 1024}' /proc/meminfo 2>/dev/null)"
  log_debug "Diagnostics: disk free for ${INSTALL_DIR}: $(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 {printf "%d MiB on %s", $4 / 1024, $6}')"
}

# Explain a failed kernel build: show the first real error in the build
# output instead of the tail, which only holds make's generic "Error 2" lines
# (see issue #12). $1 = line count of $RUN_LOG before the build started.
report_build_failure() {
  local start=$1 line='' hint='' from='' first=''
  # A shell or make could not run a program at all (dash, bash, make exec);
  # unlike "fatal error: foo.h: No such file or directory", a missing header
  local missing_cmd='^(/usr)?/bin/(ba|da)?sh: (line )?[0-9]+: .*not found$|^make([[][0-9]+[]])?: [^ ]+: No such file or directory$'
  line=$(awk -v start="$start" -v missing="$missing_cmd" '
    NR <= start { next }
    /^dpkg-buildpackage: error:/ { next }
    # log lines written by this script ("[2026-01-01 12:00:00 CET] [ERROR] ..."),
    # also when run_ok appends one to its "message: " prefix
    /\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:]+ [^]]*\] \[[A-Z]+\]/ { next }
    $0 ~ missing || /internal compiler error|Killed signal terminated program|No space left on device|mktemp: .*failed to create|No rule to make target|fatal error:|undefined reference to|(^|[^[:alpha:]])error:/ {
      print NR; exit
    }' "$RUN_LOG" 2>/dev/null)
  echo
  if [ -z "$line" ]; then
    log_error "Kernel build failed, and no error message was found in the build output; see ${RUN_LOG}."
  else
    log_error "Kernel build failed. First error in the build output (${RUN_LOG}, line ${line}):"
    # Two lines of context above (never from before the build), three below
    from=$((line - 2 > start ? line - 2 : start + 1))
    sed -n "${from},$((line + 3))p" "$RUN_LOG" | sed 's/^/    /'
    first=$(sed -n "${line}p" "$RUN_LOG")
    case "$first" in
      *"internal compiler error"* | *"Killed signal terminated program"*)
        hint="The compiler itself crashed or was killed (often for lack of memory); this is not a bug in the kernel source. Retry with fewer jobs (--nproc). If it fails in a different file each time, suspect RAM or overclocking; if it fails in the same place, try another kernel version or compiler."
        ;;
      *"No space left on device"*)
        hint="The disk holding ${INSTALL_DIR} is full. Free some space or build elsewhere with --dir."
        ;;
      *".pem"* | *"certs/"*)
        hint="The kernel configuration points at a certificate file that does not exist in the kernel.org source (distribution configs set CONFIG_SYSTEM_TRUSTED_KEYS / CONFIG_SYSTEM_REVOCATION_KEYS). Clear them with: --custom-config 'scripts/config --set-str SYSTEM_TRUSTED_KEYS \"\"' --custom-config 'scripts/config --set-str SYSTEM_REVOCATION_KEYS \"\"'"
        ;;
      *)
        if [[ $first =~ $missing_cmd ]]; then
          hint="A program the kernel build runs is not installed (it is named on the error line). Install it and run the script again."
        fi
        ;;
    esac
    if [ -n "$hint" ]; then
      log_error "Hint: ${hint}"
    fi
  fi
  log_error "The build tree is kept in ${INSTALL_DIR} for inspection (it is removed on the next run)."
}

# Refuse to start while another run holds the lock. This deliberately does not
# go through fatal(): fatal removes INSTALL_DIR, which would delete the build
# tree of the run that currently holds the lock.
take_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    printf 'Cannot start: flock (util-linux) is not installed.\n' >&2
    exit 1
  fi
  if [ ! -d "$(dirname -- "$LOCK_FILE")" ]; then
    LOCK_FILE=/var/lock/kernel_installer.lock
  fi
  if ! exec 9>>"$LOCK_FILE"; then
    printf 'Cannot open lock file %s.\n' "$LOCK_FILE" >&2
    exit 1
  fi
  if ! flock -n 9; then
    printf 'Another kernel_installer run is already in progress (lock: %s).\n' "$LOCK_FILE" >&2
    exit 1
  fi
}

# Validate the log path before root appends to it or renames it to .1. The
# default lives in a 0700 root-owned directory; a custom LOGFILE must not be a
# symlink, must not be a file owned by someone else, and must not sit in a
# directory other users can write to (#64).
chk_logfile() {
  local log=${1:-$LOGFILE} dir mode
  dir=$(dirname -- "$log")
  if [ -L "$log" ]; then
    fatal "Log file $log is a symlink; refusing to write through it."
  fi
  if [ -e "$log" ] && { [ ! -f "$log" ] || [ ! -O "$log" ]; }; then
    fatal "Log file $log is not a regular file owned by the current user; refusing to use it."
  fi
  if [ -L "$log.1" ]; then
    fatal "Previous log $log.1 is a symlink; refusing to rotate onto it."
  fi
  if [ -e "$log.1" ] && { [ ! -f "$log.1" ] || [ ! -O "$log.1" ]; }; then
    fatal "Previous log $log.1 is not a regular file owned by the current user; refusing to replace it."
  fi
  if [ ! -d "$dir" ]; then
    if [[ $log == "$DEFAULT_LOGFILE" ]]; then
      if ! mkdir -p -m 0700 -- "$dir"; then
        fatal "Could not create log directory $dir."
      fi
    else
      fatal "Log directory $dir does not exist."
    fi
  fi
  if [ -L "$dir" ]; then
    fatal "Log directory $dir is a symlink; refusing to use it."
  fi
  mode=$(stat -c '%a' -- "$dir" 2>/dev/null) ||
    fatal "Could not read the permissions of log directory $dir."
  if (( (8#$mode & 0022) != 0 )); then
    fatal "Log directory $dir is writable by group or others; use $DEFAULT_LOGFILE or a directory only root can write to."
  fi
  if [[ $log == "$DEFAULT_LOGFILE" ]]; then
    if [ ! -O "$dir" ]; then
      fatal "Log directory $dir is not owned by the current user."
    fi
    if (( (8#$mode & 0077) != 0 )); then
      fatal "Log directory $dir must not be accessible by group or others; run: chmod 700 $dir"
    fi
  fi
}

# Start an install with an empty log and keep the previous one as
# $LOGFILE.1, so a failed build's log survives the next run (#53).
rotate_log() {
  if [ -f "$LOGFILE" ]; then
    mv -f -- "$LOGFILE" "$LOGFILE.1"
  fi
}

# A directory is safe to reuse (and wipe) when it does not exist yet, is
# empty, or was created by this installer in a previous run (marker present).
is_safe_install_dir() {
  local dir="$1"
  if [ -z "$dir" ] || [ "$dir" = "/" ] || [ ! -d "$dir" ]; then
    return 1
  fi
  if [ -L "$dir" ]; then
    return 1
  fi
  if [ -e "$dir/$INSTALL_DIR_MARKER" ]; then
    return 0
  fi
  if [ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  return 1
}

# Delete a build directory this installer owns, removing the marker last so an
# interrupted delete leaves a folder the next run can still recognise (#69).
remove_install_dir() {
  local dir=$1
  if [ -z "$dir" ] || [ "$dir" = "/" ] || [ ! -d "$dir" ]; then
    return 1
  fi
  if ! find "$dir" -mindepth 1 ! -name "$INSTALL_DIR_MARKER" -delete; then
    return 1
  fi
  rm -f -- "$dir/$INSTALL_DIR_MARKER" || return 1
  rmdir -- "$dir" 2>/dev/null || true
  return 0
}

# Create a fresh build directory for this run. Refuse symlinks, folders owned
# by another user, and shared parents another user can replace entries in: the
# tree is built as root, so a nested attacker-controlled folder would let them
# swap the tarball or source between verification and the build (#62).
prepare_install_dir() {
  local dir=$INSTALL_DIR parent parent_uid caller_uid mode
  parent=$(dirname -- "$dir")
  if [ ! -d "$parent" ]; then
    # Create the parent private from the start. With the default root umask
    # 002 a plain `mkdir -p` would create 0775, which the check below then
    # rejects (the installer would create the directory and refuse it).
    if ! mkdir -p -m 0700 -- "$parent"; then
      fatal "Could not create install directory parent $parent"
    fi
  fi
  if [ -L "$parent" ]; then
    fatal "Install directory parent $parent is a symlink; refusing to use it."
  fi
  mode=$(stat -c '%a' -- "$parent" 2>/dev/null) ||
    fatal "Could not read the permissions of $parent."
  # A non-sticky group/other-writable parent lets another user rename or
  # replace the build folder; sticky shared folders (/tmp, /var/tmp) do not.
  if (( (8#$mode & 0022) != 0 && (8#$mode & 01000) == 0 )); then
    fatal "Install directory parent $parent is writable by group or others and is not sticky; run: chmod 700 $parent (or choose a private --dir)"
  fi
  parent_uid=$(stat -c '%u' -- "$parent" 2>/dev/null) ||
    fatal "Could not read the owner of $parent."
  caller_uid=${SUDO_UID:-$(id -u)}
  if [ "$parent_uid" != "0" ] && [ "$parent_uid" != "$caller_uid" ]; then
    fatal "Install directory parent $parent is owned by another user; choose a directory you own."
  fi
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    if ! is_safe_install_dir "$dir"; then
      fatal "Install directory $dir is not empty and does not look like it was created by this script. Refusing to delete its contents; use an empty directory or clean it up yourself."
    fi
    if ! remove_install_dir "$dir"; then
      fatal "Could not remove the previous build directory $dir."
    fi
  fi
  if ! mkdir -m 0755 -- "$dir"; then
    fatal "Could not create install directory $dir"
  fi
  if [ -L "$dir" ] || [ ! -O "$dir" ]; then
    fatal "Install directory $dir is not owned by the current user; refusing to build in it."
  fi
  mode=$(stat -c '%a' -- "$dir" 2>/dev/null) ||
    fatal "Could not read the permissions of $dir."
  if (( (8#$mode & 0022) != 0 )); then
    fatal "Install directory $dir is writable by group or others; refusing to build in it."
  fi
  if ! touch -- "$dir/$INSTALL_DIR_MARKER"; then
    fatal "Could not create the marker file in $dir"
  fi
}

read_sleep() {
  read -rt "$1" <> <(:) || :
}

# Read the user's answer into variable $1; the remaining arguments go to read
# (e.g. -p prompt). When the script itself is piped in (curl | bash, $self is
# empty), stdin is the rest of the script, so read from the terminal instead
# and leave the answer empty if there is none. Otherwise read stdin as usual,
# so answers can still be piped in (yes | ./kernel_installer.sh ...).
ask() {
  local __var=$1 __reply=''
  shift
  if [ -n "$self" ]; then
    read -r "$@" __reply
  elif { : </dev/tty; } 2>/dev/null; then
    read -r "$@" __reply </dev/tty
  fi
  printf -v "$__var" '%s' "$__reply"
}

# Make sure that the script runs with root permissions
chk_permissions() {
  # Only root can run this
  if [[ "$EUID" != 0 ]]; then
    local hint
    if [[ -n "$SCRIPT_FILENAME" ]]; then
      hint="Run it again as root: sudo bash ${SCRIPT_FILENAME}${SCRIPT_ARGS:+ ${SCRIPT_ARGS}}"
    else
      # A piped run cannot rerun itself; $self is empty there on purpose
      hint="Run it again as root: replace 'bash' with 'sudo bash' in the download command"
    fi
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} The ${SCRIPT_FILENAME:-kernel_installer.sh} script must be run as root. ${hint}"
  fi
}

# Kernel release (uname -r, package names) built from a kernel.org version.
# The Makefile always has a SUBLEVEL, so 7.3 builds 7.3.0 and 7.3-rc7 builds
# 7.3.0-rc7; versions that already have one (6.12.113, 7.0.0-38-generic) are
# returned unchanged.
kernel_release() {
  local base=${1%%-*}
  local extra=${1#"$base"}
  if [[ $base =~ ^[0-9]+\.[0-9]+$ ]]; then
    base=$base.0
  fi
  echo "${base}${extra}"
}

# Print the installed package <name>-<release> (name: linux-image,
# linux-headers, kernel, kernel-devel); fails if it is not installed.
# binrpm-pkg writes - as _ in the rpm version (kernel-7.3.0_rc7) while distro
# kernels keep it (kernel-6.17.1-300.fc44.x86_64), so rpm tries both.
installed_kernel_pkg() {
  local name=$1 release=$2 pkg
  local -a candidates=("$name-$release")
  if [[ $DISTRO_GROUP == "RHEL" ]]; then
    candidates+=("$name-${release//-/_}")
  fi
  for pkg in "${candidates[@]}"; do
    if ${PKGCHK} "$pkg" >/dev/null 2>&1; then
      echo "$pkg"
      return 0
    fi
  done
  return 1
}

# Kernel release the configured tree builds, CONFIG_LOCALVERSION included
# (6.12.113-test). mkdebian and kernel.spec name the packages after exactly
# this release, so it is what the install path has to follow (#49). Prints
# nothing and returns non-zero when the tree cannot answer (not configured
# yet, no Makefile).
built_kernelrelease() {
  local release
  # kernelrelease is a no-sync-config target: it runs scripts/setlocalversion,
  # which reads include/config/auto.conf but never refreshes it from .config.
  # The profile and --kernel-tag edits happen after the last syncconfig, so a
  # stale or missing auto.conf answers without the localversion (7.3.4 instead
  # of 7.3.4-cachyos-workstation-bore-lto) or fails outright. Force a resync
  # first; the tree then names exactly the release mkdebian and kernel.spec
  # used for the packages (#74).
  release=$(
    cd "$1" 2>/dev/null || exit 1
    touch .config 2>/dev/null || exit 1
    # shellcheck disable=SC2086
    ${MAKE_LLVM:+$MAKE_LLVM }make -s syncconfig >/dev/null 2>&1 || exit 1
    # shellcheck disable=SC2086
    ${MAKE_LLVM:+$MAKE_LLVM }make -s kernelrelease 2>/dev/null
  ) || return 1
  [[ -n $release ]] || return 1
  printf '%s\n' "$release"
}

# Release from the built image package, linux-image-<release>_<version>_<arch>.deb.
# mkdebian names the package after the release the configured tree built, so the
# package itself is the ground truth for the install path (#74).
built_deb_release() {
  local dir=${1:-.} deb release
  for deb in "$dir"/linux-image-*.deb; do
    [ -e "$deb" ] || continue
    release=${deb##*/}
    # mkdebian names the debug package linux-image-<release>-dbg; it carries a
    # different suffix and must not win the release lookup.
    case $release in *-dbg_*) continue ;; esac
    release=${release#linux-image-}
    release=${release%%_*}
    [ -n "$release" ] || continue
    printf '%s\n' "$release"
    return 0
  done
  return 1
}

# Kernel release derived from the top-level Makefile,
# VERSION.PATCHLEVEL.SUBLEVEL+EXTRAVERSION. It carries the -rc suffix
# (7.3-rc7 -> 7.3.0-rc7) but not CONFIG_LOCALVERSION, which only the
# configured tree knows (#49).
get_linux_full_ver() {
  # SUBLEVEL is always present in the Makefile (VERSION and PATCHLEVEL are on
  # the first line, SUBLEVEL on the third, so awk always has $3)
  awk '/^VERSION =/ { v = $3 } /^PATCHLEVEL =/ { p = $3 } /^SUBLEVEL =/ { s = $3 }
       /^EXTRAVERSION =/ { x = $3 } END { print v "." p "." s x }' "$1"
}

# Installed kernel packages named <name>-<release> plus a localversion suffix
# (linux-image-6.12.113-test). The suffix is a config decision of the build
# that installed them, so it can only be found by matching the installed
# packages against the release prefix (#49). Every match is printed on its own
# line; a following digit is not a suffix but a different version.
installed_kernel_pkgs_localversion() {
  local name=$1 release=$2 pattern installed
  local -a grep_args=()
  pattern="${name}-${release}"
  pattern=${pattern//./\\.}
  grep_args=(-E -e "^${pattern}([^0-9].*)?$")
  if [[ $DISTRO_GROUP == "RHEL" ]]; then
    # The rpm version has - rewritten to _ (kernel-6.12.113_test)
    grep_args+=(-e "^${pattern//-/_}([^0-9].*)?$")
    installed=$(rpm -qa 2>/dev/null || true)
  else
    installed=$(dpkg-query -f '${binary:Package}\n' -W 2>/dev/null || true)
  fi
  grep "${grep_args[@]}" <<<"$installed" | sort -u
}

chk_kernel() {
  # Check if kernel is installed, abort if same version is found
  local release image_pkg
  release=$(kernel_release "$LINUX_VER")
  if [[ $DISTRO_GROUP == "RHEL" ]]; then
    image_pkg=kernel
  else
    image_pkg=linux-image
  fi
  # Only exact names are matched here: a kernel built with a localversion is
  # installed as <release><suffix> (6.12.113-test), and a prefix match would
  # also catch unrelated distribution kernels (6.12.113-generic, -300.fc44),
  # aborting on a build that installs next to them (#49). Pass the full
  # release (-k 6.12.113-test) to have it recognised.
  if [ "$CURRENT_VER" = "$release" ] || installed_kernel_pkg "$image_pkg" "$release" >/dev/null; then
    echo
    ask YESNO -e -p "${YELLOW}Linux kernel ${LINUX_VER} is already installed, install anyways?${NORMAL} [y/N]: "
    case ${YESNO,,} in
      y | yes) return ;;
      *)
        fatal "${RED}${BALLOT_X} Kernel ${LINUX_VER} is already installed. Process aborted${NORMAL}"
        ;;
    esac
  fi
}

# A kernel version is digits.digits plus an optional release suffix such as
# -rc7, -38-generic or -300.fc44.x86_64. Only these characters are used: the
# version is pasted into run_ok commands (which eval), so shell metacharacters,
# spaces and path separators must never get through (#63).
valid_kernel_version() {
  [[ $1 =~ ^[0-9]+\.[0-9]+[0-9A-Za-z.+~_-]*$ ]]
}

# Make sure a valid kernel version was determined before doing anything destructive
chk_version() {
  if ! valid_kernel_version "$LINUX_VER"; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Could not determine a valid kernel version (got: '${YELLOW}${LINUX_VER}${NORMAL}'). Check your network connection or specify a version with ${CYAN}--kernel${NORMAL}."
  fi
}

# Turn debug info off in .config (current directory = kernel tree).
# From 5.18, "Debug information" is a choice (DEBUG_INFO_NONE,
# DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT, DEBUG_INFO_DWARF4, DEBUG_INFO_DWARF5):
# enabling NONE alone leaves e.g. Ubuntu's DWARF5=y in place, and with two
# members at y olddefconfig keeps DWARF5, so every other member is disabled.
# $1 = kernel version
disable_debug_info() {
  if [ "$(versionToInt "$1")" -ge "$(versionToInt 5.18)" ]; then
    scripts/config --enable DEBUG_INFO_NONE \
      --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
      --disable DEBUG_INFO_DWARF4 \
      --disable DEBUG_INFO_DWARF5
  else
    scripts/config --set-val DEBUG_INFO n
    scripts/config --set-val DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT n
  fi
}

versionToInt() {
  echo "$@" | awk -F "." '{ printf("%03d%03d%03d", $1,$2,$3); }';
}

# Distribution configs copied from /boot (Ubuntu, Mint) point the trusted
# and revoked key lists at certificate files from the distribution's own
# kernel tree (debian/canonical-certs.pem), so a kernel.org tree stops with
# "No rule to make target". Clear a key list whose file does not exist;
# paths are relative to the kernel source tree (the current directory).
clear_missing_cert_keys() {
  local key cert
  for key in SYSTEM_TRUSTED_KEYS SYSTEM_REVOCATION_KEYS; do
    cert=$(scripts/config --state "$key")
    case "$cert" in
      "" | n | undef) continue ;;
    esac
    if [ ! -f "$cert" ]; then
      log_warning "CONFIG_${key} points at ${cert}, which is not in the kernel source; clearing it."
      scripts/config --set-str "$key" ""
    fi
  done
}

# --- Optimization profiles ---
# Profiles are config deltas applied after the kernel's base configuration.
# They deliberately avoid symbols that need an out-of-tree patchset (BORE,
# CACHY) or DEBUG_INFO_BTF (sched_ext); those are separate opt-ins.
profile_cfg() {
  log_debug "Profile ${PROFILE}: scripts/config $*"
  scripts/config "$@"
}

profile_kernel_ge() {
  [ "$(versionToInt "$1")" -ge "$(versionToInt "$2")" ]
}

profile_set_hz() {
  local hz=$1 other
  profile_cfg --set-val HZ "$hz"
  profile_cfg --enable "HZ_${hz}"
  for other in 100 250 300 1000; do
    [ "$other" = "$hz" ] || profile_cfg --disable "HZ_${other}"
  done
}

profile_set_preempt_full() {
  profile_cfg --enable PREEMPT_DYNAMIC
  profile_cfg --enable PREEMPT
  profile_cfg --disable PREEMPT_LAZY
  profile_cfg --disable PREEMPT_VOLUNTARY
  profile_cfg --disable PREEMPT_NONE
}

profile_set_preempt_relaxed() {
  local lazy_state
  profile_cfg --enable PREEMPT_DYNAMIC
  profile_cfg --disable PREEMPT
  lazy_state=$(scripts/config --state PREEMPT_LAZY)
  if [ "$lazy_state" != "undef" ]; then
    profile_cfg --disable PREEMPT_VOLUNTARY
    profile_cfg --disable PREEMPT_NONE
    profile_cfg --enable PREEMPT_LAZY
  else
    profile_cfg --disable PREEMPT_LAZY
    profile_cfg --disable PREEMPT_NONE
    profile_cfg --enable PREEMPT_VOLUNTARY
  fi
}

profile_set_thp_madvise() {
  profile_cfg --enable TRANSPARENT_HUGEPAGE
  profile_cfg --enable TRANSPARENT_HUGEPAGE_MADVISE
  profile_cfg --disable TRANSPARENT_HUGEPAGE_ALWAYS
}

profile_set_lru_gen() {
  if profile_kernel_ge "$LINUX_VER" 6.1; then
    profile_cfg --enable LRU_GEN
    profile_cfg --enable LRU_GEN_ENABLED
  else
    log_info "LRU_GEN is not available before Linux 6.1; skipping"
  fi
}

profile_set_bbr() {
  profile_cfg --enable TCP_CONG_BBR
  profile_cfg --enable NET_SCH_FQ
}

profile_set_bbr_default() {
  profile_cfg --disable DEFAULT_CUBIC
  profile_cfg --enable DEFAULT_BBR
  profile_cfg --set-str DEFAULT_TCP_CONG bbr
}

profile_set_o2() {
  profile_cfg --enable CC_OPTIMIZE_FOR_PERFORMANCE
  profile_cfg --disable CC_OPTIMIZE_FOR_PERFORMANCE_O3
}

profile_set_cgroup() {
  profile_cfg --enable PSI
  profile_cfg --enable CGROUPS
  profile_cfg --enable MEMCG
  profile_cfg --enable BPF_SYSCALL
  profile_cfg --enable BPF_JIT
  profile_cfg --enable CGROUP_BPF
  profile_cfg --enable FAIR_GROUP_SCHED
  profile_cfg --enable CFS_BANDWIDTH
  profile_cfg --enable SCHED_AUTOGROUP
}

profile_common() {
  profile_set_thp_madvise
  profile_set_lru_gen
  profile_cfg --enable PSI
  profile_cfg --enable ZRAM
  profile_set_bbr
}

# Balanced interactive desktop: low timer latency, full preemption, MGLRU,
# THP madvise, BBR and O3 (the CachyOS-style compiler choice).
profile_desktop() {
  profile_common
  profile_set_hz 1000
  profile_set_preempt_full
  profile_set_o2
}

# Build-heavy interactive desktop (LLM/Android builds): the desktop profile
# plus the cgroup knobs needed to keep builds in their own slice, and BBR as
# the default congestion control.
profile_workstation() {
  profile_desktop
  profile_set_cgroup
  profile_set_bbr_default
}

# Same timer/scheduler trade-off as desktop; kept separate so a gaming profile
# can grow scheduler-specific options without changing daily-driver defaults.
profile_gaming() {
  profile_desktop
}

# Throughput server: 250 Hz, relaxed preemption, O2, BBR default, and the
# group-scheduling knobs systemd needs for per-service CPU limits.
profile_server() {
  profile_common
  profile_set_hz 250
  profile_set_preempt_relaxed
  profile_set_o2
  profile_set_cgroup
  profile_cfg --set-val NR_CPUS 256
  profile_set_bbr_default
}

# Battery/thermal profile: 300 Hz, relaxed preemption, schedutil, P-state,
# the energy model, MGLRU and zram-friendly memory defaults.
profile_laptop() {
  profile_common
  profile_set_hz 300
  profile_set_preempt_relaxed
  profile_set_o2
  profile_cfg --enable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
  profile_cfg --enable X86_AMD_PSTATE
  profile_cfg --enable X86_INTEL_PSTATE
  profile_cfg --enable ENERGY_MODEL
}

# Legacy --lowlatency behavior. This is low-latency, not PREEMPT_RT.
profile_lowlatency() {
  profile_set_hz 1000
  profile_set_preempt_full
  profile_cfg --enable LATENCYTOP
  profile_cfg --disable COMEDI_TESTS_EXAMPLE
  profile_cfg --disable COMEDI_TESTS_NI_ROUTES
  profile_cfg --set-val TEST_DIV64 m
}

profile_is_valid() {
  case "$1" in
    desktop | workstation | gaming | server | laptop | lowlatency) return 0 ;;
    *) return 1 ;;
  esac
}

build_kernel_tag() {
  [ -n "$KERNEL_TAG" ] && return 0
  local tag=""
  if [ "$SOURCE" = "cachyos" ]; then
    tag="-cachyos"
  elif [ -n "$PROFILE" ]; then
    tag="-vanilla"
  fi
  [ -n "$PROFILE" ] && tag+="-$PROFILE"
  [ "$KERNEL_SCHED" != "eevdf" ] && tag+="-$KERNEL_SCHED"
  [ "$CPU" != "generic" ] && tag+="-$CPU"
  case "$LTO" in
    thin) tag+="-lto" ;;
    full) tag+="-ltofull" ;;
  esac
  [ -n "$HZ_OVERRIDE" ] && tag+="-hz${HZ_OVERRIDE}"
  [ "$BBR3" = "1" ] && tag+="-bbr3"
  [ "$BINDER" = "1" ] && tag+="-binder"
  [ "$SCHED_EXT" = "1" ] && tag+="-sched-ext"
  KERNEL_TAG="$tag"
}

apply_profile() {
  case "$1" in
    desktop) profile_desktop ;;
    workstation) profile_workstation ;;
    gaming) profile_gaming ;;
    server) profile_server ;;
    laptop) profile_laptop ;;
    lowlatency) profile_lowlatency ;;
    *) fatal "Unknown optimization profile: $1" ;;
  esac
}

# Fail the build if a profile symbol did not survive olddefconfig. This is
# what catches a profile that was silently dropped by a Kconfig dependency.
profile_assert() {
  local spec sym want got
  for spec in "$@"; do
    sym=${spec%%=*}
    want=${spec#*=}
    got=$(scripts/config --state "$sym")
    if [ "$got" != "$want" ]; then
      fatal "Profile ${PROFILE}: CONFIG_${sym} is '${got}', expected '${want}'"
    fi
  done
}

assert_profile() {
  local -a common=(
    TRANSPARENT_HUGEPAGE_MADVISE=y
    TRANSPARENT_HUGEPAGE_ALWAYS=n
    PSI=y
    ZRAM=y
    TCP_CONG_BBR=y
    NET_SCH_FQ=y
  )
  local -a expect=() filtered=()
  local item use_common=1
  if profile_kernel_ge "$LINUX_VER" 6.1; then
    common+=(LRU_GEN=y LRU_GEN_ENABLED=y)
  fi

  case "$1" in
    desktop | gaming)
      expect=(HZ=1000 HZ_1000=y PREEMPT=y CC_OPTIMIZE_FOR_PERFORMANCE=y)
      ;;
    workstation)
      expect=(HZ=1000 HZ_1000=y PREEMPT=y CC_OPTIMIZE_FOR_PERFORMANCE=y \
        MEMCG=y CGROUP_BPF=y FAIR_GROUP_SCHED=y CFS_BANDWIDTH=y \
        DEFAULT_BBR=y DEFAULT_TCP_CONG=bbr)
      ;;
    server)
      expect=(HZ=250 HZ_250=y PREEMPT=n \
        CC_OPTIMIZE_FOR_PERFORMANCE=y \
        MEMCG=y CGROUP_BPF=y FAIR_GROUP_SCHED=y CFS_BANDWIDTH=y \
        NR_CPUS=256 DEFAULT_BBR=y DEFAULT_TCP_CONG=bbr)
      ;;
    laptop)
      expect=(HZ=300 HZ_300=y PREEMPT=n \
        CC_OPTIMIZE_FOR_PERFORMANCE=y \
        CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y X86_AMD_PSTATE=y \
        X86_INTEL_PSTATE=y ENERGY_MODEL=y)
      ;;
    lowlatency)
      expect=(HZ=1000 HZ_1000=y PREEMPT=y LATENCYTOP=y)
      use_common=0
      ;;
    *)
      fatal "Unknown optimization profile: $1"
      ;;
  esac

  # Explicit flags override the profile, so assert the effective values.
  for item in "${expect[@]}"; do
    case "$item" in
      HZ=* | HZ_*=y)
        [ -n "$HZ_OVERRIDE" ] && continue
        ;;
      DEFAULT_BBR=y | DEFAULT_TCP_CONG=bbr)
        [ "$BBR3" = "1" ] && continue
        ;;
    esac
    filtered+=("$item")
  done
  [ -n "$HZ_OVERRIDE" ] && filtered+=("HZ=$HZ_OVERRIDE" "HZ_${HZ_OVERRIDE}=y")
  [ "$BBR3" = "1" ] && filtered+=(DEFAULT_BBR3=y DEFAULT_TCP_CONG=bbr3)
  if [ "$use_common" = "1" ]; then
    profile_assert "${common[@]}" "${filtered[@]}"
  else
    profile_assert "${filtered[@]}"
  fi
}

list_profiles() {
  cat <<'EOF'
desktop       Balanced interactive desktop: HZ 1000, full preempt, MGLRU, THP madvise, BBR, O2
workstation   Build-heavy interactive desktop: desktop + PSI/cgroup CPU limits + BBR default
gaming        Low-latency games: desktop timer/preempt settings, O2
server        Throughput server: HZ 250, relaxed preempt, MGLRU, BBR default, O2
laptop        Battery/thermal: HZ 300, relaxed preempt, schedutil/P-state, energy model, O2
lowlatency    Legacy low-latency profile: HZ 1000, full preempt, LATENCYTOP (not PREEMPT_RT)
EOF
}

# Copy the base config before the make target runs. Profiles default to the
# running kernel's config so the resulting kernel keeps the hardware support
# the machine already has; --base-config none keeps the historical behavior.
prepare_base_config() {
  [ -n "$BASE_CONFIG" ] || return 0
  case "$BASE_CONFIG" in
    none) return 0 ;;
    cachyos)
      if [ "$SOURCE" != "cachyos" ]; then
        fatal "--base-config cachyos requires --source cachyos"
        return 1
      fi
      if ! curl -fsSL --retry 3 -o .config "$CACHYOS_CONFIG_URL"; then
        fatal "Could not download the pinned CachyOS config"
        return 1
      fi
      if ! printf '%s  %s\n' "$CACHYOS_CONFIG_SHA256" ".config" | sha256sum -c - >/dev/null 2>&1; then
        fatal "CachyOS config checksum mismatch (expected ${CACHYOS_CONFIG_SHA256})"
        return 1
      fi
      log_info "Using pinned CachyOS kernel config"
      ;;
    running)
      local src
      src="/boot/config-$(uname -r)"
      if [ ! -f "$src" ]; then
        fatal "Base config ${src} not found; use --base-config /path or --base-config none"
        return 1
      fi
      if ! cp -f "$src" .config; then
        fatal "Could not copy ${src} to .config"
        return 1
      fi
      log_info "Using base kernel config: ${src}"
      ;;
    *)
      if [ ! -f "$BASE_CONFIG" ]; then
        fatal "Base config not found: ${BASE_CONFIG}"
        return 1
      fi
      if ! cp -f "$BASE_CONFIG" .config; then
        fatal "Could not copy ${BASE_CONFIG} to .config"
        return 1
      fi
      log_info "Using base kernel config: ${BASE_CONFIG}"
      ;;
  esac

  case "$CONFIG_OPTION" in
    defconfig | savedefconfig | allnoconfig | allyesconfig | allmodconfig | alldefconfig | randconfig | tinyconfig)
      log_warning "Base config was copied, but --config ${CONFIG_OPTION} creates a new config and will replace it."
      ;;
  esac
}
# --- End optimization profiles ---

changelog() {
  curl -s https://cdn.kernel.org/pub/linux/kernel/v"$(echo "$LINUX_VER" | cut -c1)".x/ChangeLog-${LINUX_VER} | less
}

# BANNERS
header_logo() {
  #header
  echo -e "${GREEN}"
  echo '    __ __                     __                      ';
  echo '   / //_/__  _________  ___  / /                      ';
  echo '  / ,< / _ \/ ___/ __ \/ _ \/ /                       ';
  echo ' / /| /  __/ /  / / / /  __/ /                        ';
  echo '/_/ |_\___/_/  /_/ /_/\___/_/____               __    ';
  echo '   /  _/___  _____/ /_____ _/ / /__  __________/ /_   ';
  echo '   / // __ \/ ___/ __/ __ \`/ / / _ \/ ___/ ___/ __ \ ';
  echo ' _/ // / / (__  ) /_/ /_/ / / /  __/ /  (__  ) / / /  ';
  echo '/___/_/ /_/____/\__/\__,_/_/_/\___/_(_)/____/_/ /_/   ';
  #echo '                                                      ';
  echo -e '                                                       ' "${NORMAL}"
}

# Header
# Print one centered line inside the header box
box_line() {
  local text=$1 inner=$2 pad
  pad=$(( (inner - ${#text}) / 2 ))
  printf ' ║%*s%s%*s║\n' "$pad" '' "$text" "$((inner - pad - ${#text}))" ''
}

header() {
  # Inner width of the box, excluding the border characters
  local HEADER_INNER=67 hr
  printf -v hr '%*s' "$HEADER_INNER" ''
  hr=${hr// /═}
  echo -e "${GREEN}\n"
  echo " ╔${hr}╗"
  box_line "${SCRIPT_FILENAME}" "$HEADER_INNER"
  box_line "Automatic kernel install script" "$HEADER_INNER"
  box_line "Maintained by @tmiland" "$HEADER_INNER"
  box_line "version: ${VERSION}" "$HEADER_INNER"
  echo " ╚${hr}╝"
  echo -e "${NORMAL}"
}

# Update banner
show_update_banner () {
  header
  echo ""
  echo "There is a newer version of ${SCRIPT_FILENAME} available."
  #echo ""
  echo ""
  echo -e "${GREEN}${DONE} New version:${NORMAL} ${RELEASE_TAG} - ${RELEASE_TITLE}"
  echo ""
  echo -e "${YELLOW}${ARROW} Notes:${NORMAL}\n"
  echo -e "${BLUE}${RELEASE_NOTE}${NORMAL}"
  echo ""
}

# Exit Script
exit_script() {
  header_logo
  echo -e "
   This script runs on coffee ☕

   ${GREEN}${CHECK}${NORMAL} ${BBLUE}Paypal${NORMAL} ${ARROW} ${YELLOW}https://paypal.me/milandtommy${NORMAL}
   ${GREEN}${CHECK}${NORMAL} ${BBLUE}BTC${NORMAL}    ${ARROW} ${YELLOW}33mjmoPxqfXnWNsvy8gvMZrrcG3gEa3YDM${NORMAL}
  "
  echo -e "Documentation for this script is available here: ${YELLOW}\n${ARROW} https://github.com/${REPO_NAME}${NORMAL}\n"
  echo -e "${YELLOW}${ARROW} Goodbye.${NORMAL} ☺"
  echo ""
}

##
# Returns the version number of ${SCRIPT_FILENAME} file on line 14
##
get_updater_version () {
  echo $(sed -n '14 s/[^0-9.]*\([0-9.]*\).*/\1/p' "$1")
}

# Pick a release asset download URL by an extended-regex match; empty if the
# release has no matching asset (#66).
release_asset_url() {
  printf '%s\n' "$1" |
    grep '"browser_download_url":' |
    grep -E -- "$2" |
    sed -n 's#.*\(https*://[^"]*\).*#\1#;p' |
    head -n 1
}

# Print the sha256 recorded for a file name in a SHA256SUMS file.
checksum_for_asset() {
  awk -v file="$2" '($2 == file || $2 == ("*" file)) { print $1; exit }' <<<"$1"
}

# Compare a file's sha256 with an expected 64-hex digest.
verify_sha256() {
  local actual
  [[ $2 =~ ^[0-9a-f]{64}$ ]] || return 1
  actual=$(sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1) || return 1
  [ -n "$actual" ] && [ "$actual" = "$2" ]
}

# Update script
# Default: Do not check for update
update_updater () {
  # --update replaces the running script file; a piped run has none (#72).
  if [ -z "$self" ] || [ -z "$SCRIPT_FILENAME" ] || [ -z "$SCRIPT_DIR" ] || [ ! -f "$self" ]; then
    log_error "Cannot update: --update needs the script to be a file, not a piped run. Download it first."
    return 1
  fi
  # Download a file, printing the temp path (empty on failure). The optional
  # second argument is a mktemp template; the new script is created next to
  # the old one so the final mv is a rename, not a cross-filesystem copy (#72).
  download_file () {
    local url=$1 template=${2:-} tf
    if [ -n "$template" ]; then
      tf=$(mktemp "$template") || { echo ''; return 0; }
    else
      tf=$(mktemp) || { echo ''; return 0; }
    fi
    if command -v curl >/dev/null 2>&1; then
      if curl -sSLf -o "$tf" "${url}"; then
        echo "$tf"
      else
        rm -f "$tf"
        echo ''
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -qO "$tf" "${url}"; then
        echo "$tf"
      else
        rm -f "$tf"
        echo ''
      fi
    else
      rm -f "$tf"
      echo ''
    fi
  }
  # Fetch the latest release info once, then parse the fields we need
  local release_json release_file tmpfile='' current_version checksums_file expected
  release_file=$(download_file "https://api.github.com/repos/${REPO_NAME}/releases/latest")
  if [ -n "$release_file" ]; then
    release_json=$(cat "$release_file")
    rm -f "$release_file"
  else
    release_json=''
  fi

  if [ -z "$release_json" ]; then
    log_error "Could not fetch the latest release info. Check your network connection."
    return 1
  fi

  # Latest release tag
  RELEASE_TAG=$(printf '%s\n' "$release_json" |
    grep '"tag_name":' |
    sed -n 's/[^0-9.]*\([0-9.]*\).*/\1/p')

  # Only the script asset and its checksum: the first asset is not necessarily
  # the script (a checksum file can be listed first).
  LATEST_RELEASE=$(release_asset_url "$release_json" '\.sh"')
  CHECKSUMS_URL=$(release_asset_url "$release_json" '(SHA256SUMS|sha256sums)"')

  # Latest release notes
  RELEASE_NOTE=$(printf '%s\n' "$release_json" |
    grep '"body":' |
    sed -n 's/.*"\([^"]*\)".*/\1/;p')

  # Latest release title
  RELEASE_TITLE=$(printf '%s\n' "$release_json" |
    grep -m 1 '"name":' |
    sed -n 's/.*"\([^"]*\)".*/\1/;p')

  echo -e "${GREEN}${ARROW} Checking for updates...${NORMAL}"
  current_version=$(get_updater_version "$self")

  # Only proceed when RELEASE_TAG is a strictly newer version
  if [ -n "$RELEASE_TAG" ] && [ "$current_version" != "$RELEASE_TAG" ] &&
    [ "$(printf '%s\n%s\n' "$current_version" "$RELEASE_TAG" | sort -V | tail -n1)" = "$RELEASE_TAG" ]; then
    if [ "$UPDATE_SCRIPT" = "1" ]; then
      show_update_banner
      echo -e "${RED}${ARROW} Do you want to update [Y/N?]${NORMAL}"
      ask REPLY -n 1
      echo -e "\n\n"
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -z "$LATEST_RELEASE" ]; then
          log_error "The latest release has no kernel_installer.sh asset. Aborting update."
          return 1
        fi
        if [ -z "$CHECKSUMS_URL" ]; then
          log_error "The latest release has no SHA256SUMS asset; refusing an unverified update."
          return 1
        fi
        tmpfile=$(download_file "$LATEST_RELEASE" "${SCRIPT_DIR}/.${SCRIPT_FILENAME}.XXXXXX")
        if [ -z "$tmpfile" ]; then
          log_error "Failed to download the new version. Aborting update."
          return 1
        fi
        checksums_file=$(download_file "$CHECKSUMS_URL")
        if [ -z "$checksums_file" ]; then
          log_error "Failed to download SHA256SUMS. Aborting update."
          rm -f "$tmpfile"
          return 1
        fi
        expected=$(checksum_for_asset "$(cat "$checksums_file")" "$SCRIPT_FILENAME")
        rm -f "$checksums_file"
        if [ -z "$expected" ] || ! verify_sha256 "$tmpfile" "$expected"; then
          log_error "Checksum verification failed; refusing to replace the script."
          rm -f "$tmpfile"
          return 1
        fi
        chmod 0755 "$tmpfile"
        if ! mv -f -- "$tmpfile" "${SCRIPT_DIR}/${SCRIPT_FILENAME}"; then
          log_error "Failed to install the new version. Aborting update."
          rm -f "$tmpfile"
          return 1
        fi
        echo -e "${GREEN}${DONE} Updated to version ${RELEASE_TAG} (checksum verified), restarting...${NORMAL}"

        # Re-exec the updated script, preserving the parsed options
        local -a reexec_args=()
        if [ "$mode" = "uninstall" ]; then
          reexec_args+=(--uninstall)
        fi
        local arg
        for arg in "$@"; do
          case "$arg" in
            --update | -upd) continue ;;
          esac
          reexec_args+=("$arg")
        done

        exec env \
          INSTALL_DIR="$INSTALL_DIR" \
          LINUX_VER="$LINUX_VER" \
          LINUX_VER_NAME="$LINUX_VER_NAME" \
          NPROC="$NPROC" \
          KEXEC="$KEXEC" \
          VERBOSE="$VERBOSE" \
          CONFIG_OPTION="$CONFIG_OPTION" \
          DEFAULT_COMPRESSION="$DEFAULT_COMPRESSION" \
          GET_VERIFIED_TARBALL="$GET_VERIFIED_TARBALL" \
          ENABLE_DEBUG_INFO="$ENABLE_DEBUG_INFO" \
          LOWLATENCY="$LOWLATENCY" \
          PROFILE="$PROFILE" \
          BASE_CONFIG="$BASE_CONFIG" \
          SOURCE="$SOURCE" \
          KERNEL_SCHED="$KERNEL_SCHED" \
          CPU="$CPU" \
          LTO="$LTO" \
          KERNEL_TAG="$KERNEL_TAG" \
          BANNERS="$BANNERS" \
          LIST_INSTALLED="$LIST_INSTALLED" \
          "${SCRIPT_DIR}/${SCRIPT_FILENAME}" "${reexec_args[@]}"
      fi
    fi
    return 1 # Update available, but not applied
  else
    echo -e "${GREEN}${DONE} No update available.${NORMAL}"
    return 0 # No update available
  fi
}

usage() {
  #header
  ## shellcheck disable=SC2046
  printf "Usage: %s %s [options]" "${CYAN}" "${SCRIPT_FILENAME}${NORMAL}"
  echo
  echo "  If called without arguments, installs stable kernel ${YELLOW}${LINUX_VER}${NORMAL} using ${INSTALL_DIR}"
  echo
  printf "%s\\n" "  ${YELLOW}--help                 |-h${NORMAL}   display this help and exit"
  printf "%s\\n" "  ${YELLOW}--kernel               |-k${NORMAL}   kernel version of choice"
  printf "%s\\n" "  ${YELLOW}--stable               |-s${NORMAL}   stable kernel version ${YELLOW}$STABLE_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--mainline             |-m${NORMAL}   mainline kernel version ${YELLOW}$MAINLINE_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--longterm             |-l${NORMAL}   longterm kernel version ${YELLOW}$LONGTERM_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--dir                  |-d${NORMAL}   install directory"
  printf "%s\\n" "  ${YELLOW}--kexec                |-x${NORMAL}   load new kernel without reboot"
  printf "%s\\n" "  ${YELLOW}--config               |-c${NORMAL}   set configuration target"
  printf "%s\\n" "  ${YELLOW}--custom-config        |-cc${NORMAL}  set custom configuration directive, can be used multiple times"
  printf "%s\\n" "  ${YELLOW}--profile              |-p${NORMAL}   optimization profile (see --list-profiles)"
  printf "%s\\n" "  ${YELLOW}--list-profiles        |-lp${NORMAL}  list optimization profiles and exit"
  printf "%s\\n" "  ${YELLOW}--base-config          |-bc${NORMAL}  profile base config: running, a path, cachyos, or none"
  printf "%s\\n" "  ${YELLOW}--source               |${NORMAL}      kernel source: vanilla (kernel.org) or cachyos (pinned)"
  printf "%s\\n" "  ${YELLOW}--sched                |${NORMAL}      scheduler for the cachyos source: eevdf or bore"
  printf "%s\\n" "  ${YELLOW}--cpu                  |${NORMAL}      CPU tuning: generic, native, zen4, x86-64-v3, x86-64-v4"
  printf "%s\\n" "  ${YELLOW}--lto                  |${NORMAL}      LTO: none, thin, or full (requires clang/lld)"
  printf "%s\\n" "  ${YELLOW}--hz                   |${NORMAL}      timer frequency: 100, 250, 300, 500, 600, 750, 1000"
  printf "%s\\n" "  ${YELLOW}--bbr3                 |${NORMAL}      make BBRv3 the default TCP congestion control (cachyos)"
  printf "%s\\n" "  ${YELLOW}--binder               |${NORMAL}      enable Android Binder IPC and binderfs (Waydroid)"
  printf "%s\\n" "  ${YELLOW}--sched-ext            |${NORMAL}      enable sched_ext and BTF for userspace BPF schedulers"
  printf "%s\\n" "  ${YELLOW}--kernel-tag           |${NORMAL}      custom localversion suffix (default: auto from source/profile)"
  printf "%s\\n" "  ${YELLOW}--verbose              |-v${NORMAL}   increase verbosity"
  printf "%s\\n" "  ${YELLOW}--get-verified-tarball |-gvt${NORMAL} cryptographically verify kernel tarball (default)"
  printf "%s\\n" "  ${YELLOW}--nproc                |-n${NORMAL}   set the number of processing units to use"
  printf "%s\\n" "  ${YELLOW}--enable-debug-info    |-edi${NORMAL} enable debug info"
  printf "%s\\n" "  ${YELLOW}--lowlatency           |-low${NORMAL} convert generic config to lowlatency"
  printf "%s\\n" "  ${YELLOW}--list-installed       |-li${NORMAL}  list installed kernels"
  printf "%s\\n" "  ${YELLOW}--default-compression  |-dc${NORMAL}  select default compression algorithm"
  printf "%s\\n" "  ${YELLOW}--changelog            |-cl${NORMAL}  view changelog for kernel version"
  printf "%s\\n" "  ${YELLOW}--update               |-upd${NORMAL} check for script update"
  printf "%s\\n" "  ${YELLOW}--uninstall            |-u${NORMAL}   uninstall kernel (use with -k option)"
  echo
  printf "%s\\n" "  Installed kernel version: ${YELLOW}${CURRENT_VER}${NORMAL}  | Script version: ${CYAN}${VERSION}${NORMAL}"
  echo
}

POSITIONAL_ARGS=()
CUSTOM_CONFIG_OPTIONS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --help | -h)
      usage
      exit 0
      ;;
    --verbose | -v)
      shift
      VERBOSE=1
      ;;
    --get-verified-tarball | -gvt)
      shift
      GET_VERIFIED_TARBALL=1
      ;;
    --stable | -s)
      shift
      LINUX_VER=$STABLE_VER
      LINUX_VER_NAME=Stable
      VER_SELECTED=1
      ;;
    --mainline | -m)
      shift
      LINUX_VER=$MAINLINE_VER
      LINUX_VER_NAME=Mainline
      VER_SELECTED=1
      ;;
    --longterm | -l)
      shift
      LINUX_VER=$LONGTERM_VER
      LINUX_VER_NAME=Longterm
      VER_SELECTED=1
      ;;
    --kernel | -k)
      require_arg "$1" "${2:-}"
      if ! valid_kernel_version "$2"; then
        fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Invalid kernel version: $2"
      fi
      LINUX_VER="$2"
      LINUX_VER_NAME=Custom
      VER_SELECTED=1
      shift 2
      ;;
    --dir | -d) # Bash Space-Separated (e.g., --option argument)
      require_arg "$1" "${2:-}"
      # Make a relative path absolute while $PWD is still the invocation
      # directory: install_kernel later cd's into INSTALL_DIR and still uses
      # the full path, which would otherwise resolve twice.
      INSTALL_DIR="$(realpath -m -- "$2")/linux-kernel" # Source: https://stackoverflow.com/a/14203146
      shift 2 # past option and value
      ;;
    --config | -c)
      require_arg "$1" "${2:-}"
      CONFIG_OPTION="$2"
      shift 2
      ;;
    --custom-config | -cc)
      require_arg "$1" "${2:-}"
      CUSTOM_CONFIG_OPTIONS+=("$2")
      shift 2
      ;;
    --profile | -p)
      require_arg "$1" "${2:-}"
      if ! profile_is_valid "$2"; then
        fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Unknown optimization profile: $2 (use --list-profiles)"
      fi
      PROFILE="$2"
      shift 2
      ;;
    --list-profiles | -lp)
      list_profiles
      exit 0
      ;;
    --base-config | -bc)
      require_arg "$1" "${2:-}"
      if [ "$2" != "running" ] && [ "$2" != "none" ] && [ "$2" != "cachyos" ] && [ ! -f "$2" ]; then
        fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Base config not found: $2"
      fi
      if [ "$2" = "running" ] || [ "$2" = "none" ] || [ "$2" = "cachyos" ]; then
        BASE_CONFIG="$2"
      else
        # Resolve now, before install_kernel cd's into the kernel tree.
        BASE_CONFIG="$(realpath -m -- "$2")"
      fi
      shift 2
      ;;
    --source)
      require_arg "$1" "${2:-}"
      case "$2" in
        vanilla | cachyos) SOURCE="$2" ;;
        *) fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Unknown kernel source: $2 (vanilla or cachyos)" ;;
      esac
      shift 2
      ;;
    --sched)
      require_arg "$1" "${2:-}"
      case "$2" in
        eevdf | bore) KERNEL_SCHED="$2" ;;
        *) fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Unknown scheduler: $2 (eevdf or bore)" ;;
      esac
      shift 2
      ;;
    --cpu)
      require_arg "$1" "${2:-}"
      case "$2" in
        generic | native | zen4 | x86-64-v3 | x86-64-v4) CPU="$2" ;;
        *) fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Unknown CPU tuning: $2 (generic, native, zen4, x86-64-v3, x86-64-v4)" ;;
      esac
      shift 2
      ;;
    --lto)
      require_arg "$1" "${2:-}"
      case "$2" in
        none | thin | full) LTO="$2" ;;
        *) fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Unknown LTO mode: $2 (none, thin, full)" ;;
      esac
      shift 2
      ;;
    --hz)
      require_arg "$1" "${2:-}"
      case "$2" in
        100 | 250 | 300 | 500 | 600 | 750 | 1000) HZ_OVERRIDE="$2" ;;
        *) fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Unknown --hz value: $2 (100, 250, 300, 500, 600, 750, 1000)" ;;
      esac
      shift 2
      ;;
    --bbr3)
      BBR3=1
      shift
      ;;
    --binder)
      BINDER=1
      shift
      ;;
    --sched-ext)
      SCHED_EXT=1
      shift
      ;;
    --kernel-tag)
      require_arg "$1" "${2:-}"
      KERNEL_TAG="$2"
      shift 2
      ;;
    --kexec | -x)
      shift
      KEXEC=1
      ;;
    --nproc | -n)
      require_arg "$1" "${2:-}"
      if [[ ! $2 =~ ^[1-9][0-9]*$ ]]; then
        fatal "${RED}${BALLOT_X}Fatal:${NORMAL} Invalid number of processing units: $2"
      fi
      NPROC=$2
      shift 2
      ;;
    --enable-debug-info | -edi)
      shift
      ENABLE_DEBUG_INFO=1
      ;;
    --lowlatency | -low)
      shift
      LOWLATENCY=1
      ;;
    --list-installed | -li)
      shift
      LIST_INSTALLED=1
      ;;
    --default-compression | -dc)
      require_arg "$1" "${2:-}"
      DEFAULT_COMPRESSION="$2"
      shift 2
      ;;
    --changelog | -cl)
      changelog
      exit 0
      ;;
    --update | -upd)
      UPDATE_SCRIPT=1
      update_updater "$@"
      exit $?
      ;;
    --uninstall | -u)
      shift
      mode="uninstall"
      ;;
    -* | --*)
      printf "%s\\n\\n" "Unrecognized option: $1"
      usage
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
  set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters
fi

if [ "$KERNEL_SCHED" = "bore" ] && [ "$SOURCE" != "cachyos" ]; then
  fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --sched bore requires --source cachyos"
fi

if [ "$SOURCE" = "cachyos" ]; then
  if [ "$VER_SELECTED" = "1" ] && [ "$LINUX_VER" != "$CACHYOS_VERSION" ]; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --source cachyos is pinned to ${CACHYOS_VERSION}; remove the version option or use ${CACHYOS_VERSION}"
  fi
  LINUX_VER="$CACHYOS_VERSION"
  LINUX_VER_NAME="CachyOS"
  VER_SELECTED=1
fi

if [ "$BASE_CONFIG" = "cachyos" ] && [ "$SOURCE" != "cachyos" ]; then
  fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --base-config cachyos requires --source cachyos"
fi

if [ -n "$KERNEL_TAG" ]; then
  KERNEL_TAG=${KERNEL_TAG#-}
  case "$KERNEL_TAG" in
    '' | *[!a-z0-9+.-]*)
      fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --kernel-tag must use lowercase letters, digits, '+', '.', or '-'"
      ;;
  esac
  KERNEL_TAG="-${KERNEL_TAG}"
fi

# --uninstall without -k targets the running kernel, which may have a
# localversion suffix.
if [ "$mode" = "uninstall" ] && [ "$VER_SELECTED" = "0" ]; then
  LINUX_VER=$(uname -r)
  LINUX_VER_NAME="Running"
  VER_SELECTED=1
fi

case "$CPU" in
  zen4 | x86-64-v3 | x86-64-v4)
    [ "$SOURCE" = "cachyos" ] || fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --cpu $CPU requires --source cachyos"
    ;;
esac

# 500/600/750 Hz are CachyOS choices; vanilla only has 100/250/300/1000.
case "$HZ_OVERRIDE" in
  '' | 100 | 250 | 300 | 1000) ;;
  500 | 600 | 750)
    [ "$SOURCE" = "cachyos" ] || fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --hz $HZ_OVERRIDE requires --source cachyos"
    ;;
esac

if [ "$BBR3" = "1" ] && [ "$SOURCE" != "cachyos" ]; then
  fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --bbr3 requires --source cachyos"
fi

if [ "$LTO" != "none" ]; then
  MAKE_LLVM="LLVM=1 LLVM_IAS=1"
else
  MAKE_LLVM=""
fi

# --lowlatency is kept as an alias for --profile lowlatency. Refuse the
# combination instead of guessing which one should win.
if [ "$LOWLATENCY" = "1" ]; then
  if [ -n "$PROFILE" ] && [ "$PROFILE" != "lowlatency" ]; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --lowlatency cannot be combined with --profile $PROFILE"
  fi
  PROFILE=lowlatency
  LOWLATENCY=0
fi

# Profiles are deltas on a real hardware config. CachyOS source builds use
# the pinned CachyOS config by default; vanilla profiles use the running
# kernel's config. --base-config none keeps the historical arch-defconfig
# behavior.
if [ -z "$BASE_CONFIG" ]; then
  if [ "$SOURCE" = "cachyos" ]; then
    BASE_CONFIG=cachyos
  elif [ -n "$PROFILE" ]; then
    BASE_CONFIG=running
  fi
fi

build_kernel_tag

# Custom directives must invoke scripts/config; anything else (e.g. a raw
# CONFIG_X=y assignment) would be silently ignored by eval
for custom_config_option in "${CUSTOM_CONFIG_OPTIONS[@]}"; do
  if [[ $custom_config_option != scripts/config* ]]; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --custom-config expects a scripts/config command, got: ${custom_config_option}"
  fi
done

# Configuration targets that talk to the user on a terminal (menus or
# prompts for new symbols). They run attached to /dev/tty instead of under
# run_ok, which sends all output to the log; check for a terminal now rather
# than after the download and unpack.
CONFIG_INTERACTIVE=0
case $CONFIG_OPTION in
  config | oldconfig | menuconfig | nconfig | localmodconfig | localyesconfig)
    CONFIG_INTERACTIVE=1
    if ! { : </dev/tty; } 2>/dev/null; then
      fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --config $CONFIG_OPTION needs an interactive terminal, but none is available"
    fi
    ;;
esac

# Fail fast without root: everything below (distro detection, the lsb-release
# prompt and its package installation, the dependency checks) assumes root,
# and a run piped through a one-liner must not get that far as a regular user.
chk_permissions
chk_logfile "$LOGFILE"

shopt -s nocasematch

# Distro detection reads /etc/os-release, the file meant for programs to read
# (#47). The Debian family used to be matched on /etc/issue.net instead, which
# is a login banner an admin is free to replace: a customized banner on an
# otherwise supported system ended in "unknown distro". Matching ID/ID_LIKE
# also covers derivatives the old name list missed.
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

# Print the value of <key> from os-release, without the surrounding quotes.
os_release_value() {
  local line
  line=$(grep -m1 "^$1=" "$OS_RELEASE_FILE" 2>/dev/null) || return 0
  line=${line#*=}
  line=${line#\"}
  line=${line%\"}
  printf '%s' "$line"
}

# Sets DISTRO (used in messages), DISTRO_GROUP, PKGCMD and LSB. Returns
# non-zero for a distro that is not supported yet, leaving DISTRO_GROUP set to
# the family it belongs to (Arch) or to "unknown".
detect_distro() {
  local os_id os_like pretty ids
  os_id=$(os_release_value ID)
  os_like=$(os_release_value ID_LIKE)
  pretty=$(os_release_value PRETTY_NAME)
  if [[ -z $os_id && -z $os_like ]]; then
    # No os-release (very old systems): fall back to the release files
    if [[ -f /etc/debian_version ]]; then
      os_id=debian
    elif [[ -f /etc/redhat-release ]]; then
      os_id=$(tr '[:upper:]' '[:lower:]' < /etc/redhat-release)
    fi
    DISTRO=${pretty:-$(cat /etc/issue.net 2>/dev/null)}
  else
    DISTRO=${pretty:-$os_id}
  fi
  # ID and ID_LIKE hold space-separated lists of IDs: match whole words, so
  # that e.g. "opensuse-leap" is not taken for Arch
  ids=" ${os_id,,} ${os_like,,} "
  case "$ids" in
    *" debian "* | *" ubuntu "*)
      # shellcheck disable=SC2140
      PKGCMD="apt-get -o Dpkg::Progress-Fancy="1" install -qq"
      LSB=lsb-release
      DISTRO_GROUP=Debian
      ;;
    # Fedora and the RHEL family (RHEL, Rocky, AlmaLinux, CentOS Stream,
    # Oracle Linux)
    *" rhel "* | *" fedora "* | *" centos "* | *" rocky "* | *" almalinux "*)
      PKGCMD="dnf install -y"
      LSB=redhat-lsb-core
      DISTRO_GROUP=RHEL
      ;;
    *" arch "*)
      PKGCMD="yes | LC_ALL=en_US.UTF-8 pacman -S"
      LSB=lsb-release
      DISTRO_GROUP=Arch
      return 1
      ;;
    *)
      DISTRO_GROUP=unknown
      return 1
      ;;
  esac
  return 0
}

if ! detect_distro; then
  if [[ $DISTRO_GROUP == "Arch" ]]; then
    echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}" ; exit 1
  fi
  echo -e "${RED}${BALLOT_X} unknown distro: '$DISTRO'${NORMAL}" ; exit 1
fi
# lsb_release is only needed to verify the install on Debian; the Fedora/RHEL
# family is detected via /etc/redhat-release and no longer ships lsb_release.
if [[ $DISTRO_GROUP != "RHEL" ]] && ! lsb_release -si 1>/dev/null 2>&1; then
  echo ""
  echo -e "${RED}${BALLOT_X} Looks like ${LSB} is not installed!${NORMAL}"
  echo ""
  ask ANSWER -p "Do you want to download ${LSB}? [y/n]? "
  echo ""
  case $ANSWER in
    [Yy]* )
      echo -e "${GREEN}${ARROW} Installing ${LSB} on ${DISTRO}...${NORMAL}"
      su -s "$(command -v bash)" -c "${PKGCMD} ${LSB}" || echo -e "${RED}${BALLOT_X} Error: could not install ${LSB}!${NORMAL}"
      echo -e "${GREEN}${CHECK} Done${NORMAL}"
      read_sleep 3
      #indexit
      ;;
    [Nn]* )
      exit 1;
      ;;
    * ) echo "Enter Y, N, please." ;;
  esac
fi
# SUDO=""
UPDATE=""
#UPGRADE=""
INSTALL=""
UNINSTALL=""
# PURGE=""
# CLEAN=""
PKGCHK=""
shopt -s nocasematch
if [[ $DISTRO_GROUP == "Debian" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  # SUDO="sudo"
  # shellcheck disable=SC2140
  UPDATE="apt-get -o Dpkg::Progress-Fancy="1" update -qq"
  # shellcheck disable=SC2140
  # UPGRADE="apt-get -o Dpkg::Progress-Fancy="1" upgrade -qq"
  # shellcheck disable=SC2140
  INSTALL="apt-get -o Dpkg::Progress-Fancy="1" install -qq -y"
  # # shellcheck disable=SC2140
  # UNINSTALL="apt-get -o Dpkg::Progress-Fancy="1" remove -qq"
  # # shellcheck disable=SC2140
  # PURGE="apt-get purge -o Dpkg::Progress-Fancy="1" -qq"
  # CLEAN="apt-get clean && apt-get autoremove -qq"
  PKGCHK="dpkg -s"
  #BUILD_DEP="apt-get -o Dpkg::Progress-Fancy="1" build-dep -qq"
  # Install packages
  # Package names are tracked against Debian 12/13 and Ubuntu 22.04/24.04:
  # "ncurses-dev" and "liblz4-tool" are transitional aliases that no longer
  # resolve on newer releases, and "paxctl" was removed from the archive.
  # cpio/kmod are required by the kernel's Build-Depends-Arch (mkdebian),
  # enforced by dpkg-checkbuilddeps during `make bindeb-pkg`.
  # gawk: the build runs it by name for CONFIG_BUILTIN_MODULE_RANGES
  # (scripts/Makefile.vmlinux), which Ubuntu configs enable; Debian and
  # Ubuntu only ship mawk by default.
  # python3: scripts/package/mkdebian lists python3:native in
  # Build-Depends-Arch since Linux 6.13, so dpkg-checkbuilddeps aborts
  # `make bindeb-pkg` without it -- minimal Debian/Ubuntu images do not
  # ship python3 (it was reported as an unmet build dependency on 7.2.11).
  INSTALL_PKGS="wget curl git rsync fakeroot cpio kmod build-essential patch libncurses-dev xz-utils zstd libssl-dev bc lz4 libelf-dev flex bison gawk debhelper dpkg-dev procps apt-transport-https libdw-dev python3 ca-certificates"
  #INSTALL_PKGS="build-essential fakeroot rsync git wget curl"
  # Build Dependencies
  #BUILD_DEP_PKGS="linux"
  elif [[ $DISTRO_GROUP == "RHEL" ]]; then
    # Fedora / RHEL family: dnf on Fedora and EL8+, yum on older EL
    if command -v dnf >/dev/null 2>&1; then
      RH_PM="dnf"
    else
      RH_PM="yum"
    fi
    UPDATE="${RH_PM} -q makecache"
    INSTALL="${RH_PM} -y -q install"
    UNINSTALL="${RH_PM} -y -q remove"
    PKGCHK="rpm -q"
    # Install packages
    # Package names are tracked against Fedora 44 and EL9:
    # bc/binutils/... mirror the kernel.spec BuildRequires (enforced by
    # rpmbuild during `make binrpm-pkg`), rpm-build provides rpmbuild,
    # dracut/grubby let the kernel rpm scriptlets create the initramfs and
    # boot entry at install time. gawk: see the Debian list above.
    # elfutils-devel provides libdw, required by the kernel.spec
    # BuildRequires check on newer mainline kernels.
    INSTALL_PKGS="wget curl git rsync ca-certificates procps-ng findutils diffutils hostname bc binutils bison dwarves elfutils-devel elfutils-libelf-devel flex gawk gcc make patch openssl openssl-devel perl python3 ncurses-devel cpio kmod xz lz4 zstd rpm-build dracut grubby"
  # elif [[ $DISTRO_GROUP == "Arch" ]]; then
  #   SUDO="sudo"
  #   UPDATE="pacman -Syu"
  #   INSTALL="pacman -S --noconfirm --needed"
  #   UNINSTALL="pacman -R"
  #   PURGE="pacman -Rs"
  #   CLEAN="pacman -Sc"
  #   PKGCHK="pacman -Qs"
  #   # Install packages
  #   INSTALL_PKGS=""
else
  echo -e "${RED}${BALLOT_X} Error: Sorry, your OS is not supported.${NORMAL}"
  exit 1;
fi

if [ "$LTO" != "none" ]; then
  # LTO needs clang/LLD; install them only when requested.
  INSTALL_PKGS+=" clang lld llvm"
fi

if [ "$SCHED_EXT" = "1" ]; then
  # BTF (sched_ext) is generated by pahole, provided by dwarves. The RHEL
  # package list already includes it.
  case "$DISTRO_GROUP" in
    Debian) INSTALL_PKGS+=" dwarves" ;;
  esac
fi

case "$DEFAULT_COMPRESSION" in
  lzo-rle)
    DEF_COM_NUM=1
    DEF_COM=LZORLE
  ;;
  lzo)
    DEF_COM_NUM=2
    DEF_COM=LZO
  ;;
  lz4)
    DEF_COM_NUM=3
    DEF_COM=LZ4
  ;;
  lz4hc)
    DEF_COM_NUM=4
    DEF_COM=LZ4HC
  ;;
  zstd)
    DEF_COM_NUM=5
    DEF_COM=ZSTD
  ;;
  deflate)
    DEF_COM_NUM=6
    DEF_COM=DEFLATE
  ;;
  842)
    DEF_COM_NUM=7
    DEF_COM=842
  ;;
  *)
  echo -e "${RED}${BALLOT_X} Error: Enter lzo-rle, lzo, lz4, lz4hc, zstd, deflate or 842 as argument.${NORMAL}"
  exit 1;
  ;;
esac

# Record why get_verified_tarball failed and remove its verification
# directory (only once it was created: before that TMPDIR may be the user's).
# get_verified_tarball runs under run_ok, whose output goes to the log, so it
# must return instead of exiting: an exit there ended the whole run with
# nothing on screen (#50). The caller shows VERIFY_ERROR.
# Print the primary fingerprints of keys whose user ID is exactly <email> in
# the given GnuPG homedir. gpg --export/--list-keys match user IDs by
# substring, and Fedora's gpg ignores --keyring for listing when use-keyboxd
# is enabled, so select from a homedir instead (#68).
key_fingerprints() {
  local gpgbin=$1 homedir=$2 email=$3
  "${gpgbin}" --batch --homedir "${homedir}" --with-colons --list-keys 2>/dev/null |
    awk -F: -v want="<${email}>" '
      $1 == "pub" { inkey = 1; fpr = ""; next }
      $1 == "sub" { inkey = 0 }
      inkey && $1 == "fpr" { fpr = $10; next }
      inkey && $1 == "uid" { if (index($10, want) > 0) { print fpr; inkey = 0 } }
    '
}

# Require exactly the pinned primary key for each kernel.org address, so a
# bundled file or a WKD response cannot substitute a different key.
check_kernel_key_fingerprints() {
  local gpgbin=$1 home=$2
  local -a fprs
  mapfile -t fprs < <(key_fingerprints "${gpgbin}" "${home}" torvalds@kernel.org)
  [ ${#fprs[@]} -eq 1 ] && [ "${fprs[0]}" = "${TORVALDS_FPR}" ] || return 1
  mapfile -t fprs < <(key_fingerprints "${gpgbin}" "${home}" gregkh@kernel.org)
  [ ${#fprs[@]} -eq 1 ] && [ "${fprs[0]}" = "${GREGKH_FPR}" ] || return 1
  mapfile -t fprs < <(key_fingerprints "${gpgbin}" "${home}" autosigner@kernel.org)
  [ ${#fprs[@]} -eq 1 ] && [ "${fprs[0]}" = "${AUTOSIGNER_FPR}" ] || return 1
}

# shellcheck disable=SC2329  # only called from get_verified_tarball (see there)
verify_fail() {
  VERIFY_ERROR=$1
  if [ -n "${verify_dir:-}" ]; then
    rm -rf "$verify_dir"
  fi
  if [ -n "${gpg_root:-}" ]; then
    rm -rf "$gpg_root"
  fi
}

# shellcheck disable=SC2329  # called by name through run_ok
get_verified_tarball() {
  # Keep the verify directory out of the environment: this function must not
  # clobber an exported TMPDIR, whose value later build steps rely on (#48).
  local TMPDIR keyring_home ok gpg_root=''
  # Source: https://git.kernel.org/pub/scm/linux/kernel/git/mricon/korg-helpers.git/tree/get-verified-tarball
  # get-verified-tarball
  # --------------------
  # Get Linux kernel tarball and cryptographically verify it,
  # retrieving the PGP keys using the Web Key Directory (WKD)
  # protocol if they are not already in the keyring.
  #
  # Pass the kernel version as the only parameter, or
  # we'll grab the latest stable kernel.
  #
  # Example: ./get-verified-tarball 4.4.145
  #
  # Configurable parameters
  # -----------------------
  # Where to download the tarball and verification data.
  TARGETDIR="$INSTALL_DIR"

  # A throwaway keyring is the default: root's own ~/.gnupg may contain keys
  # that were imported from anywhere. Set GNUPGHOME to reuse a keyring, and
  # see the USEKEYRING configuration option for CI keyrings.
  GNUPGHOME=${GNUPGHOME-}

  # For CI and other automated infrastructure, you may want to
  # create a keyring containing the keys belonging to:
  #  - autosigner@kernel.org
  #  - torvalds@kernel.org
  #  - gregkh@kernel.org
  #
  # To generate the keyring with these keys, do:
  #   gpg --export autosigner@ torvalds@ gregkh@ > keyring.gpg
  #   (or use full keyids for maximum certainty)
  #
  # Once you have keyring.gpg, install it on your CI system and set
  # USEKEYRING to the full path to it. If unset, we generate our own
  # from GNUPGHOME.
  USEKEYRING=

  # Point this at your GnuPG binary version 2.1.11 or above.
  # If you are using USEKEYRING, GnuPG-1 will work, too.
  # Modern distributions only ship the gpg/gpgv binaries.
  GPGBIN="$(command -v gpg2 || command -v gpg)"
  GPGVBIN="$(command -v gpgv2 || command -v gpgv)"
  # We need a compatible version of sha256sum, too
  SHA256SUMBIN="/usr/bin/sha256sum"
  # And curl
  CURLBIN="/usr/bin/curl"
  # And we need the xz binary
  XZBIN="/usr/bin/xz"

  # You shouldn't need to modify this, unless someone
  # other than Linus or Greg start releasing kernels.
  DEVKEYS="torvalds@kernel.org gregkh@kernel.org"
  # Don't add this to DEVKEYS, as it plays a wholly
  # different role and is NOT a key that should be used
  # to verify kernel tarball signatures (just the checksums).
  SHAKEYS="autosigner@kernel.org"

  # What kernel version do you want?
  # LINUX_VER=${1}
  # if [[ -z ${LINUX_VER} ]]; then
  #     # Assume you want the latest stable
  #     LINUX_VER=$(${CURLBIN} -sL https://www.kernel.org/finger_banner \
    #           | grep 'latest stable version' \
    #           | awk -F: '{gsub(/ /,"", $0); print $2}')
  # fi
  # if [[ -z ${LINUX_VER} ]]; then
  #     echo "Could not figure out the latest stable version."
  #     exit 1
  # fi

  VERIFY_ERROR=''
  verify_dir=''
  MAJOR="$(echo "${LINUX_VER}" | cut -d. -f1)"
  if [[ ${MAJOR} -lt 3 ]]; then
    verify_fail "This script only supports kernel v3.x.x and above"
    return 1
  fi

  if [[ ! -d ${TARGETDIR} ]]; then
    verify_fail "${TARGETDIR} does not exist"
    return 1
  fi

  TARGET="${TARGETDIR}/linux-${LINUX_VER}.tar.xz"
  # Never trust an existing tarball: the build directory is recreated for each
  # run, so a file here can only come from an interrupted run or from someone
  # who can write to the directory. Download and verify it again (#62).

  # Start by making sure our GnuPG environment is sane
  if [[ ! -x ${GPGBIN} || ! -x ${GPGVBIN} ]]; then
    echo "Could not find gpg or gpgv, installing gnupg"
    log_debug "Installing gnupg"
    ${INSTALL} gnupg ca-certificates
    GPGBIN="$(command -v gpg2 || command -v gpg)"
    GPGVBIN="$(command -v gpgv2 || command -v gpgv)"
    if [[ ! -x ${GPGBIN} || ! -x ${GPGVBIN} ]]; then
      verify_fail "Failed to install gpg or gpgv"
      return 1
    fi
    echo "done"
  fi

  # Let's make a safe temporary directory for intermediates
  if ! TMPDIR=$(mktemp -d "${TARGETDIR}"/linux-tarball-verify.XXXXXXXXX.untrusted); then
    verify_fail "Could not create a temporary directory in ${TARGETDIR}"
    return 1
  fi
  verify_dir=$TMPDIR
  log_debug "Using TMPDIR=${TMPDIR}"
  # GnuPG sockets have a ~108-character path limit; the build directory can be
  # deep (e.g. --dir under a long CI workspace), so keep gpg homes in /tmp.
  gpg_root=$(mktemp -d "${GPG_TMPDIR:-/tmp}/kernel-installer-gpg.XXXXXXXX") || {
    verify_fail "Could not create a temporary GnuPG directory"
    return 1
  }
  chmod 700 "${gpg_root}"
  # Build a private homedir containing exactly the keys to trust. A checkout
  # has src/keys/kernel.org.asc and uses it (no WKD/dirmngr dependency); piped
  # runs fall back to WKD. Fedora's gpg enables use-keyboxd, which makes
  # --keyring on a file ignored for --list-keys, so selection and export both
  # use a homedir (#68).
  if [[ -z ${USEKEYRING} ]]; then
    if [[ -n ${self:-} && -f "${SCRIPT_DIR}/${KERNEL_KEYRING_FILE}" ]]; then
      keyring_home="${gpg_root}/bundled"
      mkdir -m 0700 "${keyring_home}"
      if ! ${GPGBIN} --batch --homedir "${keyring_home}" \
        --import "${SCRIPT_DIR}/${KERNEL_KEYRING_FILE}" >/dev/null 2>&1; then
        verify_fail "Could not import the bundled kernel.org signing keys"
        return 1
      fi
      log_debug "Using bundled kernel.org signing keys"
    else
      if [[ -z ${GNUPGHOME} ]]; then
        GNUPGHOME="${gpg_root}/wkd"
      fi
      mkdir -p -m 0700 "${GNUPGHOME}"
      log_debug "Making sure we have all the necessary keys"
      ok=0
      # dirmngr occasionally fails to start on the first attempt in a fresh
      # container (and WKD needs it); retry before giving up.
      for _ in 1 2 3; do
        if ${GPGBIN} --batch --quiet \
          --homedir "${GNUPGHOME}" \
          --auto-key-locate wkd \
          --locate-keys ${DEVKEYS} ${SHAKEYS}; then
          ok=1
          break
        fi
        sleep 1
      done
      if [[ $ok != 1 ]]; then
        verify_fail "Could not fetch the kernel.org signing keys (gpg --locate-keys via WKD failed)"
        return 1
      fi
      keyring_home=$GNUPGHOME
    fi
    if ! check_kernel_key_fingerprints "${GPGBIN}" "${keyring_home}"; then
      verify_fail "The kernel.org signing keys do not match the pinned fingerprints"
      return 1
    fi
  else
    keyring_home="${gpg_root}/custom"
    mkdir -m 0700 "${keyring_home}"
    if ! ${GPGBIN} --batch --homedir "${keyring_home}" --import "${USEKEYRING}" >/dev/null 2>&1; then
      verify_fail "Could not import USEKEYRING ${USEKEYRING}"
      return 1
    fi
    if ! check_kernel_key_fingerprints "${GPGBIN}" "${keyring_home}"; then
      verify_fail "USEKEYRING does not contain the pinned kernel.org signing keys"
      return 1
    fi
  fi
  # Now we make two keyrings -- one for the autosigner, and
  # the other for kernel developers. We do this in order to
  # make sure that we never verify kernel tarballs using the
  # autosigner keys, only using developer keys. Select exact addresses and
  # export by fingerprint: gpg --export a@b also matches *a@b* (#68).
  SHAKEYRING=${TMPDIR}/shakeyring.gpg
  DEVKEYRING=${TMPDIR}/devkeyring.gpg
  mapfile -t SHA_FPRS < <(key_fingerprints "${GPGBIN}" "${keyring_home}" autosigner@kernel.org)
  mapfile -t DEV_FPRS < <(
    key_fingerprints "${GPGBIN}" "${keyring_home}" torvalds@kernel.org
    key_fingerprints "${GPGBIN}" "${keyring_home}" gregkh@kernel.org
  )
  if [ ${#SHA_FPRS[@]} -eq 0 ] || [ ${#DEV_FPRS[@]} -eq 0 ]; then
    verify_fail "Could not find the expected kernel.org signing keys (exact addresses) in the keyring"
    return 1
  fi
  ${GPGBIN} --batch --homedir "${keyring_home}" \
    --export "${SHA_FPRS[@]}" > "${SHAKEYRING}"
  ${GPGBIN} --batch --homedir "${keyring_home}" \
    --export "${DEV_FPRS[@]}" > "${DEVKEYRING}"

  # Now that we know we can verify them, grab the contents
  TXZ="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${LINUX_VER}.tar.xz"
  SIG="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${LINUX_VER}.tar.sign"
  SHA="https://www.kernel.org/pub/linux/kernel/v${MAJOR}.x/sha256sums.asc"

  # Before we verify the developer signature, we make sure that the
  # tarball matches what is on the kernel.org master. This avoids
  # CDN cache poisoning that could, in theory, use vulnerabilities in
  # the XZ binary to alter the verification process or compromise the
  # system performing the verification.
  SHAFILE=${TMPDIR}/sha256sums.asc
  log_debug "Downloading the checksums file for linux-${LINUX_VER}"
  if ! ${CURLBIN} -sL -o ${SHAFILE} ${SHA}; then
    verify_fail "Failed to download the checksums file"
    return 1
  fi
  log_debug "Verifying the checksums file"
  SHAFILE_SIGNED=${TMPDIR}/sha256sums.signed
  STATUSFILE=${TMPDIR}/sha256sums.status
  if ! ${GPGVBIN} --keyring=${SHAKEYRING} --status-fd=1 \
    --output "${SHAFILE_SIGNED}" "${SHAFILE}" > "${STATUSFILE}"; then
    verify_fail "FAILED to verify the sha256sums.asc file."
    return 1
  fi
  COUNT=$(grep -c -E '^\[GNUPG:\] (GOODSIG|VALIDSIG)' "${STATUSFILE}")
  if [[ ${COUNT} -lt 2 ]]; then
    verify_fail "FAILED to verify the sha256sums.asc file."
    return 1
  fi
  # Grab only the tarball we want from gpgv's output, never from text appended
  # after the signature block in the clearsigned file (#67).
  SHACHECK=${TMPDIR}/sha256sums.txt
  grep "linux-${LINUX_VER}.tar.xz" "${SHAFILE_SIGNED}" > "${SHACHECK}"

  echo
  log_debug "Downloading the signature file for linux-${LINUX_VER}"
  SIGFILE=${TMPDIR}/linux-${LINUX_VER}.tar.asc
  if ! ${CURLBIN} -sL -o ${SIGFILE} ${SIG}; then
    verify_fail "Failed to download the signature file"
    return 1
  fi
  log_debug "Downloading the XZ tarball for linux-${LINUX_VER}"
  TXZFILE=${TMPDIR}/linux-${LINUX_VER}.tar.xz
  if ! ${CURLBIN} -L -o ${TXZFILE} ${TXZ}; then
    verify_fail "Failed to download the tarball"
    return 1
  fi

  log_debug "Verifying checksum on linux-${LINUX_VER}.tar.xz"
  # sha256sum -c reads paths relative to the current directory
  if ! (cd "${TMPDIR}" && ${SHA256SUMBIN} -c ${SHACHECK}); then
    verify_fail "FAILED to verify the downloaded tarball checksum"
    return 1
  fi

  echo
  log_debug "Verifying developer signature on the tarball"
  COUNT=$(${XZBIN} -cd "${TXZFILE}" \
      | ${GPGVBIN} --keyring="${DEVKEYRING}" --status-fd=1 "${SIGFILE}" - \
    | grep -c -E '^\[GNUPG:\] (GOODSIG|VALIDSIG)')
  if [[ ${COUNT} -lt 2 ]]; then
    verify_fail "FAILED to verify the tarball signature"
    return 1
  fi
  mv -f "${TXZFILE}" "${TARGET}"
  rm -rf "${TMPDIR}"
  rm -rf "${gpg_root}"
  echo
  log_success "Successfully downloaded and verified ${TARGET}"
}

# Boot into the freshly installed kernel without a full reboot.
# systemctl kexec only loads a kernel by itself from Boot Loader
# Specification entries (UEFI, e.g. systemd-boot) and refuses otherwise, so
# load the new kernel explicitly first. The kernel is already installed at
# this point, so a kexec failure is reported but is not an install failure.
kexec_new_kernel() {
  local release=$1 image initrd
  local -a kexec_args
  image=/boot/vmlinuz-${release}
  if [[ $DISTRO_GROUP == "RHEL" ]]; then
    initrd=/boot/initramfs-${release}.img
  else
    initrd=/boot/initrd.img-${release}
  fi
  if ! command -v kexec >/dev/null 2>&1; then
    run_ok "${INSTALL} kexec-tools" "Installing kexec-tools..."
  fi
  if [ ! -f "$image" ]; then
    log_error "Kernel image $image not found; reboot to use kernel ${release}."
    return 0
  fi
  kexec_args=(-l "$image" --reuse-cmdline)
  if [ -f "$initrd" ]; then
    kexec_args+=(--initrd="$initrd")
  fi
  if ! kexec "${kexec_args[@]}"; then
    log_error "Kernel ${release} is installed, but kexec could not load it; reboot to use it."
    return 0
  fi
  log_info "Rebooting into kernel ${release} with kexec..."
  if ! systemctl kexec; then
    log_error "Kernel ${release} is installed, but systemctl kexec failed; reboot to use it."
  fi
  return 0
}

# Download and verify the pinned CachyOS source tarball. The CachyOS release
# is signed by Peter Jung or Eric Naim; checkout runs use the bundled public
# keys, piped runs fetch the same pinned fingerprints from keys.openpgp.org.
get_verified_cachyos_tarball() {
  local tar="linux-${LINUX_VER}.tar.gz"
  local asc="${tar}.asc"
  local gpg_root home valid fpr ok=0 status
  local gpg_bin
  gpg_bin=$(command -v gpg || command -v gpg2 || true)
  if [ -z "$gpg_bin" ]; then
    log_debug "Installing gnupg for CachyOS source verification"
    # shellcheck disable=SC2086
    ${INSTALL} gnupg >/dev/null 2>&1 || { verify_fail "Failed to install gnupg"; return 1; }
    gpg_bin=$(command -v gpg || command -v gpg2 || true)
  fi
  # shellcheck disable=SC2086
  ${CURLBIN:-curl} -fsSL --retry 3 -o "$tar" "$CACHYOS_SOURCE_URL" 2>/dev/null ||
    { verify_fail "Failed to download the CachyOS source tarball"; return 1; }
  # shellcheck disable=SC2086
  ${CURLBIN:-curl} -fsSL --retry 3 -o "$asc" "${CACHYOS_SOURCE_URL}.asc" 2>/dev/null ||
    { verify_fail "Failed to download the CachyOS source signature"; return 1; }

  gpg_root=$(mktemp -d "${GPG_TMPDIR:-/tmp}/cachyos-gpg.XXXXXXXX") ||
    { verify_fail "Could not create a temporary GnuPG directory"; return 1; }
  home="${gpg_root}/home"
  mkdir -m 0700 "$home" || { rm -rf "$gpg_root"; verify_fail "Could not create a GnuPG home"; return 1; }

  if [ -n "${self:-}" ] && [ -f "${SCRIPT_DIR}/${CACHYOS_KEYRING_FILE}" ]; then
    if ! "$gpg_bin" --batch --homedir "$home" --import "${SCRIPT_DIR}/${CACHYOS_KEYRING_FILE}" >/dev/null 2>&1; then
      rm -rf "$gpg_root"
      verify_fail "Could not import the bundled CachyOS signing keys"
      return 1
    fi
  else
    for fpr in "${CACHYOS_KEY_FINGERPRINTS[@]}"; do
      # shellcheck disable=SC2086
      if ! ${CURLBIN:-curl} -fsSL --retry 3 -o "${gpg_root}/${fpr}.asc" \
        "https://keys.openpgp.org/vks/v1/by-fingerprint/${fpr}" 2>/dev/null ||
        ! "$gpg_bin" --batch --homedir "$home" --import "${gpg_root}/${fpr}.asc" >/dev/null 2>&1; then
        rm -rf "$gpg_root"
        verify_fail "Could not fetch/import CachyOS key ${fpr}"
        return 1
      fi
    done
  fi

  if ! status=$("$gpg_bin" --batch --homedir "$home" --status-fd 1 \
    --verify "$asc" "$tar" 2>/dev/null); then
    rm -rf "$gpg_root"
    verify_fail "CachyOS source signature verification failed"
    return 1
  fi
  valid=$(printf '%s\n' "$status" | awk '/^\[GNUPG:\] VALIDSIG/{print $3; exit}')
  for fpr in "${CACHYOS_KEY_FINGERPRINTS[@]}"; do
    [ "$valid" = "$fpr" ] && ok=1
  done
  rm -rf "$gpg_root"
  if [ "$ok" -ne 1 ]; then
    verify_fail "CachyOS source is signed by an unexpected key: ${valid:-unknown}"
    return 1
  fi
  TARGET="${PWD}/${tar}"
  log_debug "Verified CachyOS source with key ${valid}"
  return 0
}

apply_cachyos_bore_patch() {
  [ "$SOURCE" = "cachyos" ] && [ "$KERNEL_SCHED" = "bore" ] || return 0
  local patch="cachyos-bore.patch"
  # shellcheck disable=SC2086
  ${CURLBIN:-curl} -fsSL --retry 3 -o "$patch" "$CACHYOS_BORE_PATCH_URL" 2>/dev/null ||
    fatal "Could not download the BORE scheduler patch"
  if ! printf '%s  %s\n' "$CACHYOS_BORE_PATCH_SHA256" "$patch" | sha256sum -c - >/dev/null 2>&1; then
    fatal "BORE scheduler patch checksum mismatch (expected ${CACHYOS_BORE_PATCH_SHA256})"
  fi
  if ! patch -p1 < "$patch" >/dev/null; then
    fatal "BORE scheduler patch failed to apply to the CachyOS source"
  fi
  log_success "BORE scheduler patch applied"
  return 0
}

configure_cachyos_source() {
  [ "$SOURCE" = "cachyos" ] || return 0
  scripts/config --enable CACHY
  if [ "$KERNEL_SCHED" = "bore" ]; then
    scripts/config --enable SCHED_BORE
  else
    scripts/config --disable SCHED_BORE
  fi
}

assert_cachyos_source() {
  [ "$SOURCE" = "cachyos" ] || return 0
  local got
  got=$(scripts/config --state CACHY)
  [ "$got" = "y" ] || fatal "CachyOS source: CONFIG_CACHY is '${got}', expected 'y'"
  if [ "$KERNEL_SCHED" = "bore" ]; then
    got=$(scripts/config --state SCHED_BORE)
    [ "$got" = "y" ] || fatal "CachyOS source: CONFIG_SCHED_BORE is '${got}', expected 'y'"
  fi
}

configure_cpu() {
  case "$CPU" in
    generic)
      if [ "$SOURCE" = "cachyos" ]; then
        scripts/config --enable GENERIC_CPU
        scripts/config --set-val X86_64_VERSION 1
        scripts/config --disable X86_NATIVE_CPU
        scripts/config --disable MZEN4
      fi
      ;;
    native)
      scripts/config --enable X86_NATIVE_CPU
      scripts/config --disable GENERIC_CPU
      scripts/config --disable MZEN4
      ;;
    zen4)
      scripts/config --enable MZEN4
      scripts/config --disable GENERIC_CPU
      scripts/config --disable X86_NATIVE_CPU
      ;;
    x86-64-v3 | x86-64-v4)
      scripts/config --enable GENERIC_CPU
      scripts/config --disable X86_NATIVE_CPU
      scripts/config --disable MZEN4
      scripts/config --set-val X86_64_VERSION "${CPU##*-v}"
      ;;
  esac
}

assert_cpu() {
  local got
  case "$CPU" in
    generic)
      [ "$SOURCE" = "cachyos" ] || return 0
      got=$(scripts/config --state GENERIC_CPU)
      [ "$got" = "y" ] || fatal "CPU tuning generic: CONFIG_GENERIC_CPU is '${got}', expected 'y'"
      got=$(scripts/config --state X86_64_VERSION)
      [ "$got" = "1" ] || fatal "CPU tuning generic: CONFIG_X86_64_VERSION is '${got}', expected '1'"
      ;;
    native)
      got=$(scripts/config --state X86_NATIVE_CPU)
      [ "$got" = "y" ] || fatal "CPU tuning native: CONFIG_X86_NATIVE_CPU is '${got}', expected 'y'"
      ;;
    zen4)
      got=$(scripts/config --state MZEN4)
      [ "$got" = "y" ] || fatal "CPU tuning zen4: CONFIG_MZEN4 is '${got}', expected 'y'"
      ;;
    x86-64-v3 | x86-64-v4)
      got=$(scripts/config --state GENERIC_CPU)
      [ "$got" = "y" ] || fatal "CPU tuning ${CPU}: CONFIG_GENERIC_CPU is '${got}', expected 'y'"
      got=$(scripts/config --state X86_64_VERSION)
      [ "$got" = "${CPU##*-v}" ] || fatal "CPU tuning ${CPU}: CONFIG_X86_64_VERSION is '${got}', expected '${CPU##*-v}'"
      ;;
  esac
}

check_dkms_release() {
  local release=$1 status
  command -v dkms >/dev/null 2>&1 || return 0
  status=$(dkms status -k "$release" 2>/dev/null || true)
  if [ -z "$status" ]; then
    log_warning "No DKMS modules are built for ${release}; run: dkms autoinstall -k ${release}"
    return 0
  fi
  printf '%s\n' "$status" | while IFS= read -r line; do
    log_info "DKMS: ${line}"
  done
}

configure_kernel_name() {
  [ -n "$KERNEL_TAG" ] || return 0
  scripts/config --set-str LOCALVERSION "$KERNEL_TAG"
  scripts/config --disable LOCALVERSION_AUTO
}

assert_kernel_name() {
  [ -n "$KERNEL_TAG" ] || return 0
  local got
  got=$(scripts/config --state LOCALVERSION)
  [ "$got" = "$KERNEL_TAG" ] || fatal "Kernel name: CONFIG_LOCALVERSION is '${got}', expected '${KERNEL_TAG}'"
  got=$(scripts/config --state LOCALVERSION_AUTO)
  [ "$got" = "n" ] || fatal "Kernel name: CONFIG_LOCALVERSION_AUTO is '${got}', expected 'n'"
}

configure_lto() {
  case "$LTO" in
    none)
      scripts/config --enable LTO_NONE
      scripts/config --disable LTO_CLANG_THIN
      scripts/config --disable LTO_CLANG_FULL
      ;;
    thin)
      scripts/config --enable LTO_CLANG_THIN
      scripts/config --disable LTO_CLANG_FULL
      scripts/config --disable LTO_NONE
      ;;
    full)
      scripts/config --enable LTO_CLANG_FULL
      scripts/config --disable LTO_CLANG_THIN
      scripts/config --disable LTO_NONE
      ;;
  esac
}

assert_lto() {
  [ "$LTO" = "none" ] && return 0
  local got
  got=$(scripts/config --state CC_IS_CLANG)
  [ "$got" = "y" ] || fatal "LTO ${LTO}: CONFIG_CC_IS_CLANG is '${got}', expected 'y'"
  if [ "$LTO" = "thin" ]; then
    got=$(scripts/config --state LTO_CLANG_THIN)
    [ "$got" = "y" ] || fatal "LTO thin: CONFIG_LTO_CLANG_THIN is '${got}', expected 'y'"
  else
    got=$(scripts/config --state LTO_CLANG_FULL)
    [ "$got" = "y" ] || fatal "LTO full: CONFIG_LTO_CLANG_FULL is '${got}', expected 'y'"
  fi
}

# Timer frequency: set HZ and the matching HZ_<n> choice, clear the others.
configure_hz() {
  [ -n "$HZ_OVERRIDE" ] || return 0
  local hz=$HZ_OVERRIDE other
  scripts/config --set-val HZ "$hz"
  scripts/config --enable "HZ_${hz}"
  for other in 100 250 300 500 600 750 1000; do
    [ "$other" = "$hz" ] || scripts/config --disable "HZ_${other}"
  done
}

# BBRv3 as the default congestion control (CachyOS patchset).
configure_bbr3() {
  [ "$BBR3" = "1" ] || return 0
  scripts/config --enable TCP_CONG_BBR3
  scripts/config --enable DEFAULT_BBR3
  scripts/config --disable DEFAULT_BBR
  scripts/config --set-str DEFAULT_TCP_CONG bbr3
}

# Android Binder IPC and binderfs, used by Waydroid and Android app layers.
configure_binder() {
  [ "$BINDER" = "1" ] || return 0
  scripts/config --enable ANDROID_BINDER_IPC
  scripts/config --enable ANDROID_BINDERFS
  scripts/config --set-str ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder"
}

# sched_ext needs BTF, which the installer otherwise disables with the rest of
# the debug information. Re-enable DWARF5 and BTF, then the scheduling class.
configure_sched_ext() {
  [ "$SCHED_EXT" = "1" ] || return 0
  if [ "$(versionToInt "$LINUX_VER")" -lt "$(versionToInt 6.12)" ]; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} --sched-ext requires kernel 6.12 or newer"
  fi
  scripts/config --disable DEBUG_INFO_NONE
  scripts/config --enable DEBUG_INFO_DWARF5
  scripts/config --enable DEBUG_INFO_BTF
  scripts/config --enable DEBUG_INFO_BTF_MODULES
  scripts/config --enable BPF_SYSCALL
  scripts/config --enable BPF_JIT
  scripts/config --enable SCHED_CLASS_EXT
}

assert_hz() {
  [ -n "$HZ_OVERRIDE" ] || return 0
  local got
  got=$(scripts/config --state HZ)
  [ "$got" = "$HZ_OVERRIDE" ] || fatal "Timer frequency: CONFIG_HZ is '${got}', expected '${HZ_OVERRIDE}'"
  got=$(scripts/config --state "HZ_${HZ_OVERRIDE}")
  [ "$got" = "y" ] || fatal "Timer frequency: CONFIG_HZ_${HZ_OVERRIDE} is '${got}', expected 'y'"
}

assert_bbr3() {
  [ "$BBR3" = "1" ] || return 0
  local got
  got=$(scripts/config --state TCP_CONG_BBR3)
  [ "$got" = "y" ] || fatal "BBR3: CONFIG_TCP_CONG_BBR3 is '${got}', expected 'y'"
  got=$(scripts/config --state DEFAULT_BBR3)
  [ "$got" = "y" ] || fatal "BBR3: CONFIG_DEFAULT_BBR3 is '${got}', expected 'y'"
  got=$(scripts/config --state DEFAULT_TCP_CONG)
  [ "$got" = "bbr3" ] || fatal "BBR3: CONFIG_DEFAULT_TCP_CONG is '${got}', expected 'bbr3'"
}

assert_binder() {
  [ "$BINDER" = "1" ] || return 0
  local got
  got=$(scripts/config --state ANDROID_BINDER_IPC)
  [ "$got" = "y" ] || fatal "Binder: CONFIG_ANDROID_BINDER_IPC is '${got}', expected 'y'"
  got=$(scripts/config --state ANDROID_BINDERFS)
  [ "$got" = "y" ] || fatal "Binder: CONFIG_ANDROID_BINDERFS is '${got}', expected 'y'"
}

assert_sched_ext() {
  [ "$SCHED_EXT" = "1" ] || return 0
  local got
  got=$(scripts/config --state SCHED_CLASS_EXT)
  [ "$got" = "y" ] || fatal "sched_ext: CONFIG_SCHED_CLASS_EXT is '${got}', expected 'y'"
  got=$(scripts/config --state DEBUG_INFO_BTF)
  [ "$got" = "y" ] || fatal "sched_ext: CONFIG_DEBUG_INFO_BTF is '${got}', expected 'y'"
}

install_kernel() {
  if [ "$INTERACTIVE_MODE" = "on" ]; then
    clear
  fi
  header_logo
  log_info "Started installation log in $LOGFILE"
  echo
  log_info "${CYANBG}Installing The Linux Kernel version:${NORMAL} $LINUX_VER_NAME: ${YELLOW}$LINUX_VER${NORMAL}"
  echo
  printf "%s \\n" "${YELLOW}▣${CYAN}□□□□□${NORMAL} Phase ${YELLOW}1${NORMAL} of ${GREEN}6${NORMAL}: Setup packages"
  # Setup Dependencies
  log_debug "Phase 1 of 6: Dependencies setup"
  log_debug "Configuring package manager for ${DISTRO_GROUP} .."
  if ! ${PKGCHK} $INSTALL_PKGS 1>/dev/null 2>&1; then
    log_debug "Updating packages"
    run_ok "${UPDATE}" "Updating package repo..."
    # Collect only the missing packages and install them in a single
    # transaction: installing them one by one re-resolves the dependency
    # graph for every package (slow) and silently ignored install errors.
    MISSING_PKGS=""
    for i in $INSTALL_PKGS; do
      if ! ${PKGCHK} "${i}" 1>/dev/null 2>&1; then
        MISSING_PKGS="${MISSING_PKGS} ${i}"
      fi
    done
    if [ -n "${MISSING_PKGS}" ]; then
      log_debug "Installing required packages:${MISSING_PKGS}"
      # shellcheck disable=SC2086
      if ! run_ok "${INSTALL}${MISSING_PKGS}" "Installing required packages..."; then
        fatal "Failed to install required packages:${MISSING_PKGS}"
      fi
    fi
  fi
  # log_debug "Install build dependencies required by the kernel build process"
  # run_ok "${BUILD_DEP} ${BUILD_DEP_PKGS}" "Installing build dependencies"
  log_success "Package Setup Finished"
  log_diagnostics

  # Reap any clingy processes (like spinner forks)
  # get the parent pids (as those are the problem)
  allpids="$(ps -o pid= --ppid $$) $allpids"
  for pid in $allpids; do
    kill "$pid" 1>/dev/null 2>&1
  done

  # Next step is configuration. Wait here for a moment, hopefully letting any
  # apt processes disappear before we start, as they're huge and memory is a
  # problem. XXX This is hacky. I'm not sure what's really causing random fails.
  read_sleep 1
  echo
  # Download Linux source code
  log_debug "Phase 2 of 6: Linux source code download"
  printf "%s \\n" "${GREEN}▣${YELLOW}▣${CYAN}□□□□${NORMAL} Phase ${YELLOW}2${NORMAL} of ${GREEN}6${NORMAL}: Download Linux source code"
  log_debug "Deleting old Linux source code files in $INSTALL_DIR"
  prepare_install_dir
  if [ -d "$INSTALL_DIR" ]; then
    cd "$INSTALL_DIR" || exit 1
    log_debug "Downloading Linux source code"
    if [ "$SOURCE" = "cachyos" ]; then
      # CachyOS source is signed by its release keys, not kernel.org.
      if ! RUN_ERRORS_FATAL='' run_ok "get_verified_cachyos_tarball" "Downloading and Verifying CachyOS source tarball..."; then
        fatal "Failed to download and verify the CachyOS source tarball: ${VERIFY_ERROR:-see the log for details}"
      fi
      log_debug "Verified tarball: ${TARGET}"
      log_success "Downloaded and verified ${TARGET##*/}"
      file_ext=gz
    elif [ "$LINUX_VER_NAME" != "Mainline" ] && [ "$GET_VERIFIED_TARBALL" = "1" ]; then
      # get-verified-tarball function; handle a failure here (not in run_ok)
      # so the reason is shown on screen
      if ! RUN_ERRORS_FATAL='' run_ok "get_verified_tarball" "Downloading and Verifying source code tarball..."; then
        fatal "Failed to download and verify the kernel tarball: ${VERIFY_ERROR:-see the log for details}"
      fi
      log_debug "Verified tarball: ${TARGET}"
      log_success "Downloaded and verified ${TARGET##*/}"
      file_ext=xz
    else
      if [ "$LINUX_VER_NAME" = "Mainline" ]; then
        # Kernel url 2 (Mainline)
        # git.kernel.org snapshots are not signed, so they cannot go through
        # get_verified_tarball and are always downloaded as-is
        if [ "$GET_VERIFIED_TARBALL" = "1" ]; then
          log_warning "Mainline snapshots are not signed; skipping tarball verification."
        fi
        kernel_url=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/linux-"${LINUX_VER}".tar.gz
        file_ext=gz
      else
        # Kernel url 1 (Stable/longterm)
        kernel_url=https://cdn.kernel.org/pub/linux/kernel/v"$(echo "$LINUX_VER" | cut -c1)".x/linux-"${LINUX_VER}".tar.xz
        file_ext=xz
      fi
      if [ ! -f linux-"${LINUX_VER}".tar.$file_ext ]; then
        log_debug "Downloading Linux source code"
        run_ok "wget -c $kernel_url" "Downloading..."
        log_success "Download finished"
      fi
    fi
    echo
    # Unpacking
    log_debug "Phase 3 of 6: Linux source code Unpacking"
    printf "%s \\n" "${GREEN}▣▣${YELLOW}▣${CYAN}□□□${NORMAL} Phase ${YELLOW}3${NORMAL} of ${GREEN}6${NORMAL}: Unpacking Linux source code"
    log_debug "Unpacking Linux source code"
    # No -v: the file listing (~90,000 lines) used to bury the build output in the log
    run_ok "tar xf linux-${LINUX_VER}.tar.$file_ext" "Unpacking..."
    log_success "Unpacking finished"
    if [ "$SOURCE" = "cachyos" ]; then
      if [ -d "$CACHYOS_SRCNAME" ]; then
        mv "$CACHYOS_SRCNAME" "linux-${LINUX_VER}" || fatal "Could not rename the CachyOS source tree"
      fi
      [ -d "linux-${LINUX_VER}" ] || fatal "CachyOS source did not unpack as linux-${LINUX_VER}"
    fi
    #)
  fi
  if [ -d "$INSTALL_DIR"/linux-"${LINUX_VER}" ]; then
    (
      #cd linux-"${LINUX_VER}" || exit
      cd "$INSTALL_DIR"/linux-"${LINUX_VER}" || exit 1
      echo
      # Config
      log_debug "Phase 4 of 6: Configuration"
      printf "%s \\n" "${GREEN}▣▣▣${YELLOW}▣${CYAN}□□${NORMAL} Phase ${YELLOW}4${NORMAL} of ${GREEN}6${NORMAL}: Setup kernel"
      prepare_base_config
      log_debug "Configuring..."
      if [ "$SOURCE" = "cachyos" ]; then
        apply_cachyos_bore_patch
      fi
      if [ "$CONFIG_INTERACTIVE" = "1" ]; then
        log_info "Running make $CONFIG_OPTION; save the configuration and exit to continue."
        # shellcheck disable=SC2086
        if ! ${MAKE_LLVM:+$MAKE_LLVM }make "$CONFIG_OPTION" </dev/tty >/dev/tty 2>&1; then
          fatal "make $CONFIG_OPTION failed"
        fi
      else
        run_ok "${MAKE_LLVM:+$MAKE_LLVM }make $CONFIG_OPTION" "Writing configuration..."
      fi
      log_success "Configuration finished"
      read_sleep 1
      # Disable debug info since it's enabled by default
      if [ "$ENABLE_DEBUG_INFO" = "0" ]; then
        disable_debug_info "$LINUX_VER"
      fi
      # Revert zstd changes from 6.12
      VER1=$LINUX_VER # version to check if is greater than or equal to
      VER2=6.12 # required version
      if [ "$(versionToInt $VER1)" -ge "$(versionToInt $VER2)" ]; then
        # enable zstd
        # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1086172#19
        scripts/config --enable CONFIG_ZRAM_BACKEND_ZSTD
        # Disable forced compression
        scripts/config --disable CONFIG_ZRAM_BACKEND_FORCE_LZO
        # Disable default lzorle
        scripts/config --disable CONFIG_ZRAM_DEF_COMP_LZORLE
        # Set default zram comp
        scripts/config --enable CONFIG_ZRAM_DEF_COMP_$DEF_COM
        scripts/config --set-str CONFIG_ZRAM_DEF_COMP "$DEFAULT_COMPRESSION"
        # Enable optional algorithms
        scripts/config --enable CONFIG_ZRAM_BACKEND_LZ4
        scripts/config --enable CONFIG_ZRAM_BACKEND_LZ4HC
        scripts/config --enable CONFIG_ZRAM_BACKEND_DEFLATE
        scripts/config --enable CONFIG_ZRAM_BACKEND_842
        scripts/config --enable CONFIG_ZRAM_BACKEND_LZO
      fi
      if [ "$SOURCE" = "cachyos" ]; then
        configure_cachyos_source
      fi
      configure_cpu
      configure_lto
      configure_kernel_name
      if [ -n "$PROFILE" ]; then
        log_info "Applying optimization profile: ${PROFILE}"
        apply_profile "$PROFILE"
      fi
      # Explicit flags override the profile; --custom-config overrides both.
      configure_hz
      configure_bbr3
      configure_binder
      configure_sched_ext
      for custom_config_option in "${CUSTOM_CONFIG_OPTIONS[@]}"; do
        log_debug "Adding custom config option: \"$custom_config_option\""
        eval "$custom_config_option"
      done
      # After --custom-config, so a certificate the user provides is kept
      clear_missing_cert_keys
      run_ok "${MAKE_LLVM:+$MAKE_LLVM }make olddefconfig" "Finalizing configuration..."
      if [ -n "$PROFILE" ]; then
        assert_profile "$PROFILE"
      fi
      if [ "$SOURCE" = "cachyos" ]; then
        assert_cachyos_source
      fi
      assert_cpu
      assert_lto
      assert_kernel_name
      assert_hz
      assert_bbr3
      assert_binder
      assert_sched_ext
      echo
      # Compilation
      log_debug "Phase 5 of 6: Compilation"
      printf "%s \\n" "${GREEN}▣▣▣▣${YELLOW}▣${CYAN}□${NORMAL} Phase ${YELLOW}5${NORMAL} of ${GREEN}6${NORMAL}: Kernel Compilation"
      log_debug "Compiling The Linux Kernel source code"
      printf "%s \\n" "Go grab a coffee ☕ 😎 This may take a while..."
      # Add echo 5 to answer Default zram compressor as zstd
      if [[ $DISTRO_GROUP == "RHEL" ]]; then
        build_target=binrpm-pkg
      else
        build_target=bindeb-pkg
      fi
      # Remember where the build output starts in the log, and handle a
      # failure here (instead of run_ok's tail) to point at the real error
      build_log_start=$(wc -l < "$RUN_LOG" 2>/dev/null || echo 0)
      if ! RUN_ERRORS_FATAL='' run_ok "echo $DEF_COM_NUM | ${MAKE_LLVM:+$MAKE_LLVM }make $build_target -j${NPROC}" "Compiling The Linux Kernel source code..."; then
        report_build_failure "$build_log_start"
        exit 1
      fi
      log_success "Compiling finished"
      echo
      # Installation
      log_debug "Phase 6 of 6: Installation"
      printf "%s \\n" "${GREEN}▣▣▣▣▣${YELLOW}▣${NORMAL} Phase ${YELLOW}6${NORMAL} of ${GREEN}6${NORMAL}: Kernel Installation"
      cd - 1>/dev/null 2>&1 || exit 1
    ) || exit 1 # a failed configure/build step ends the run here, not at phase 6
  fi
  # if [ $LINUX_VER_NAME = "Mainline" ]; then

  LINUX_VER_FILE="$INSTALL_DIR"/linux-"${LINUX_VER}"/Makefile
  LINUX_VER_FINAL_FILE="$INSTALL_DIR"/linux_full_ver

  # Grab version numbers from Makefile > Output to final version file
  get_linux_full_ver "$LINUX_VER_FILE" > "$LINUX_VER_FINAL_FILE"
  # Strip spaces on the first two and add a . then just stript the last space
  sed -i 's/  */./;s/  */./;s/ //g' "$LINUX_VER_FINAL_FILE"
  # Final version should look like 5.18.0-rc7
  LINUX_FULL_VER=$(cat "$LINUX_VER_FINAL_FILE")

  # mkdebian and kernel.spec name the packages after the release the configured
  # tree builds, CONFIG_LOCALVERSION included (6.12.113-test). The Makefile
  # alone does not know the localversion. Prefer the built image package, whose
  # name mkdebian derived from that release; ask the tree next (rpm builds), and
  # fall back to the guessed release only when neither can answer (#49, #74).
  if [[ $DISTRO_GROUP != "RHEL" ]] && BUILT_DEB_RELEASE=$(built_deb_release "$INSTALL_DIR"); then
    if [[ $BUILT_DEB_RELEASE != "$LINUX_FULL_VER" ]]; then
      log_debug "Kernel release from the built package: ${BUILT_DEB_RELEASE} (Makefile gives ${LINUX_FULL_VER})"
    fi
    LINUX_FULL_VER=$BUILT_DEB_RELEASE
  elif BUILT_KERNELRELEASE=$(built_kernelrelease "$INSTALL_DIR/linux-${LINUX_VER}"); then
    if [[ $BUILT_KERNELRELEASE != "$LINUX_FULL_VER" ]]; then
      log_debug "Kernel release from the tree: ${BUILT_KERNELRELEASE} (Makefile gives ${LINUX_FULL_VER})"
    fi
    LINUX_FULL_VER=$BUILT_KERNELRELEASE
  else
    LINUX_FULL_VER=$(kernel_release "$LINUX_FULL_VER")
    log_warning "Could not read the kernel release from the built package or the configured tree; using ${LINUX_FULL_VER}. The built packages may be named differently."
  fi
  log_info "Kernel release: ${LINUX_FULL_VER}"
  # Install
  # Install through the package manager so that runtime dependencies of the
  # kernel packages (kmod, linux-base, initramfs-tools, ...) are pulled in on
  # minimal systems, where a plain "dpkg -i" would fail.
  # Package names carry the kernel release as-is, but package versions are
  # rewritten for pre-releases: mkdebian turns -rcN into ~rcN (7.3.0~rc7-1)
  # and kernel.spec turns - into _ (kernel-7.3.0_rc7-1), so the globs below
  # match the name and the rpm version rather than the raw release string.
  if [[ $DISTRO_GROUP == "RHEL" ]]; then
    RPM_VER=${LINUX_FULL_VER//-/_}
    # binrpm-pkg writes kernel, kernel-devel and kernel-headers rpms to
    # <kernel tree>/rpmbuild/RPMS/<arch>/ (see scripts/package/kernel.spec)
    if ! compgen -G "./linux-${LINUX_VER}/rpmbuild/RPMS/*/kernel-${RPM_VER}-*.rpm" >/dev/null ||
      ! compgen -G "./linux-${LINUX_VER}/rpmbuild/RPMS/*/kernel-devel-${RPM_VER}-*.rpm" >/dev/null; then
      log_error "Kernel build did not produce packages for ${LINUX_VER}; aborting before installation. See ${RUN_LOG} for build errors."
      exit 1
    fi
    run_ok "${INSTALL} ./linux-\"${LINUX_VER}\"/rpmbuild/RPMS/*/kernel-\"${RPM_VER}\"-*.rpm ./linux-\"${LINUX_VER}\"/rpmbuild/RPMS/*/kernel-devel-\"${RPM_VER}\"-*.rpm" "Installing Kernel image and headers: ${LINUX_VER}"
  else
    if ! compgen -G "./linux-headers-${LINUX_FULL_VER}_*.deb" >/dev/null ||
      ! compgen -G "./linux-image-${LINUX_FULL_VER}_*.deb" >/dev/null; then
      log_error "Kernel build did not produce packages for ${LINUX_VER}; aborting before installation. See ${RUN_LOG} for build errors."
      exit 1
    fi
    run_ok "${INSTALL} ./linux-headers-\"${LINUX_FULL_VER}\"_*.deb ./linux-image-\"${LINUX_FULL_VER}\"_*.deb" "Installing Kernel image and headers: ${LINUX_VER}"
  fi
  log_success "Installation finished"
  check_dkms_release "$LINUX_FULL_VER"
  # else
  #   # Install
  #   run_ok "dpkg -i linux-image-\"${LINUX_VER}\"_\"${LINUX_VER}\"-*.deb" "Installing Kernel image: ${LINUX_VER}"
  #   run_ok "dpkg -i linux-headers-\"${LINUX_VER}\"_\"${LINUX_VER}\"-*.deb" "Installing Kernel headers: ${LINUX_VER}"
  #   log_success "Installation finished"
  # fi
  # if /usr/sbin/dkms; then
  #   run_ok "dkms autoinstall -k ${CURRENT_VER}" "triggering installation of modules for the currently loaded kernel: ${CURRENT_VER}"
  #   log_success "Module installation finished"
  # fi
  echo
  # Cleanup
  printf "%s \\n" "${GREEN}▣▣▣▣▣▣${NORMAL} Cleaning up"
  if [ -d "$INSTALL_DIR" ] && is_safe_install_dir "$INSTALL_DIR"; then
    log_debug "Cleaning up temporary files in $INSTALL_DIR."
    remove_install_dir "$INSTALL_DIR" ||
      log_error "Could not completely clean up $INSTALL_DIR."
  else
    log_error "Could not safely clean up temporary files because INSTALL DIR set to $INSTALL_DIR."
  fi

  # Make sure the cursor is back (if spinners misbehaved)
  if [ "$INTERACTIVE_MODE" = "on" ]; then
    tput cnorm
  fi
  printf "%s \\n" "${GREEN}▣▣▣▣▣▣${NORMAL} All ${GREEN}6${NORMAL} phases finished successfully"

  if [ "$KEXEC" = "1" ]; then
    kexec_new_kernel "$LINUX_FULL_VER"
  fi
}

# Start Script
# (the root check, chk_permissions, ran during argument parsing)
# Uninstall kernel
if [ "$mode" = "uninstall" ]; then
  take_lock
  if [ "$VER_SELECTED" != "1" ]; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} No kernel version selected for uninstall. Use ${CYAN}--kernel${NORMAL} to select one."
  fi
  chk_version
  # Packages are named after the kernel release (7.3-rc7 -> 7.3.0-rc7)
  uninstall_release=$(kernel_release "$LINUX_VER")
  uninstall_pkgs=()
  if [[ $DISTRO_GROUP == "RHEL" ]]; then
    uninstall_names="kernel kernel-devel"
  else
    uninstall_names="linux-headers linux-image"
  fi
  for name in $uninstall_names; do
    if pkg=$(installed_kernel_pkg "$name" "$uninstall_release"); then
      uninstall_pkgs+=("$pkg")
    fi
  done
  if [ ${#uninstall_pkgs[@]} -eq 0 ]; then
    # Nothing named exactly <release>: the installed kernel may have been built
    # with a CONFIG_LOCALVERSION suffix (6.12.113-test), which --uninstall
    # cannot see before any build (#49). Offer those packages instead of
    # failing, but only after the user confirms which ones to remove.
    uninstall_localversion=()
    for name in $uninstall_names; do
      while IFS= read -r pkg; do
        [ -n "$pkg" ] && uninstall_localversion+=("$pkg")
      done < <(installed_kernel_pkgs_localversion "$name" "$uninstall_release")
    done
    if [ ${#uninstall_localversion[@]} -gt 0 ]; then
      echo -e "${YELLOW}No packages named exactly ${uninstall_release}.${NORMAL}"
      echo -e "${YELLOW}Installed kernel packages that match it:${NORMAL}"
      printf '  %s\n' "${uninstall_localversion[@]}"
      ask YESNO -e -p "${YELLOW}Remove them?${NORMAL} [y/N]: "
      case ${YESNO,,} in
        y | yes) uninstall_pkgs=("${uninstall_localversion[@]}") ;;
        *)
          log_error "No installed kernel packages found for ${LINUX_VER} (release ${uninstall_release})."
          exit 1
          ;;
      esac
    else
      log_error "No installed kernel packages found for ${LINUX_VER} (release ${uninstall_release})."
      exit 1
    fi
  fi
  if [[ $DISTRO_GROUP == "RHEL" ]]; then
    ${UNINSTALL} "${uninstall_pkgs[@]}"
  else
    apt purge "${uninstall_pkgs[@]}"
  fi
  exit
fi

if [ $LIST_INSTALLED == "1" ]; then
  if [[ $DISTRO_GROUP == "RHEL" ]]; then
    rpm -qa | grep -E '^kernel(-devel|-headers|-core|-modules|-modules-extra)?-[0-9]' | sort
  else
    dpkg --list | grep -Ei 'linux-image|linux-headers|linux-modules' | awk '{ print $2 }'
  fi
  exit
fi

# Install Kernel
# Only an install starts a new log; --list-installed and --uninstall above
# leave the last one in place
take_lock
rotate_log
chk_version
chk_kernel
errors=$((0))
if ! install_kernel; then
  errorlist="${errorlist}  ${YELLOW}◉${NORMAL} Kernel installation returned an error.\\n"
  errors=$((errors + 1))
fi
if [ $errors -eq "0" ]; then
  read_sleep 5
  if [ "$BANNERS" = "1" ]; then
    exit_script
  fi
  read_sleep 5
  #indexit
else
  log_warning "The following errors occurred during installation:"
  echo
  printf "%s" "${errorlist}"
  if [ -d "$INSTALL_DIR" ] && is_safe_install_dir "$INSTALL_DIR"; then
    log_warning "Removing temporary directory and files."
    remove_install_dir "$INSTALL_DIR" ||
      log_warning "Could not completely remove $INSTALL_DIR."
  fi
fi

exit

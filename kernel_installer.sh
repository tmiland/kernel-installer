#!/usr/bin/env bash
# shellcheck disable=SC2221,SC2222,SC2181,SC2174,SC2086,SC2046,SC2005,SC2317

## Author: Tommy Miland (@tmiland) - Copyright (c) 2025


######################################################################
####                    Kernel Installer.sh                       ####
####               Automatic kernel install script                ####
####                   Maintained by @tmiland                     ####
######################################################################


VERSION='1.2.6'

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
# Original command-line arguments (diagnostics and the "run as root" hint)
SCRIPT_ARGS="$*"
# Logfile (the previous install's log is kept as $LOGFILE.1)
LOGFILE=${LOGFILE:-/var/log/kernel_installer.log}
# Default processing units (all available)
NPROC=${NPROC:-$(nproc)}
# Console output level; ignore debug level messages.
VERBOSE=${VERBOSE:-0}
# Disable debug info since it's enabled by default to speed up kernel compilation
ENABLE_DEBUG_INFO=${ENABLE_DEBUG_INFO:-0}
# Low latency (Default off)
LOWLATENCY=${LOWLATENCY:-0}
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
SLIB_REV="b3ba718"
SLIB_SHA256="b12a371e5449fc6659be56e6529dd3c580f0de6c453d0f53fd26a1f2dc28d800"
# Functions url
SLIB_URL=https://raw.githubusercontent.com/$REPO_NAME/$SLIB_REV/src/slib.sh
# Set default configuration target
CONFIG_OPTION=${CONFIG_OPTION:-olddefconfig}

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
    rm -rf "$INSTALL_DIR"
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
  log_debug "Diagnostics: target: ${LINUX_VER_NAME} ${LINUX_VER}, config: ${CONFIG_OPTION}, custom directives: ${#CUSTOM_CONFIG_OPTIONS[@]}, verified tarball: ${GET_VERIFIED_TARBALL}, jobs: ${NPROC}"
  log_debug "Diagnostics: running kernel's config (base for olddefconfig/oldconfig): $(ls /boot/config-"$(uname -r)" 2>/dev/null || echo "none, so arch defconfig is the base")"
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

# Start an install with an empty log and keep the previous one as
# $LOGFILE.1, so a failed build's log survives the next run (#53).
rotate_log() {
  if [ -f "$LOGFILE" ]; then
    mv -f "$LOGFILE" "$LOGFILE.1"
  fi
}

# A directory is safe to reuse (and wipe) when it does not exist yet, is
# empty, or was created by this installer in a previous run (marker present).
is_safe_install_dir() {
  local dir="$1"
  if [ -z "$dir" ] || [ "$dir" = "/" ] || [ ! -d "$dir" ]; then
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

chk_kernel() {
  # Check if kernel is installed, abort if same version is found
  local release image_pkg
  release=$(kernel_release "$LINUX_VER")
  if [[ $DISTRO_GROUP == "RHEL" ]]; then
    image_pkg=kernel
  else
    image_pkg=linux-image
  fi
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

# Make sure a valid kernel version was determined before doing anything destructive
chk_version() {
  if [[ ! $LINUX_VER =~ ^[0-9]+\.[0-9]+ ]]; then
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

# Update script
# Default: Do not check for update
update_updater () {
  # Download a file, printing the temp path (empty on failure)
  download_file () {
    local url=$1 tf
    tf=$(mktemp)
    if command -v curl >/dev/null 2>&1; then
      curl -sSLf -o "$tf" "${url}" && echo "$tf" || echo ''
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$tf" "${url}" && echo "$tf" || echo ''
    else
      echo ''
    fi
  }
  # Fetch the latest release info once, then parse the fields we need
  local release_json release_file
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

  # Latest release download url
  LATEST_RELEASE=$(printf '%s\n' "$release_json" |
    grep '"browser_download_url":' |
    sed -n 's#.*\(https*://[^"]*\).*#\1#;p')

  # Latest release notes
  RELEASE_NOTE=$(printf '%s\n' "$release_json" |
    grep '"body":' |
    sed -n 's/.*"\([^"]*\)".*/\1/;p')

  # Latest release title
  RELEASE_TITLE=$(printf '%s\n' "$release_json" |
    grep -m 1 '"name":' |
    sed -n 's/.*"\([^"]*\)".*/\1/;p')

  echo -e "${GREEN}${ARROW} Checking for updates...${NORMAL}"
  local tmpfile current_version
  tmpfile=$(download_file "$LATEST_RELEASE")
  current_version=$(get_updater_version "$self")

  # Only proceed when RELEASE_TAG is a strictly newer version
  if [ -n "$RELEASE_TAG" ] && [ "$current_version" != "$RELEASE_TAG" ] &&
    [ "$(printf '%s\n%s\n' "$current_version" "$RELEASE_TAG" | sort -V | tail -n1)" = "$RELEASE_TAG" ]; then
    if [ $UPDATE_SCRIPT = "1" ]; then
      show_update_banner
      echo -e "${RED}${ARROW} Do you want to update [Y/N?]${NORMAL}"
      ask REPLY -n 1
      echo -e "\n\n"
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -z "$tmpfile" ]; then
          log_error "Failed to download the new version. Aborting update."
          return 1
        fi
        if ! mv "$tmpfile" "${SCRIPT_DIR}/${SCRIPT_FILENAME}"; then
          log_error "Failed to install the new version. Aborting update."
          rm -f "$tmpfile"
          return 1
        fi
        chmod u+x "${SCRIPT_DIR}/${SCRIPT_FILENAME}"
        echo -e "${GREEN}${DONE} Updated to version ${RELEASE_TAG}, restarting...${NORMAL}"

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
          BANNERS="$BANNERS" \
          LIST_INSTALLED="$LIST_INSTALLED" \
          "${SCRIPT_DIR}/${SCRIPT_FILENAME}" "${reexec_args[@]}"
      fi
      rm -f "$tmpfile"
      return 1 # Update available, but not applied
    fi
  else
    rm -f "$tmpfile"
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
      if [[ ! $2 =~ ^[0-9] ]]; then
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

shopt -s nocasematch
if [[ -f /etc/debian_version ]]; then
  DISTRO=$(cat /etc/issue.net)
elif [[ -f /etc/redhat-release ]]; then
  DISTRO=$(cat /etc/redhat-release)
elif [[ -f /etc/os-release ]]; then
  DISTRO=$(cat < /etc/os-release | grep "PRETTY_NAME" | sed 's/PRETTY_NAME=//g' | sed 's/["]//g' | awk '{print $1}')
fi

case "$DISTRO" in
  # Linux Mint's /etc/issue.net reads "Linux Mint 22.3 Zena" (with a space)
  # and LMDE's reads "LMDE 7 Gigi"
  Debian*|Ubuntu*|LinuxMint*|"Linux Mint"*|LMDE*|PureOS*|Pop*|Devuan*)
    # shellcheck disable=SC2140
    PKGCMD="apt-get -o Dpkg::Progress-Fancy="1" install -qq"
    LSB=lsb-release
    DISTRO_GROUP=Debian
    ;;
  CentOS*|Rocky*|AlmaLinux*|Fedora*|Red*)
    # Fedora and the RHEL family (RHEL, Rocky, AlmaLinux, CentOS Stream)
    PKGCMD="dnf install -y"
    LSB=redhat-lsb-core
    DISTRO_GROUP=RHEL
    ;;
  Arch*|Manjaro*)
    PKGCMD="yes | LC_ALL=en_US.UTF-8 pacman -S"
    LSB=lsb-release
    DISTRO_GROUP=Arch
    echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}" ; exit 1
    ;;
  *) echo -e "${RED}${BALLOT_X} unknown distro: '$DISTRO'${NORMAL}" ; exit 1 ;;
esac
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
  INSTALL_PKGS="wget curl git rsync fakeroot cpio kmod build-essential libncurses-dev xz-utils libssl-dev bc lz4 libelf-dev flex bison gawk debhelper dpkg-dev procps apt-transport-https libdw-dev python3"
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
    INSTALL_PKGS="wget curl git rsync ca-certificates procps-ng findutils diffutils hostname bc binutils bison dwarves elfutils-devel elfutils-libelf-devel flex gawk gcc make openssl openssl-devel perl python3 ncurses-devel cpio kmod xz lz4 rpm-build dracut grubby"
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
# shellcheck disable=SC2329  # only called from get_verified_tarball (see there)
verify_fail() {
  VERIFY_ERROR=$1
  if [ -n "${verify_dir:-}" ]; then
    rm -rf "$verify_dir"
  fi
}

# shellcheck disable=SC2329  # called by name through run_ok
get_verified_tarball() {
  # Keep the verify directory out of the environment: this function must not
  # clobber an exported TMPDIR, whose value later build steps rely on (#48).
  local TMPDIR
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

  # If you set this to empty value (e.g. GNUPGHOME= ./kernel_installer.sh),
  # we'll make a temporary directory and fetch the verification keys from the
  # Web Key Directory each time. Also, see the USEKEYRING=
  # configuration option for an alternative that doesn't
  # rely on WKD.
  GNUPGHOME=${GNUPGHOME-"$HOME/.gnupg"}

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
  # Do we already have this file?
  if [[ -f ${TARGET} ]]; then
    log_debug "File ${TARGETDIR}/linux-${LINUX_VER}.tar.xz already exists."
    echo "Skipping download..."
    return 0
  fi

  # Start by making sure our GnuPG environment is sane
  if [[ ! -x ${GPGBIN} || ! -x ${GPGVBIN} ]]; then
    echo "Could not find gpg or gpgv, installing gnupg"
    log_debug "Installing gnupg"
    ${INSTALL} gnupg
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
  # Are we using a keyring?
  if [[ -z ${USEKEYRING} ]]; then
    if [[ -z ${GNUPGHOME} ]]; then
      GNUPGHOME="${TMPDIR}/gnupg"
      # elif [[ ! -d ${GNUPGHOME} ]]; then
      #   echo "GNUPGHOME directory ${GNUPGHOME} does not exist"
      #   echo -n "Create it? [Y/n]"
      #   read -r YN
      #   if [[ ${YN} == 'n' ]]; then
      #     echo "Exiting"
      #     rm -rf "${TMPDIR}"
      #     exit 1
      #   fi
    fi
    mkdir -p -m 0700 "${GNUPGHOME}"
    log_debug "Making sure we have all the necessary keys"
    ${GPGBIN} --batch --quiet \
      --homedir "${GNUPGHOME}" \
      --auto-key-locate wkd \
      --locate-keys ${DEVKEYS} ${SHAKEYS}
    # If this returned non-0, we bail
    if [[ $? != "0" ]]; then
      verify_fail "Could not fetch the kernel.org signing keys (gpg --locate-keys via WKD failed)"
      return 1
    fi
    # Make a temporary keyring and set USEKEYRING to it
    USEKEYRING=${TMPDIR}/keyring.gpg
    ${GPGBIN} --batch --export ${DEVKEYS} ${SHAKEYS} > ${USEKEYRING}
  fi
  # Now we make two keyrings -- one for the autosigner, and
  # the other for kernel developers. We do this in order to
  # make sure that we never verify kernel tarballs using the
  # autosigner keys, only using developer keys.
  SHAKEYRING=${TMPDIR}/shakeyring.gpg
  ${GPGBIN} --batch \
    --no-default-keyring --keyring ${USEKEYRING} \
    --export ${SHAKEYS} > ${SHAKEYRING}
  DEVKEYRING=${TMPDIR}/devkeyring.gpg
  ${GPGBIN} --batch \
    --no-default-keyring --keyring ${USEKEYRING} \
    --export ${DEVKEYS} > ${DEVKEYRING}

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
  COUNT=$(${GPGVBIN} --keyring=${SHAKEYRING} --status-fd=1 ${SHAFILE} \
    | grep -c -E '^\[GNUPG:\] (GOODSIG|VALIDSIG)')
  if [[ ${COUNT} -lt 2 ]]; then
    verify_fail "FAILED to verify the sha256sums.asc file."
    return 1
  fi
  # Grab only the tarball we want from the full list
  SHACHECK=${TMPDIR}/sha256sums.txt
  grep "linux-${LINUX_VER}.tar.xz" ${SHAFILE} > ${SHACHECK}

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
  if [ ! -d "$INSTALL_DIR" ]; then
    if ! mkdir -p "$INSTALL_DIR" 1>/dev/null 2>&1; then
      fatal "Could not create install directory $INSTALL_DIR"
    fi
  fi
  if [ -d "$INSTALL_DIR" ]; then
    if ! is_safe_install_dir "$INSTALL_DIR"; then
      fatal "Install directory $INSTALL_DIR is not empty and does not look like it was created by this script. Refusing to delete its contents; use an empty directory or clean it up yourself."
    fi
    #(
    #cd "$INSTALL_DIR"/linux || exit
    log_debug "Deleting old Linux source code files in $INSTALL_DIR"
    rm -rf "$INSTALL_DIR" && mkdir -p "$INSTALL_DIR"
    touch "$INSTALL_DIR/$INSTALL_DIR_MARKER"
    cd "$INSTALL_DIR" || exit 1
    log_debug "Downloading Linux source code"
    if [ "$LINUX_VER_NAME" != "Mainline" ] && [ "$GET_VERIFIED_TARBALL" = "1" ]; then
      # get-verified-tarball function; handle a failure here (not in run_ok)
      # so the reason is shown on screen
      if ! RUN_ERRORS_FATAL='' run_ok "get_verified_tarball" "Downloading and Verifying source code tarball..."; then
        fatal "Failed to download and verify the kernel tarball: ${VERIFY_ERROR:-see the log for details}"
      fi
      log_success "Downloaded and verified ${TARGET}"
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
      # cp /boot/config-"$(uname -r)" .config
      log_debug "Configuring..."
      if [ "$CONFIG_INTERACTIVE" = "1" ]; then
        log_info "Running make $CONFIG_OPTION; save the configuration and exit to continue."
        if ! make "$CONFIG_OPTION" </dev/tty >/dev/tty 2>&1; then
          fatal "make $CONFIG_OPTION failed"
        fi
      else
        run_ok "make $CONFIG_OPTION" "Writing configuration..."
      fi
      log_success "Configuration finished"
      read_sleep 1
      # Disable debug info since it's enabled by default
      if [ "$ENABLE_DEBUG_INFO" = "0" ]; then
        disable_debug_info "$LINUX_VER"
      fi
      if [ "$LOWLATENCY" = "1" ]; then
        # convert generic config to lowlatency
        scripts/config --disable COMEDI_TESTS_EXAMPLE
        scripts/config --disable COMEDI_TESTS_NI_ROUTES
        scripts/config --set-val CONFIG_HZ 1000
        scripts/config --enable HZ_1000
        scripts/config --disable HZ_250

        scripts/config --enable LATENCYTOP
        scripts/config --enable PREEMPT
        scripts/config --disable PREEMPT_VOLUNTARY
        scripts/config --set-val TEST_DIV64 m
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
      for custom_config_option in "${CUSTOM_CONFIG_OPTIONS[@]}"; do
        log_debug "Adding custom config option: \"$custom_config_option\""
        eval "$custom_config_option"
      done
      # After --custom-config, so a certificate the user provides is kept
      clear_missing_cert_keys
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
      if ! RUN_ERRORS_FATAL='' run_ok "echo $DEF_COM_NUM | make $build_target -j${NPROC}" "Compiling The Linux Kernel source code..."; then
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

  get_linux_full_ver() {
    # shellcheck disable=SC2046
    echo $(
      sed -n '2 s/.*VERSION *= *\([^ ]*.*\)/\1/p' "$1"
      sed -n '3 s/.*PATCHLEVEL *= *\([^ ]*.*\)/\1/p' "$1"
      sed -n '4 s/.*SUBLEVEL *= *\([^ ]*.*\)/\1/p' "$1"
      sed -n '5 s/.*EXTRAVERSION *= *\([^ ]*.*\)/\1/p' "$1"
    )
  }
  # Grab version numbers from Makefile > Output to final version file
  get_linux_full_ver "$LINUX_VER_FILE" > "$LINUX_VER_FINAL_FILE"
  # Strip spaces on the first two and add a . then just stript the last space
  sed -i 's/  */./;s/  */./;s/ //g' "$LINUX_VER_FINAL_FILE"
  # Final version should look like 5.18.0-rc7
  LINUX_FULL_VER=$(cat "$LINUX_VER_FINAL_FILE")
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
    run_ok "${INSTALL} ./linux-headers-\"${LINUX_FULL_VER}\"_*.deb" "Installing Kernel headers: ${LINUX_VER}"
    run_ok "${INSTALL} ./linux-image-\"${LINUX_FULL_VER}\"_*.deb" "Installing Kernel image: ${LINUX_VER}"
  fi
  log_success "Installation finished"
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
    find "$INSTALL_DIR" -mindepth 1 -delete
    rmdir "$INSTALL_DIR" 2>/dev/null || true
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
    log_error "No installed kernel packages found for ${LINUX_VER} (release ${uninstall_release})."
    exit 1
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
    rm -rf "$INSTALL_DIR"
  fi
fi

exit

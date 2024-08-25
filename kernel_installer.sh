#!/usr/bin/env bash
# shellcheck disable=SC2221,SC2222,SC2181,SC2174,SC2086,SC2046,SC2005

## Author: Tommy Miland (@tmiland) - Copyright (c) 2022


######################################################################
####                    Kernel Installer.sh                       ####
####               Automatic kernel install script                ####
####                   Maintained by @tmiland                     ####
######################################################################


VERSION='1.2.3'

#------------------------------------------------------------------------------#
#
# MIT License
#
# Copyright (c) 2022 Tommy Miland
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
# Get current directory
CURRDIR=$(pwd)
# Set update check
UPDATE_SCRIPT=0
# Get script filename
self=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_FILENAME=$(basename "$self")
# Logfile
LOGFILE=$CURRDIR/kernel_installer.log
# Default processing units (all available)
NPROC=$(nproc)
# Console output level; ignore debug level messages.
VERBOSE=0
# Disable debug info since it's enabled by default to speed up kernel compilation
ENABLE_DEBUG_INFO=0
# Low latency (Default off)
LOWLATENCY=0
# get-verified-tarball (Default: no)
GET_VERIFIED_TARBALL=${GET_VERIFIED_TARBALL:-0}
# Show banners (Default: yes)
BANNERS=1
# Default Install dir (Default: /opt/linux)
INSTALL_DIR=${INSTALL_DIR:-/opt/linux}
# https://stackoverflow.com/a/51068988
latest_kernel() {
  curl -s https://www.kernel.org/finger_banner | grep -m1 "$1" | sed -r 's/^.+: +([^ ]+)( .+)?$/\1/'
}
# Default Kernel version
STABLE_VER=$(latest_kernel stable)
# Mainline kernel version
MAINLINE_VER=$(latest_kernel mainline)
# Lonterm kernel version
LONGTERM_VER=$(latest_kernel longterm)
# Default kernel version without arguments
LINUX_VER=${LINUX_VER:-$STABLE_VER}
# Default linux version name
LINUX_VER_NAME=Stable
# Installed kernel
CURRENT_VER=$(uname -r)
# Default kexec option
KEXEC=${KEXEC:-0}
# root
root=$(id | grep -i "uid=0(" >/dev/null)
# Repo name for this script
REPO_NAME="tmiland/kernel-installer"
# Functions url
SLIB_URL=https://raw.githubusercontent.com/$REPO_NAME/main/src/slib.sh
# Set default configuration target
CONFIG_OPTION=${CONFIG_OPTION:-olddefconfig}

# Include functions
if [[ -f $CURRDIR/src/slib.sh ]]; then
  # shellcheck disable=SC1091
  . ./src/slib.sh
else
  if [[ $(command -v 'curl') ]]; then
    # shellcheck source=/dev/null
    source <(curl -sSLf $SLIB_URL)
  elif [[ $(command -v 'wget') ]]; then
    # shellcheck source=/dev/null
    . <(wget -qO - $SLIB_URL)
  else
    echo -e "${RED}${BALLOT_X} This script requires curl or wget.\nProcess aborted${NORMAL}"
    exit 0
  fi
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
  if [ -x "$INSTALL_DIR" ]; then
    log_warning "Removing temporary directory and files."
    rm -rf "$INSTALL_DIR"
  fi
  log_fatal "If you are unsure of what went wrong, you may wish to review the log"
  log_fatal "in $LOGFILE"
  exit 1
}

success() {
  log_success "$1 Succeeded."
}

read_sleep() {
  read -rt "$1" <> <(:) || :
}

# Make sure that the script runs with root permissions
chk_permissions() {
  # Only root can run this
  if [ "$root" = "0" ]; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} The ${SCRIPT_NAME} script must be run as root"
  fi
}

chk_kernel() {
  # Check if kernel is installed, abort if same version is found
  if [ "$CURRENT_VER" = "${LINUX_VER}" ]; then
    fatal "${RED}${BALLOT_X} Kernel ${LINUX_VER} is already installed. Process aborted${NORMAL}"
  fi
}

versionToInt() {
  echo "$@" | awk -F "." '{ printf("%03d%03d%03d", $1,$2,$3); }';
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
header() {
  echo -e "${GREEN}\n"
  echo ' ╔═══════════════════════════════════════════════════════════════════╗'
  echo ' ║                        '"${SCRIPT_NAME}"'                        ║'
  echo ' ║                  Automatic kernel install script                  ║'
  echo ' ║                      Maintained by @tmiland                       ║'
  echo ' ║                          version: '${VERSION}'                           ║'
  echo ' ╚═══════════════════════════════════════════════════════════════════╝'
  echo -e "${NORMAL}"
}

# Update banner
show_update_banner () {
  header
  echo ""
  echo "There is a newer version of ${SCRIPT_NAME} available."
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
# Returns the version number of ${SCRIPT_NAME} file on line 14
##
get_updater_version () {
  echo $(sed -n '14 s/[^0-9.]*\([0-9.]*\).*/\1/p' "$1")
}

# Update script
# Default: Do not check for update
update_updater () {
  # Download files
  download_file () {
    declare -r url=$1
    declare -r tf=$(mktemp)
    local dlcmd=''
    dlcmd="wget -O $tf"
    $dlcmd "${url}" &>/dev/null && echo "$tf" || echo '' # return the temp-filename (or empty string on error)
  }
  # Open files
  open_file () { #expects one argument: file_path

    if [ "$(uname)" == 'Darwin' ]; then
      open "$1"
    elif [ "$(cut $(uname -s) 1 5)" == "Linux" ]; then
      xdg-open "$1"
    else
      echo -e "${RED}${ERROR} Error: Sorry, opening files is not supported for your OS.${NC}"
    fi
  }
  # Get latest release tag from GitHub
  get_latest_release_tag() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"tag_name":' |
    sed -n 's/[^0-9.]*\([0-9.]*\).*/\1/p'
  }

  RELEASE_TAG=$(get_latest_release_tag ${REPO_NAME})

  # Get latest release download url
  get_latest_release() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"browser_download_url":' |
    sed -n 's#.*\(https*://[^"]*\).*#\1#;p'
  }

  LATEST_RELEASE=$(get_latest_release ${REPO_NAME})

  # Get latest release notes
  get_latest_release_note() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"body":' |
    sed -n 's/.*"\([^"]*\)".*/\1/;p'
  }

  RELEASE_NOTE=$(get_latest_release_note ${REPO_NAME})

  # Get latest release title
  get_latest_release_title() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep -m 1 '"name":' |
    sed -n 's/.*"\([^"]*\)".*/\1/;p'
  }

  RELEASE_TITLE=$(get_latest_release_title ${REPO_NAME})

  echo -e "${GREEN}${ARROW} Checking for updates...${NORMAL}"
  # Get tmpfile from github
  declare -r tmpfile=$(download_file "$LATEST_RELEASE")
  if [[ $(get_updater_version "${CURRDIR}/$SCRIPT_FILENAME") < "${RELEASE_TAG}" ]]; then
    if [ $UPDATE_SCRIPT = "1" ]; then
      show_update_banner
      echo -e "${RED}${ARROW} Do you want to update [Y/N?]${NORMAL}"
      read -p "" -n 1 -r
      echo -e "\n\n"
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        mv "${tmpfile}" "${CURRDIR}/${SCRIPT_FILENAME}"
        chmod u+x "${CURRDIR}/${SCRIPT_FILENAME}"
        "${CURRDIR}/${SCRIPT_FILENAME}" "$@" -d
        exit 1 # Update available, user chooses to update
      fi
      if [[ $REPLY =~ ^[Nn]$ ]]; then
        return 1 # Update available, but user chooses not to update
      fi
    fi
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
  printf "%s\\n" "  ${YELLOW}--verbose              |-v${NORMAL}   increase verbosity"
  printf "%s\\n" "  ${YELLOW}--get-verified-tarball |-gvt${NORMAL} cryptographically verify kernel tarball"
  printf "%s\\n" "  ${YELLOW}--nproc                |-n${NORMAL}   set the number of processing units to use"
  printf "%s\\n" "  ${YELLOW}--enable-debug-info    |-edi${NORMAL} enable debug info"
  printf "%s\\n" "  ${YELLOW}--lowlatency           |-low${NORMAL} convert generic config to lowlatency"
  printf "%s\\n" "  ${YELLOW}--changelog            |-cl${NORMAL}  view changelog for kernel version"
  printf "%s\\n" "  ${YELLOW}--update               |-upd${NORMAL} check for script update"
  printf "%s\\n" "  ${YELLOW}--uninstall            |-u${NORMAL}   uninstall kernel"
  echo
  printf "%s\\n" "  Installed kernel version: ${YELLOW}${CURRENT_VER}${NORMAL}  | Script version: ${CYAN}${VERSION}${NORMAL}"
  echo
}

POSITIONAL_ARGS=()

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
      ;;
    --mainline | -m)
      shift
      LINUX_VER=$MAINLINE_VER
      LINUX_VER_NAME=Mainline
      ;;
    --longterm | -l)
      shift
      LINUX_VER=$LONGTERM_VER
      LINUX_VER_NAME=Longterm
      ;;
    --kernel | -k)
      LINUX_VER="$2"
      LINUX_VER_NAME=Custom
      shift
      shift
      ;;
    --dir | -d) # Bash Space-Separated (e.g., --option argument)
      INSTALL_DIR="$2" # Source: https://stackoverflow.com/a/14203146
      shift # past argument
      shift # past value
      ;;
    --config | -c)
      CONFIG_OPTION="$2"
      shift
      shift
      ;;
    --kexec | -x)
      shift
      KEXEC=1
      ;;
    --nproc | -n)
      NPROC=$2
      shift
      shift
      ;;
    --enable-debug-info | -edi)
      shift
      ENABLE_DEBUG_INFO=1
      ;;
    --lowlatency | -low)
      shift
      LOWLATENCY=1
      ;;
    --changelog | -cl)
      changelog
      exit 0
      ;;
    --update | -upd)
      UPDATE_SCRIPT=1
      update_updater "$@"
      exit 0
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

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

chk_kernel

# Start with a clean log
if [[ -f $LOGFILE ]]; then
  rm "$LOGFILE"
fi

shopt -s nocasematch
if [[ -f /etc/debian_version ]]; then
  DISTRO=$(cat /etc/issue.net)
elif [[ -f /etc/redhat-release ]]; then
  DISTRO=$(cat /etc/redhat-release)
elif [[ -f /etc/os-release ]]; then
  DISTRO=$(cat < /etc/os-release | grep "PRETTY_NAME" | sed 's/PRETTY_NAME=//g' | sed 's/["]//g' | awk '{print $1}')
fi

case "$DISTRO" in
  Debian*|Ubuntu*|LinuxMint*|PureOS*|Pop*|Devuan*)
    # shellcheck disable=SC2140
    PKGCMD="apt-get -o Dpkg::Progress-Fancy="1" install -qq"
    LSB=lsb-release
    DISTRO_GROUP=Debian
    ;;
  CentOS*)
    PKGCMD="yum install -y"
    LSB=redhat-lsb
    DISTRO_GROUP=RHEL
    echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}" ; exit 1
    ;;
  Fedora*)
    PKGCMD="dnf install -y"
    LSB=redhat-lsb
    DISTRO_GROUP=RHEL
    echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}" ; exit 1
    ;;
  Arch*|Manjaro*)
    PKGCMD="yes | LC_ALL=en_US.UTF-8 pacman -S"
    LSB=lsb-release
    DISTRO_GROUP=Arch
    echo -e "${RED}${BALLOT_X} distro not yet supported: '$DISTRO'${NORMAL}" ; exit 1
    ;;
  *) echo -e "${RED}${BALLOT_X} unknown distro: '$DISTRO'${NORMAL}" ; exit 1 ;;
esac
if ! lsb_release -si 1>/dev/null 2>&1; then
  echo ""
  echo -e "${RED}${BALLOT_X} Looks like ${LSB} is not installed!${NORMAL}"
  echo ""
  read -r -p "Do you want to download ${LSB}? [y/n]? " ANSWER
  echo ""
  case $ANSWER in
    [Yy]* )
      echo -e "${GREEN}${ARROW} Installing ${LSB} on ${DISTRO}...${NORMAL}"
      su -s "$(which bash)" -c "${PKGCMD} ${LSB}" || echo -e "${RED}${BALLOT_X} Error: could not install ${LSB}!${NORMAL}"
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
# UNINSTALL=""
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
  INSTALL="apt-get -o Dpkg::Progress-Fancy="1" install -qq"
  # # shellcheck disable=SC2140
  # UNINSTALL="apt-get -o Dpkg::Progress-Fancy="1" remove -qq"
  # # shellcheck disable=SC2140
  # PURGE="apt-get purge -o Dpkg::Progress-Fancy="1" -qq"
  # CLEAN="apt-get clean && apt-get autoremove -qq"
  PKGCHK="dpkg -s"
  #BUILD_DEP="apt-get -o Dpkg::Progress-Fancy="1" build-dep -qq"
  # Install packages
  INSTALL_PKGS="wget curl git rsync fakeroot build-essential ncurses-dev xz-utils libssl-dev bc liblz4-tool paxctl libelf-dev flex bison debhelper apt-transport-https"
  #INSTALL_PKGS="build-essential fakeroot rsync git wget curl"
  # Build Dependencies
  #BUILD_DEP_PKGS="linux"
  # elif [[ $(lsb_release -si) == "CentOS" ]]; then
  #   SUDO="sudo"
  #   UPDATE="yum update -q"
  #   # UPGRADE="yum upgrade -q"
  #   INSTALL="yum install -y -q"
  #   UNINSTALL="yum remove -y -q"
  #   PURGE="yum purge -y -q"
  #   CLEAN="yum clean all -y -q"
  #   PKGCHK="rpm --quiet --query"
  #   # Install packages
  #   INSTALL_PKGS=""
  # elif [[ $(lsb_release -si) == "Fedora" ]]; then
  #   SUDO="sudo"
  #   UPDATE="dnf update -q"
  #   # UPGRADE="dnf upgrade -q"
  #   INSTALL="dnf install -y -q"
  #   UNINSTALL="dnf remove -y -q"
  #   PURGE="dnf purge -y -q"
  #   CLEAN="dnf clean all -y -q"
  #   PKGCHK="rpm --quiet --query"
  #   # Install packages
  #   INSTALL_PKGS=""
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

get_verified_tarball() {
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

  # If you set this to empty value, we'll make a temporary
  # directory and fetch the verification keys from the
  # Web Key Directory each time. Also, see the USEKEYRING=
  # configuration option for an alternative that doesn't
  # rely on WKD.
  GNUPGHOME="$HOME/.gnupg"

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
  GPGBIN="/usr/bin/gpg2"
  GPGVBIN="/usr/bin/gpgv2"
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

  MAJOR="$(echo "${LINUX_VER}" | cut -d. -f1)"
  if [[ ${MAJOR} -lt 3 ]]; then
    echo "This script only supports kernel v3.x.x and above"
    exit 1
  fi

  if [[ ! -d ${TARGETDIR} ]]; then
    echo "${TARGETDIR} does not exist"
    exit 1
  fi

  TARGET="${TARGETDIR}/linux-${LINUX_VER}.tar.xz"
  # Do we already have this file?
  if [[ -f ${TARGET} ]]; then
    log_debug "File ${TARGETDIR}/linux-${LINUX_VER}.tar.xz already exists."
    echo "Skipping download..."
  fi

  # Start by making sure our GnuPG environment is sane
  if [[ ! -x ${GPGBIN} ]]; then
    echo "Could not find gpg in ${GPGBIN}"
    log_debug "Installing gnupg2"
    ${INSTALL} gnupg2
    echo "done"
    #exit 1
  fi
  if [[ ! -x ${GPGVBIN} ]]; then
    echo "Could not find gpgv in ${GPGVBIN}"
    log_debug "Installing gpgv2"
    ${INSTALL} gpgv2
    echo "done"
    #exit 1
  fi

  # Let's make a safe temporary directory for intermediates
  TMPDIR=$(mktemp -d "${TARGETDIR}"/linux-tarball-verify.XXXXXXXXX.untrusted)
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
    mkdir -p -m 0700 ${GNUPGHOME}
    log_debug "Making sure we have all the necessary keys"
    ${GPGBIN} --batch --quiet \
      --homedir ${GNUPGHOME} \
      --auto-key-locate wkd \
      --locate-keys ${DEVKEYS} ${SHAKEYS}
    # If this returned non-0, we bail
    if [[ $? != "0" ]]; then
      echo "Something went wrong fetching keys"
      rm -rf ${TMPDIR}
      exit 1
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
    fatal "Failed to download the checksums file"
    rm -rf ${TMPDIR}
    exit 1
  fi
  log_debug "Verifying the checksums file"
  COUNT=$(${GPGVBIN} --keyring=${SHAKEYRING} --status-fd=1 ${SHAFILE} \
    | grep -c -E '^\[GNUPG:\] (GOODSIG|VALIDSIG)')
  if [[ ${COUNT} -lt 2 ]]; then
    fatal "FAILED to verify the sha256sums.asc file."
    rm -rf ${TMPDIR}
    exit 1
  fi
  # Grab only the tarball we want from the full list
  SHACHECK=${TMPDIR}/sha256sums.txt
  grep "linux-${LINUX_VER}.tar.xz" ${SHAFILE} > ${SHACHECK}

  echo
  log_debug "Downloading the signature file for linux-${LINUX_VER}"
  SIGFILE=${TMPDIR}/linux-${LINUX_VER}.tar.asc
  if ! ${CURLBIN} -sL -o ${SIGFILE} ${SIG}; then
    fatal "Failed to download the signature file"
    rm -rf ${TMPDIR}
    exit 1
  fi
  log_debug "Downloading the XZ tarball for linux-${LINUX_VER}"
  TXZFILE=${TMPDIR}/linux-${LINUX_VER}.tar.xz
  if ! ${CURLBIN} -L -o ${TXZFILE} ${TXZ}; then
    fatal "Failed to download the tarball"
    rm -rf ${TMPDIR}
    exit 1
  fi

  pushd ${TMPDIR} >/dev/null || exit
  log_debug "Verifying checksum on linux-${LINUX_VER}.tar.xz"
  if ! ${SHA256SUMBIN} -c ${SHACHECK}; then
    fatal "FAILED to verify the downloaded tarball checksum"
    popd >/dev/null || exit
    rm -rf ${TMPDIR}
    exit 1
  fi
  popd >/dev/null || exit

  echo
  log_debug "Verifying developer signature on the tarball"
  COUNT=$(${XZBIN} -cd "${TXZFILE}" \
      | ${GPGVBIN} --keyring="${DEVKEYRING}" --status-fd=1 "${SIGFILE}" - \
    | grep -c -E '^\[GNUPG:\] (GOODSIG|VALIDSIG)')
  if [[ ${COUNT} -lt 2 ]]; then
    fatal "FAILED to verify the tarball!"
    rm -rf ${TMPDIR}
    exit 1
  fi
  mv -f "${TXZFILE}" "${TARGET}"
  rm -rf ${TMPDIR}
  echo
  log_success "Successfully downloaded and verified ${TARGET}"
}

install_kernel() {
  clear
  header_logo
  log_info "Started installation log in $LOGFILE"
  echo
  log_info "${CYANBG}Installing The Linux Kernel version:${NORMAL} $LINUX_VER_NAME: ${YELLOW}$LINUX_VER${NORMAL}"
  echo
  printf "%s \\n" "${YELLOW}▣${CYAN}□□□□□${NORMAL} Phase ${YELLOW}1${NORMAL} of ${GREEN}6${NORMAL}: Setup packages"
  # Setup Dependencies
  log_debug "Configuring package manager for ${DISTRO_GROUP} .."
  if ! ${PKGCHK} $INSTALL_PKGS 1>/dev/null 2>&1; then
    log_debug "Updating packages"
    run_ok "${UPDATE}" "Updating package repo..."
    for i in $INSTALL_PKGS; do
      log_debug "Installing required packages $i"
      # shellcheck disable=SC2086
      ${INSTALL} ${i} >>"${RUN_LOG}" 2>&1
    done
  fi
  # log_debug "Install build dependencies required by the kernel build process"
  # run_ok "${BUILD_DEP} ${BUILD_DEP_PKGS}" "Installing build dependencies"
  log_success "Package Setup Finished"

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
  log_debug "Phase 2 of 5: Linux source code download"
  printf "%s \\n" "${GREEN}▣${YELLOW}▣${CYAN}□□□□${NORMAL} Phase ${YELLOW}2${NORMAL} of ${GREEN}6${NORMAL}: Download Linux source code"
  if [ ! -d "$INSTALL_DIR" ]; then
    mkdir "$INSTALL_DIR" 1>/dev/null 2>&1
  fi
  if [ -d "$INSTALL_DIR" ]; then
    #(
    #cd "$INSTALL_DIR"/linux || exit
    log_debug "Deleting old Linux source code files in $INSTALL_DIR"
    rm -rf "$INSTALL_DIR" && mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1
    log_debug "Downloading Linux source code"
    if [ ! $LINUX_VER_NAME = "Mainline" ]; then
      if [ ! "$GET_VERIFIED_TARBALL" = "1" ]; then
        # Kernel url 1 (Stable/longterm)
        kernel_url=https://cdn.kernel.org/pub/linux/kernel/v"$(echo "$LINUX_VER" | cut -c1)".x/linux-"${LINUX_VER}".tar.xz
        file_ext=xz
      else
        # get-verified-tarball function
        run_ok "get_verified_tarball" "Downloading and Verifying source code tarball..."
        log_success "Downloaded and verified ${TARGET}"
        file_ext=xz
      fi
    else
      # Kernel url 2 (Mainline)
      kernel_url=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/linux-"${LINUX_VER}".tar.gz
      file_ext=gz
    fi
    if [ ! "$GET_VERIFIED_TARBALL" = "1" ]; then
      if [ ! -f linux-"${LINUX_VER}".tar.$file_ext ]; then
        log_debug "Downloading Linux source code"
        run_ok "wget --no-check-certificate -c $kernel_url" "Downloading..."
        log_success "Download finished"
      fi
    fi
    echo
    # Unpacking
    log_debug "Phase 3 of 5: Linux source code Unpacking"
    printf "%s \\n" "${GREEN}▣▣${YELLOW}▣${CYAN}□□□${NORMAL} Phase ${YELLOW}3${NORMAL} of ${GREEN}6${NORMAL}: Unpacking Linux source code"
    log_debug "Unpacking Linux source code"
    run_ok "tar xvf linux-${LINUX_VER}.tar.$file_ext" "Unpacking..." #>>"${RUN_LOG}" 2>&1
    log_success "Unpacking finished"
    #)
  fi
  if [ -d "$INSTALL_DIR"/linux-"${LINUX_VER}" ]; then
    (
      #cd linux-"${LINUX_VER}" || exit
      cd "$INSTALL_DIR"/linux-"${LINUX_VER}" || exit 1
      echo
      # Config
      log_debug "Phase 4 of 5: Configuration"
      printf "%s \\n" "${GREEN}▣▣▣${YELLOW}▣${CYAN}□□${NORMAL} Phase ${YELLOW}4${NORMAL} of ${GREEN}6${NORMAL}: Setup kernel"
      # cp /boot/config-"$(uname -r)" .config
      log_debug "Configuring..."
      if [ ! "$CONFIG_OPTION" = "olddefconfig" ]; then
        make "$CONFIG_OPTION"
      else
        run_ok "make $CONFIG_OPTION" "Writing configuration..."
        log_success "Configuration finished"
      fi
      read_sleep 1
      # Disable debug info since it's enabled by default
      if [ "$ENABLE_DEBUG_INFO" = "0" ]; then

        # DEBUG_INFO_NONE introduced in version 5.18
        num1=$LINUX_VER # version to check if is greater than or equal to
        num2=5.18 # required version

        if [ "$(versionToInt $num1)" -ge "$(versionToInt $num2)" ]; then
          # $num1 is greater than or equal to $num2
          scripts/config --set-val DEBUG_INFO_NONE y
          scripts/config --set-val DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT n
        else
          # $num1 is lesser than $num2
          scripts/config --set-val DEBUG_INFO n
          scripts/config --set-val DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT n
        fi
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
      echo
      # Compilation
      log_debug "Phase 5 of 6: Compilation"
      printf "%s \\n" "${GREEN}▣▣▣▣${YELLOW}▣${CYAN}□${NORMAL} Phase ${YELLOW}5${NORMAL} of ${GREEN}6${NORMAL}: Kernel Compilation"
      log_debug "Compiling The Linux Kernel source code"
      printf "%s \\n" "Go grab a coffee ☕ 😎 This may take a while..."
      run_ok "make bindeb-pkg -j${NPROC}" "Compiling The Linux Kernel source code..."
      log_success "Compiling finished"
      echo
      # Installation
      log_debug "Phase 6 of 6: Installation"
      printf "%s \\n" "${GREEN}▣▣▣▣▣${YELLOW}▣${NORMAL} Phase ${YELLOW}6${NORMAL} of ${GREEN}6${NORMAL}: Kernel Installation"
      cd - 1>/dev/null 2>&1 || exit 1
    )
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
  run_ok "dpkg -i linux-headers-\"${LINUX_FULL_VER}\"_\"${LINUX_FULL_VER}\"-*.deb" "Installing Kernel headers: ${LINUX_VER}"
  run_ok "dpkg -i linux-image-\"${LINUX_FULL_VER}\"_\"${LINUX_FULL_VER}\"-*.deb" "Installing Kernel image: ${LINUX_VER}"
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
  if [ "$INSTALL_DIR" != "" ] && [ "$INSTALL_DIR" != "/" ]; then
    log_debug "Cleaning up temporary files in $INSTALL_DIR."
    find "$INSTALL_DIR" -delete
  else
    log_error "Could not safely clean up temporary files because INSTALL DIR set to $INSTALL_DIR."
  fi

  # Make sure the cursor is back (if spinners misbehaved)
  tput cnorm
  printf "%s \\n" "${GREEN}▣▣▣▣▣▣${NORMAL} All ${GREEN}6${NORMAL} phases finished successfully"

  if [ "$KEXEC" = "1" ]; then
    # Load the new kernel without reboot
    ${INSTALL} kexec-tools
    systemctl kexec
  fi
}

# Start Script
chk_permissions
# Uninstall kernel
if [ "$mode" = "uninstall" ]; then
  if dpkg -s linux-headers-"${LINUX_VER}" >/dev/null 2>&1; then
    apt purge linux-headers-"${LINUX_VER}"
  elif dpkg -s linux-image-"${LINUX_VER}" >/dev/null 2>&1; then
    apt purge linux-image-"${LINUX_VER}"
  fi
  exit
fi

# Install Kernel
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
  if [ -x "$INSTALL_DIR" ]; then
    log_warning "Removing temporary directory and files."
    rm -rf "$INSTALL_DIR"
  fi
fi

exit

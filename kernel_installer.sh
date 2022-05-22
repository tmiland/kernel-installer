#!/usr/bin/env bash
# shellcheck disable=SC2221,SC2222

## Author: Tommy Miland (@tmiland) - Copyright (c) 2022


######################################################################
####                    Kernel Installer.sh                       ####
####               Automatic kernel install script                ####
####                   Maintained by @tmiland                     ####
######################################################################


VERSION='1.0.0'

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
CURRDIR=$(pwd)
SCRIPT_FILENAME=$(basename "$0")
# Logfile
LOGFILE=$CURRDIR/kernel_installer.log
# Default processing units (all available)
NPROC=$(nproc)
# Console output level; ignore debug level messages.
VERBOSE=0
# Show banners
BANNERS=1
# Default Install dir (Default: /opt/linux)
INSTALL_DIR=${INSTALL_DIR:-/opt/linux}
# Default Kernel version
STABLE_VER=$(curl -s https://www.kernel.org | grep -A1 latest_link | tail -n1 | grep -E -o '>[^<]+' | grep -E -o '[^>]+')
MAINLINE_VER=$(curl -s https://www.kernel.org/ | grep -A1 'mainline:' | grep -oP '(?<=strong>).*(?=</strong.*)')
LONGTERM_VER=$(curl -s https://www.kernel.org/ | grep -A1 'longterm:' | grep -oP '(?<=strong>).*(?=</strong.*)' | head -n 1)
LINUX_VER=${LINUX_VER:-$STABLE_VER}
# Installed kernel
CURRENT_VER=$(uname -r)
# Default kexec option
KEXEC=${KEXEC:-0}
# root
root=$(id | grep -i "uid=0(" >/dev/null)
# Repo name
REPO_NAME="tmiland/kernel-installer"
# Functions url
SLIB_URL=https://raw.githubusercontent.com/$REPO_NAME/main/src/slib.sh
# Set default configuration target
CONFIG_OPTION=${CONFIG_OPTION:-olddefconfig}
# Configuration targets:
# config          - Update current config utilising a line-oriented program
# nconfig         - Update current config utilising a ncurses menu based program
# menuconfig      - Update current config utilising a menu based program
# xconfig         - Update current config utilising a QT based front-end
# gconfig         - Update current config utilising a GTK based front-end
# oldconfig       - Update current config utilising a provided .config as base
# localmodconfig  - Update current config disabling modules not loaded
# localyesconfig  - Update current config converting local mods to core
# silentoldconfig - Same as oldconfig, but quietly, additionally update deps
# defconfig       - New config with default from ARCH supplied defconfig
# savedefconfig   - Save current config as ./defconfig (minimal config)
# allnoconfig     - New config where all options are answered with no
# allyesconfig    - New config where all options are accepted with yes
# allmodconfig    - New config selecting modules when possible
# alldefconfig    - New config with all symbols set to default
# randconfig      - New config with random answer to all options
# listnewconfig   - List new options
# olddefconfig    - Same as silentoldconfig but sets new symbols to their default value
# kvmconfig       - Enable additional options for guest kernel support
# tinyconfig      - Configure the tiniest possible kernel

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
  if ! $root; then
    fatal "${RED}${BALLOT_X}Fatal:${NORMAL} The ${SCRIPT_NAME} script must be run as root"
  fi
}

# Check if kernel is installed, abort if same version is found
if uname -r == "${LINUX_VER}" 1>/dev/null 2>&1; then
  fatal "${RED}${BALLOT_X} Kernel ${LINUX_VER} is already installed.\nProcess aborted${NORMAL}"
fi

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

# Exit Script
exit_script() {
  header_logo
  echo -e "
   This script runs on coffee ☕

   ${GREEN}${CHECK}${NORMAL} ${BBLUE}Paypal${NORMAL} ${ARROW} ${YELLOW}https://paypal.me/milanddata${NORMAL}
   ${GREEN}${CHECK}${NORMAL} ${BBLUE}BTC${NORMAL}    ${ARROW} ${YELLOW}33mjmoPxqfXnWNsvy8gvMZrrcG3gEa3YDM${NORMAL}
  "
  echo -e "Documentation for this script is available here: ${YELLOW}\n${ARROW} https://github.com/${REPO_NAME}${NORMAL}\n"
  echo -e "${YELLOW}${ARROW} Goodbye.${NORMAL} ☺"
  echo ""
}

usage() {
  #header
  ## shellcheck disable=SC2046
  printf "Usage: %s %s [options]" "${CYAN}" "${SCRIPT_FILENAME}${NORMAL}"
  echo
  echo "  If called without arguments, installs stable kernel ${YELLOW}${LINUX_VER}${NORMAL} using ${INSTALL_DIR}"
  echo
  printf "%s\\n" "  ${YELLOW}--help      |-h${NORMAL}          display this help and exit"
  printf "%s\\n" "  ${YELLOW}--kernel    |-k${NORMAL}          kernel version of choice"
  printf "%s\\n" "  ${YELLOW}--stable    |-s${NORMAL}          stable kernel version ${YELLOW}$STABLE_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--mainline  |-m${NORMAL}          mainline kernel version ${YELLOW}$MAINLINE_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--longterm  |-l${NORMAL}          longterm kernel version ${YELLOW}$LONGTERM_VER${NORMAL}"
  printf "%s\\n" "  ${YELLOW}--dir       |-d${NORMAL}          install directory"
  printf "%s\\n" "  ${YELLOW}--kexec     |-x${NORMAL}          load new kernel without reboot"
  printf "%s\\n" "  ${YELLOW}--config    |-c${NORMAL}          Set configuration target"
  printf "%s\\n" "  ${YELLOW}--verbose   |-v${NORMAL}          increase verbosity"
  printf "%s\\n" "  ${YELLOW}--nproc     |-n${NORMAL}          set the number of processing units to use"
  printf "%s\\n" "  ${YELLOW}--uninstall |-u${NORMAL}          uninstall kernel"
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
  INSTALL_PKGS="wget curl git rsync fakeroot build-essential ncurses-dev xz-utils libssl-dev bc liblz4-tool paxctl libelf-dev flex bison"
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

install_kernel() {
  clear
  header_logo
  log_info "Started installation log in $LOGFILE"
  echo
  log_info "${CYANBG}Installing The Linux Kernel version:${NORMAL} $LINUX_VER_NAME: ${YELLOW}$LINUX_VER${NORMAL}"
  echo
  printf "%s \\n" "${YELLOW}▣${CYAN}□□□□${NORMAL} Phase ${YELLOW}1${NORMAL} of ${GREEN}5${NORMAL}: Setup packages"
  # Setup Dependencies
  log_debug "Configuring package manager for ${DISTRO_GROUP} .."
  if ! ${PKGCHK} "$INSTALL_PKGS" 1>/dev/null 2>&1; then
    log_debug "Updating packages"
    run_ok "${UPDATE}" "Updating package repo"
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
  printf "%s \\n" "${GREEN}▣${YELLOW}▣${CYAN}□□□${NORMAL} Phase ${YELLOW}2${NORMAL} of ${GREEN}5${NORMAL}: Download Linux source code"
  if [ ! -d "$INSTALL_DIR" ]; then
    mkdir "$INSTALL_DIR" 1>/dev/null 2>&1
  fi
  if [ -d "$INSTALL_DIR" ]; then
    #(
      #cd "$INSTALL_DIR"/linux || exit
      # log_debug "Deleting old Linux source code files in $INSTALL_DIR/linux"
      # rm -rf "$INSTALL_DIR"/linux/*
      cd "$INSTALL_DIR" || exit 1
      log_debug "Downloading Linux source code"
      if [ ! $LINUX_VER_NAME = "Mainline" ]; then
        # Kernel url 1 (Stable/longterm)
        kernel_url=https://cdn.kernel.org/pub/linux/kernel/v"$(echo "$LINUX_VER" | cut -c1)".x/linux-"${LINUX_VER}".tar.xz
        file_ext=xz
      else
        # Kernel url 2 (Mainline)
        kernel_url=https://git.kernel.org/torvalds/t/linux-"${LINUX_VER}".tar.gz
        file_ext=gz
      fi
      run_ok "wget -c $kernel_url" "Downloading..."
      log_debug "Unpacking Linux source code"
      tar xvf linux-"${LINUX_VER}".tar.$file_ext >>"${RUN_LOG}" 2>&1
    #)
  fi
  if [ -d "$INSTALL_DIR"/linux-"${LINUX_VER}" ]; then
    (
      #cd linux-"${LINUX_VER}" || exit
      cd "$INSTALL_DIR"/linux-"${LINUX_VER}" || exit 1

      # Config
      log_debug "Phase 3 of 5: Configuration"
      printf "%s \\n" "${GREEN}▣▣${YELLOW}▣${CYAN}□□${NORMAL} Phase ${YELLOW}3${NORMAL} of ${GREEN}5${NORMAL}: Setup kernel"
      cp /boot/config-"$(uname -r)" .config
      log_debug "Configuring..."
      if [ ! "$CONFIG_OPTION" = "olddefconfig" ]; then
        make "$CONFIG_OPTION"
      else  
        run_ok "make $CONFIG_OPTION" "Writing configuration..."
      fi
      # Compilation
      log_debug "Phase 4 of 5: Compilation"
      printf "%s \\n" "${GREEN}▣▣▣${YELLOW}▣${CYAN}□${NORMAL} Phase ${YELLOW}4${NORMAL} of ${GREEN}5${NORMAL}: Kernel Compilation"
      log_debug "Compiling The Linux Kernel source code"
      printf "%s \\n" "Go grab a coffee ☕ 😎 This may take a while..."
      run_ok "make bindeb-pkg -j${NPROC}" "Compiling The Linux Kernel source code..."

      # Installation
      log_debug "Phase 5 of 5: Installation"
      printf "%s \\n" "${GREEN}▣▣▣▣${YELLOW}▣${NORMAL} Phase ${YELLOW}5${NORMAL} of ${GREEN}5${NORMAL}: Kernel Installation"
      cd - 1>/dev/null 2>&1 || exit 1
    )
  fi
  run_ok "dpkg -i linux-image-\"${LINUX_VER}\"_\"${LINUX_VER}\"-*.deb" "Installing Kernel image: ${LINUX_VER}"
  run_ok "dpkg -i linux-headers-\"${LINUX_VER}\"_\"${LINUX_VER}\"-*.deb" "Installing Kernel headers: ${LINUX_VER}"

  # Cleanup
  printf "%s \\n" "${GREEN}▣▣▣▣▣${NORMAL} Cleaning up"
  if [ "$INSTALL_DIR" != "" ] && [ "$INSTALL_DIR" != "/" ]; then
    log_debug "Cleaning up temporary files in $INSTALL_DIR."
    find "$INSTALL_DIR" -delete
  else
    log_error "Could not safely clean up temporary files because INSTALL DIR set to $INSTALL_DIR."
  fi

  # Make sure the cursor is back (if spinners misbehaved)
  tput cnorm
  printf "%s \\n" "${GREEN}▣▣▣▣▣${NORMAL} All ${GREEN}5${NORMAL} phases finished successfully"

  if [ "$KEXEC" = "1" ]; then
    # Load the new kernel without reboot
    apt-get install kexec-tools
    systemctl kexec
  fi
}

  # Start Script
  chk_permissions
  # Uninstall kernel
  if [ "$mode" = "uninstall" ]; then
    apt remove linux-{image,headers}-"${LINUX_VER}"
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
#!/usr/bin/env bash
#------------------------------------------------------------------------------
# slib - Utility function library for Virtualmin installation scripts
# Copyright 2017 Joe Cooper
# slog logging library Copyright Fred Palmer and Joe Cooper
# Licensed under the BSD 3 clause license
# http://github.com/virtualmin/slib
#------------------------------------------------------------------------------
# shellcheck disable=SC2034,SC2059
cleanup () {
  # Make super duper sure we reap all the spinners
  # This is ridiculous, and I still don't know why spinners stick around.
  if [ -n "$allpids" ]; then
    for pid in $allpids; do
      kill "$pid" 1>/dev/null 2>&1
    done
    tput sgr0
  fi
  tput cnorm
  return 1
}
# This tries to catch any exit, whether normal or forced (e.g. Ctrl-C)
trap cleanup INT QUIT TERM EXIT

# scolors - Color constants
# canonical source http://github.com/swelljoe/scolors

# do we have tput?
if which 'tput' > /dev/null; then
  # do we have a terminal?
  if [ -t 1 ]; then
    # does the terminal have colors?
    ncolors=$(tput colors)
    if [ "$ncolors" -ge 8 ]; then
      RED=$(tput setaf 1)
      GREEN=$(tput setaf 2)
      YELLOW=$(tput setaf 3)
      BLUE=$(tput setaf 4)
      BBLUE=$(tput setaf 153)
      MAGENTA=$(tput setaf 5)
      CYAN=$(tput setaf 6)
      WHITE=$(tput setaf 7)
      REDBG=$(tput setab 1)
      GREENBG=$(tput setab 2)
      YELLOWBG=$(tput setab 3)
      BLUEBG=$(tput setab 4)
      MAGENTABG=$(tput setab 5)
      CYANBG=$(tput setab 6)
      WHITEBG=$(tput setab 7)

      BOLD=$(tput bold)
      UNDERLINE=$(tput smul) # Many terminals don't support this
      NORMAL=$(tput sgr0)
    fi
  fi
else
  echo "tput not found, colorized output disabled."
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  BBLUE=''
  MAGENTA=''
  CYAN=''
  WHITE=''
  REDBG=''
  GREENBG=''
  YELLOWBG=''
  BLUEBG=''
  MAGENTABG=''
  CYANBG=''
  WHITEBG=''

  BOLD=''
  UNDERLINE=''
  NORMAL=''
fi

# slog - logging library
# canonical source http://github.com/swelljoe/slog

# LOG_PATH - Define $LOG_PATH in your script to log to a file, otherwise
# just writes to STDOUT.

# LOG_LEVEL_STDOUT - Define to determine above which level goes to STDOUT.
# By default, all log levels will be written to STDOUT.
LOG_LEVEL_STDOUT="INFO"

# LOG_LEVEL_LOG - Define to determine which level goes to LOG_PATH.
# By default all log levels will be written to LOG_PATH.
LOG_LEVEL_LOG="INFO"

# Useful global variables that users may wish to reference
SCRIPT_ARGS="$*"
SCRIPT_NAME="$0"
SCRIPT_NAME="${SCRIPT_NAME#\./}"
SCRIPT_NAME="${SCRIPT_NAME##/*/}"

# Determines if we print colors or not
if [ "$(tty -s)" ]; then
    INTERACTIVE_MODE="off"
else
    INTERACTIVE_MODE="on"
fi

#--------------------------------------------------------------------------------------------------
# Begin Logging Section
if [ "${INTERACTIVE_MODE}" = "off" ]
then
    # Then we don't care about log colors
    LOG_DEFAULT_COLOR=""
    LOG_ERROR_COLOR=""
    LOG_INFO_COLOR=""
    LOG_SUCCESS_COLOR=""
    LOG_WARN_COLOR=""
    LOG_DEBUG_COLOR=""
else
  LOG_DEFAULT_COLOR=$(tput sgr0)
  LOG_ERROR_COLOR=$(tput setaf 1)
  LOG_INFO_COLOR=$(tput setaf 6)
  LOG_SUCCESS_COLOR=$(tput setaf 2)
  LOG_WARN_COLOR=$(tput setaf 3)
  LOG_DEBUG_COLOR=$(tput setaf 4)
fi

# This function scrubs the output of any control characters used in colorized output
# It's designed to be piped through with text that needs scrubbing.  The scrubbed
# text will come out the other side!
prepare_log_for_nonterminal() {
    # Essentially this strips all the control characters for log colors
    # sed "s/[[:cntrl:]]\\[[0-9;]*m//g"
    # The above doesn't strip everything
    # To break down the sed command,
    # the \x1B is the escape character that starts a control sequence:
    # Ctrl-[ . A control sequence ends with an m,
    # so we find every character that is NOT an m,
    # and the m that follows: [^m]*m.
    # Source: https://stackoverflow.com/a/44274479
    sed "s/\x1B[^m]*m//g"
}

log() {
  local log_text="$1"
  local log_level="$2"
  local log_color="$3"

  # Levels for comparing against LOG_LEVEL_STDOUT and LOG_LEVEL_LOG
  local LOG_LEVEL_DEBUG=0
  local LOG_LEVEL_INFO=1
  local LOG_LEVEL_SUCCESS=2
  local LOG_LEVEL_WARNING=3
  local LOG_LEVEL_ERROR=4

  # Default level to "info"
  [ -z "${log_level}" ] && log_level="INFO";
  [ -z "${log_color}" ] && log_color="${LOG_INFO_COLOR}";

  # Validate LOG_LEVEL_STDOUT and LOG_LEVEL_LOG since they'll be eval-ed.
  case $LOG_LEVEL_STDOUT in
    DEBUG|INFO|SUCCESS|WARNING|ERROR)
      ;;
    *)
      LOG_LEVEL_STDOUT=INFO
      ;;
  esac
  case $LOG_LEVEL_LOG in
    DEBUG|INFO|SUCCESS|WARNING|ERROR)
      ;;
    *)
      LOG_LEVEL_LOG=INFO
      ;;
  esac

  # Check LOG_LEVEL_STDOUT to see if this level of entry goes to STDOUT.
  # XXX This is the horror that happens when your language doesn't have a hash data struct.
  eval log_level_int="\$LOG_LEVEL_${log_level}";
  eval log_level_stdout="\$LOG_LEVEL_${LOG_LEVEL_STDOUT}"
  # shellcheck disable=SC2154
  if [ "$log_level_stdout" -le "$log_level_int" ]; then
    # STDOUT
    printf "%s[%s]%s %s\\n" "$log_color" "$log_level" "$LOG_DEFAULT_COLOR" "$log_text";
  fi
  # This is all very tricky; figures out a numeric value to compare.
  eval log_level_log="\$LOG_LEVEL_${LOG_LEVEL_LOG}"
  # Check LOG_LEVEL_LOG to see if this level of entry goes to LOG_PATH
  # shellcheck disable=SC2154
  if [ "$log_level_log" -le "$log_level_int" ]; then
    # LOG_PATH minus fancypants colors
    if [ -n "$LOG_PATH" ]; then
      today=$(date +"%Y-%m-%d %H:%M:%S %Z")
      printf "[%s] [%s] %s\\n" "$today" "$log_level" "$log_text" |
      # Lets prepare the log for non-terminal
      prepare_log_for_nonterminal >> "$LOG_PATH"
    fi
  fi

  return 0;
}

log_info()      { log "$@"; }
log_success()   { log "$1" "SUCCESS" "${LOG_SUCCESS_COLOR}"; }
log_error()     { log "$1" "ERROR" "${LOG_ERROR_COLOR}"; }
log_warning()   { log "$1" "WARNING" "${LOG_WARN_COLOR}"; }
log_debug()     { log "$1" "DEBUG" "${LOG_DEBUG_COLOR}"; }

# End Logging Section
#--------------------------------------------------------------------------------------------------
# spinner - Log to provide spinners when long-running tasks happen
# Canonical source http://github.com/swelljoe/spinner

# Config variables, set these after sourcing to change behavior.
SPINNER_COLORNUM=2 # What color? Irrelevent if COLORCYCLE=1.
SPINNER_COLORCYCLE=1 # Does the color cycle?
SPINNER_DONEFILE="stopspinning" # Path/name of file to exit on.
SPINNER_SYMBOLS="ASCII_PROPELLER" # Name of the variable containing the symbols.
SPINNER_CLEAR=1 # Blank the line when done.

spinner () {
  # Safest option are one of these. Doesn't need Unicode, at all.
  local ASCII_PROPELLER="/ - \\ |"

  # Bigger spinners and progress type bars; takes more space.
  local WIDE_ASCII_PROG="[>----] [=>---] [==>--] [===>-] [====>] [----<] [---<=] [--<==] [-<===] [<====]"
  local WIDE_UNI_GREYSCALE="▒▒▒▒▒▒▒ █▒▒▒▒▒▒ ██▒▒▒▒▒ ███▒▒▒▒ ████▒▒▒ █████▒▒ ██████▒ ███████ ██████▒ █████▒▒ ████▒▒▒ ███▒▒▒▒ ██▒▒▒▒▒ █▒▒▒▒▒▒ ▒▒▒▒▒▒▒"
  local WIDE_UNI_GREYSCALE2="▒▒▒▒▒▒▒ █▒▒▒▒▒▒ ██▒▒▒▒▒ ███▒▒▒▒ ████▒▒▒ █████▒▒ ██████▒ ███████ ▒██████ ▒▒█████ ▒▒▒████ ▒▒▒▒███ ▒▒▒▒▒██ ▒▒▒▒▒▒█"

  local SPINNER_NORMAL
  SPINNER_NORMAL=$(tput sgr0)

  eval SYMBOLS=\$${SPINNER_SYMBOLS}

  # Get the parent PID
  SPINNER_PPID=$(ps -p "$$" -o ppid=)
  while :; do
    tput civis
    for c in ${SYMBOLS}; do
      if [ $SPINNER_COLORCYCLE -eq 1 ]; then
        if [ $SPINNER_COLORNUM -eq 7 ]; then
          SPINNER_COLORNUM=1
        else
          SPINNER_COLORNUM=$((SPINNER_COLORNUM+1))
        fi
      fi
      local SPINNER_COLOR
      SPINNER_COLOR=$(tput setaf ${SPINNER_COLORNUM})
      tput sc
      env printf "${SPINNER_COLOR}${c}${SPINNER_NORMAL}"
      tput rc
      if [ -f "${SPINNER_DONEFILE}" ]; then
        if [ ${SPINNER_CLEAR} -eq 1 ]; then
          tput el
        fi
	      rm -f ${SPINNER_DONEFILE}
	      break 2
      fi
      # This is questionable. sleep with fractional seconds is not
      # always available, but seems to not break things, when not.
      env sleep .2
      # Check to be sure parent is still going; handles sighup/kill
      if [ -n "$SPINNER_PPID" ]; then
        # This is ridiculous. ps prepends a space in the ppid call, which breaks
        # this ps with a "garbage option" error.
        # XXX Potential gotcha if ps produces weird output.
        # shellcheck disable=SC2086
        SPINNER_PARENTUP=$(ps --no-headers $SPINNER_PPID)
        if [ -z "$SPINNER_PARENTUP" ]; then
          break 2
        fi
      fi
    done
  done
  tput rc
  tput cnorm
  return 0
}

# run_ok - function to run a command or function, start a spinner and print a confirmation
# indicator when done.
# Canonical source - http://github.com/swelljoe/run_ok
RUN_LOG="run.log"

# Check for unicode support in the shell
# This is a weird function, but seems to work. Checks to see if a unicode char can be
# written to a file and can be read back.
shell_has_unicode () {
  # Write a unicode character to a file...read it back and see if it's handled right.
  env printf "\\u2714"> unitest.txt

  read -r unitest < unitest.txt
  rm -f unitest.txt
  if [ ${#unitest} -le 3 ]; then
    return 0
  else
    return 1
  fi
}

# Setup spinner with our prefs.
SPINNER_COLORCYCLE=0
SPINNER_COLORNUM=6
if shell_has_unicode; then
  SPINNER_SYMBOLS="WIDE_UNI_GREYSCALE2"
else
  SPINNER_SYMBOLS="WIDE_ASCII_PROG"
fi
SPINNER_CLEAR=0 # Don't blank the line, so our check/x can simply overwrite it.

# Perform an action, log it, and print a colorful checkmark or X if failed
# Returns 0 if successful, $? if failed.
run_ok () {
  # Shell is really clumsy with passing strings around.
  # This passes the unexpanded $1 and $2, so subsequent users get the
  # whole thing.
  local cmd="${1}"
  local msg="${2}"
  local columns
  columns=$(tput cols)
  if [ "$columns" -ge 80 ]; then
    columns=79
  fi
  # shellcheck disable=SC2004
  COL=$((${columns}-${#msg}-7 ))

  printf "%s%${COL}s" "$2"
  # Make sure there some unicode action in the shell; there's no
  # way to check the terminal in a POSIX-compliant way, but terms
  # are mostly ahead of shells.
  # Unicode checkmark and x mark for run_ok function
  CHECK='\u2714'
  BALLOT_X='\u2718'
  spinner &
  spinpid=$!
  allpids="$allpids $spinpid"
  echo "Spin pid is: $spinpid" >> ${RUN_LOG}
  eval "${cmd}" 1>> ${RUN_LOG} 2>&1
  local res=$?
  touch ${SPINNER_DONEFILE}
  env sleep .2 # It's possible to have a race for stdout and spinner clobbering the next bit
  # Just in case the spinner survived somehow, kill it.
  pidcheck=$(ps --no-headers ${spinpid})
  if [ -n "$pidcheck" ]; then
    echo "Made it here...why?" >> ${RUN_LOG}
    kill $spinpid 2>/dev/null
    rm -rf ${SPINNER_DONEFILE} 2>/dev/null 2>&1
    tput rc
    tput cnorm
  fi
  # Log what we were supposed to be running
  printf "${msg}: " >> ${RUN_LOG}
  if shell_has_unicode; then
    if [ $res -eq 0 ]; then
      printf "Success.\\n" >> ${RUN_LOG}
      env printf "${GREENBG}[  ${CHECK}  ]${NORMAL}\\n"
      return 0
    else
      log_error "Failed with error: ${res}"
      env printf "${REDBG}[  ${BALLOT_X}  ]${NORMAL}\\n"
      if [ "$RUN_ERRORS_FATAL" ]; then
        echo
        log_fatal "Something went wrong. Exiting."
        log_fatal "The last few log entries were:"
        tail -15 ${RUN_LOG}
        exit 1
      fi
      return ${res}
    fi
  else
    if [ $res -eq 0 ]; then
      printf "Success.\\n" >> ${RUN_LOG}
      env printf "${GREENBG}[ OK! ]${NORMAL}\\n"
      return 0
    else
      printf "Failed with error: ${res}\\n" >> ${RUN_LOG}
      echo
      env printf "${REDBG}[ERROR]${NORMAL}\\n"
      if [ "$RUN_ERRORS_FATAL" ]; then
        log_fatal "Something went wrong with the previous command. Exiting."
        exit 1
      fi
      return ${res}
    fi
  fi
}
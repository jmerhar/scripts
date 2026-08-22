# shellcheck shell=bash
#
# What every script needs: its own name, where it is installed, and how it logs.
#
# Sourced at development time and inlined by compile-includes.sh at build time, so nothing here may
# assume a file beside it at run time. The other libraries declare this one as a dependency rather than
# duplicating any of it; the compiler follows that and inlines each file once.

# Double-source guard
if [[ "${_CORE_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_CORE_SH_LOADED="true"

# --- Color Setup (only when connected to a terminal) ---
if [[ -t 1 ]]; then
  _color_info=$(tput setaf 4)    # Blue for info
  _color_debug=$(tput setaf 8)   # Grey for debug
  _color_warn=$(tput setaf 3)    # Yellow for warnings
  _color_error=$(tput setaf 1)   # Red for errors
  _color_reset=$(tput sgr0)
  _text_bold=$(tput bold)
else
  _color_info=""
  _color_debug=""
  _color_warn=""
  _color_error=""
  _color_reset=""
  _text_bold=""
fi

# --- Script Identity ---
# Derived from $0; callers may override by setting SCRIPT_NAME before sourcing.
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0" .sh)}"
readonly SCRIPT_NAME

# --- Behavioral Flags (callers may override before sourcing or after) ---
_LOG_QUIET="${_LOG_QUIET:-false}"
IS_DEBUG_MODE="${IS_DEBUG_MODE:-false}"

########################################
# Enables debug mode (verbose log_debug output).
# Globals:
#   IS_DEBUG_MODE
# Arguments:
#   None
########################################
enable_debug_mode() {
  IS_DEBUG_MODE="true"
}

########################################
# Determines the installation prefix of the script (e.g., /usr/local).
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Prints the install prefix to stdout.
########################################
_get_script_prefix() {
  local script_dir
  script_dir=$(dirname "$0")
  local script_path
  script_path=$( (cd "${script_dir}" && pwd -P) )

  if [[ -z "${script_path}" ]]; then
    return
  fi

  local bin_dir
  bin_dir=$(basename "${script_path}")
  if [[ "${bin_dir}" =~ ^(bin|sbin)$ ]]; then
    dirname "${script_path}"
  fi
}

########################################
# Writes a log message to LOG_FILE with an ISO 8601 timestamp.
# Does nothing if LOG_FILE is unset or empty.
# Globals:
#   LOG_FILE
# Arguments:
#   level: The log level (e.g., INFO, ERROR).
#   message: The message to log.
########################################
log_message() {
  if [[ -z "${LOG_FILE:-}" ]]; then
    return
  fi

  local level="$1"
  shift
  local message="$*"
  local msg
  msg="[$(date +'%Y-%m-%dT%H:%M:%S%z')] [${level}]: ${message}"

  mkdir -p "$(dirname "${LOG_FILE}")"
  echo "${msg}" >> "${LOG_FILE}"
}

########################################
# Logs an info message to the log file and to stdout (unless _LOG_QUIET).
# When connected to a terminal, output is colorized.
# Globals:
#   _LOG_QUIET, _color_info, _text_bold, _color_reset
# Arguments:
#   Message to print.
########################################
log_info() {
  log_message "INFO" "$*"
  if [[ "${_LOG_QUIET}" != "true" ]]; then
    if [[ -t 1 ]]; then
      printf "%b\n" "${_color_info}${_text_bold}[INFO]: $*${_color_reset}"
    else
      printf "%s\n" "[INFO]: $*"
    fi
  fi
}

########################################
# Logs a warning to the log file and to stderr.
# When connected to a terminal, output is colorized.
#
# For a condition the script is reporting rather than suffering: a machine filling up, a threshold
# crossed, an assumption worth stating out loud. ERROR says the script itself went wrong, so using it to
# deliver a finding tells the reader the tool failed — and a red line for a working tool teaches them to
# distrust the next one. Stderr, like ERROR, so a caller reading the output does not receive a diagnostic
# as data.
# Globals:
#   _color_warn, _text_bold, _color_reset
# Arguments:
#   Message to print.
########################################
log_warn() {
  log_message "WARN" "$*"
  if [[ -t 2 ]]; then
    printf "%b\n" "${_color_warn}${_text_bold}[WARN]: $*${_color_reset}" >&2
  else
    printf "%s\n" "[WARN]: $*" >&2
  fi
}

########################################
# Logs an error message to the log file and to stderr.
# When connected to a terminal, output is colorized.
# Globals:
#   _color_error, _text_bold, _color_reset
# Arguments:
#   Message to print.
########################################
log_error() {
  log_message "ERROR" "$*"
  if [[ -t 2 ]]; then
    printf "%b\n" "${_color_error}${_text_bold}[ERROR]: $*${_color_reset}" >&2
  else
    printf "%s\n" "[ERROR]: $*" >&2
  fi
}

########################################
# Logs a debug message if IS_DEBUG_MODE is enabled.
# Writes to the log file and to stdout when connected to a terminal.
# Globals:
#   IS_DEBUG_MODE, _color_debug, _color_reset
# Arguments:
#   Message to print.
########################################
log_debug() {
  if [[ "${IS_DEBUG_MODE}" == "true" ]]; then
    log_message "DEBUG" "$*"
    if [[ -t 1 ]]; then
      printf "%b\n" "${_color_debug}[DEBUG]: $*${_color_reset}"
    else
      printf "%s\n" "[DEBUG]: $*"
    fi
  fi
}


########################################
# Turns off the colouring of log messages.
#
# core.sh picks its log colours when it loads, from whether stdout is a terminal. A script with its own
# --no-color option needs a way to say so afterwards, and doing it by assigning to _color_info and friends
# means every such script has to know the library's internal names — which is how one script came to blank
# five variables by hand.
# Globals:
#   _color_info, _color_debug, _color_warn, _color_error, _color_reset, _text_bold
########################################
disable_log_colors() {
  _color_info=""
  _color_debug=""
  _color_warn=""
  _color_error=""
  _color_reset=""
  _text_bold=""
}

########################################
# Prints the log file a script should use when the caller names none.
#
# Only an installed copy gets one: under a prefix the convention is <prefix>/var/log/<script>.log, and a
# script run from a checkout prints nothing, so it logs to the terminal alone rather than scattering log
# files through a working tree. Callers treat empty as "no log file", which is what LOG_FILE unset means
# to log_message.
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
# Outputs:
#   The path, or nothing when the script is not running from an install prefix.
########################################
default_log_file() {
  local prefix
  prefix=$(_get_script_prefix)
  if [[ -z "${prefix}" ]]; then
    return
  fi
  printf '%s/var/log/%s.log' "${prefix}" "${SCRIPT_NAME}"
}

########################################
# Runs a command, sending its output to the log file as well as the terminal.
#
# log_message records what the script decided; this records what the commands it ran had to say. Without
# it a failed rsync leaves "exit code 23" in the log and its explanation — the path, the permission, the
# full disk — only on a terminal nobody was watching.
#
# The exit status is the command's own, not tee's, because callers map particular statuses to meaning
# (rsync's 24 is a warning, not a failure). Note that `tee` writes asynchronously: the log may still be
# being written when this returns, so a caller that reads it back immediately should wait for the content
# rather than assume it is complete.
# Globals:
#   LOG_FILE
# Arguments:
#   The command and its arguments.
# Returns:
#   The command's exit status.
########################################
log_command() {
  log_debug "Running command: $*"

  if [[ -z "${LOG_FILE:-}" ]]; then
    "$@"
    return
  fi

  mkdir -p "$(dirname "${LOG_FILE}")"
  local status=0
  "$@" > >(tee -a "${LOG_FILE}") 2> >(tee -a "${LOG_FILE}" >&2) || status=$?
  return "${status}"
}

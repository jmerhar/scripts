# shellcheck shell=bash
#
# Common library for shared shell script functions.
# This file is not meant to be executed directly. It is sourced by other
# scripts at development time and inlined by compile-includes.sh at build time.

# Double-source guard
if [[ "${_COMMON_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_COMMON_SH_LOADED="true"

# --- Color Setup (only when connected to a terminal) ---
if [[ -t 1 ]]; then
  _color_info=$(tput setaf 4)    # Blue for info
  _color_debug=$(tput setaf 8)   # Grey for debug
  _color_error=$(tput setaf 1)   # Red for errors
  _color_reset=$(tput sgr0)
  _text_bold=$(tput bold)
else
  _color_info=""
  _color_debug=""
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

#######################################
# Enables debug mode (verbose log_debug output).
# Globals:
#   IS_DEBUG_MODE
# Arguments:
#   None
#######################################
enable_debug_mode() {
  IS_DEBUG_MODE="true"
}

#######################################
# Determines the installation prefix of the script (e.g., /usr/local).
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Prints the install prefix to stdout.
#######################################
get_script_prefix() {
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

#######################################
# Writes a log message to LOG_FILE with an ISO 8601 timestamp.
# Does nothing if LOG_FILE is unset or empty.
# Globals:
#   LOG_FILE
# Arguments:
#   level: The log level (e.g., INFO, ERROR).
#   message: The message to log.
#######################################
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

#######################################
# Logs an info message to the log file and to stdout (unless _LOG_QUIET).
# When connected to a terminal, output is colorized.
# Globals:
#   _LOG_QUIET, _color_info, _text_bold, _color_reset
# Arguments:
#   Message to print.
#######################################
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

#######################################
# Logs an error message to the log file and to stderr.
# When connected to a terminal, output is colorized.
# Globals:
#   _color_error, _text_bold, _color_reset
# Arguments:
#   Message to print.
#######################################
log_error() {
  log_message "ERROR" "$*"
  if [[ -t 2 ]]; then
    printf "%b\n" "${_color_error}${_text_bold}[ERROR]: $*${_color_reset}" >&2
  else
    printf "%s\n" "[ERROR]: $*" >&2
  fi
}

#######################################
# Logs a debug message if IS_DEBUG_MODE is enabled.
# Writes to the log file and to stdout when connected to a terminal.
# Globals:
#   IS_DEBUG_MODE, _color_debug, _color_reset
# Arguments:
#   Message to print.
#######################################
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

#######################################
# Finds and sources the configuration file.
# Search order:
#   1. Same directory as the script (for standalone/tarball use)
#   2. <install-prefix>/etc/ (for Homebrew/package installs)
#   3. /etc/ (system-wide fallback)
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
# Returns:
#   0 if config was found and sourced, 1 otherwise.
#######################################
load_config() {
  local script_dir
  script_dir=$(cd "$(dirname "$0")" && pwd -P)
  local config_path_local="${script_dir}/${SCRIPT_NAME}.conf"

  local prefix
  prefix=$(get_script_prefix)
  local config_path_prefix=""
  local config_path_system="/etc/${SCRIPT_NAME}.conf"

  if [[ -n "${prefix}" ]]; then
    config_path_prefix="${prefix}/etc/${SCRIPT_NAME}.conf"
  fi

  local config_to_load=""
  if [[ -r "${config_path_local}" ]]; then
    config_to_load="${config_path_local}"
  elif [[ -n "${config_path_prefix}" && -r "${config_path_prefix}" ]]; then
    config_to_load="${config_path_prefix}"
  elif [[ -r "${config_path_system}" ]]; then
    config_to_load="${config_path_system}"
  fi

  if [[ -z "${config_to_load}" ]]; then
    return 1
  fi

  log_info "Loading configuration from: ${config_to_load}"
  set +o nounset
  # shellcheck source=/dev/null
  source "${config_to_load}"
  set -o nounset
}

#######################################
# Validates configuration variables according to type-prefixed rules.
# Each argument is either "NAME" (non-empty string check) or "TYPE:NAME".
# Supported types:
#   (none)  — variable must be set and non-empty (default)
#   int     — variable must be a positive integer
#   array   — variable must be a declared, non-empty array
# Globals:
#   None (checks variables by name)
# Arguments:
#   Type-prefixed variable names to check (e.g., "HOST" "int:PORT" "array:DIRS").
# Returns:
#   0 if all checks pass, 1 if any fail.
#######################################
validate_config() {
  local has_errors=false

  for spec in "$@"; do
    local var_type="string"
    local var_name="${spec}"

    if [[ "${spec}" == *:* ]]; then
      var_type="${spec%%:*}"
      var_name="${spec#*:}"
    fi

    case "${var_type}" in
      string)
        if [[ -z "${!var_name:-}" ]]; then
          log_error "Required setting '${var_name}' is missing or empty."
          has_errors=true
        fi
        ;;
      int)
        if [[ ! "${!var_name:-}" =~ ^[1-9][0-9]*$ ]]; then
          log_error "${var_name} must be a positive integer, got '${!var_name:-}'."
          has_errors=true
        fi
        ;;
      array)
        if ! declare -p "${var_name}" &>/dev/null || eval "(( \${#${var_name}[@]} == 0 ))"; then
          log_error "Required setting '${var_name}' is missing or empty."
          has_errors=true
        fi
        ;;
      *)
        log_error "Unknown validation type '${var_type}' for '${var_name}'."
        has_errors=true
        ;;
    esac
  done

  if [[ "${has_errors}" == "true" ]]; then
    return 1
  fi
}

# shellcheck shell=bash
#
# Finding and validating a script's configuration.
#
# Sourced at development time and inlined by compile-includes.sh at build time.

# Double-source guard
if [[ "${_CONFIG_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_CONFIG_SH_LOADED="true"

# Logging, and the install prefix the search below uses. Declared here rather than left to each script:
# the compiler follows this and inlines core.sh once, so a script that wants a config need not know that a
# config needs a logger.
# shellcheck source=./core.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/core.sh"
# @include core.sh

########################################
# Sources a configuration file, announcing which one.
# nounset is relaxed around the source so a config may reference variables that are not set, and
# restored afterwards so the script's own strictness is unaffected.
# Arguments:
#   path: The configuration file to source.
########################################
_source_config() {
  log_info "Loading configuration from: $1"
  set +o nounset
  # shellcheck source=/dev/null
  source "$1"
  set -o nounset
}

########################################
# Finds and sources the configuration file.
# Search order:
#   0. $CONFIG_FILE, when set
#   1. Same directory as the script (for standalone/tarball use)
#   2. <install-prefix>/etc/ (for Homebrew/package installs)
#   3. /etc/ (system-wide fallback)
# Globals:
#   CONFIG_FILE, SCRIPT_NAME
# Arguments:
#   None
# Returns:
#   0 if config was found and sourced, 2 if CONFIG_FILE names a file that cannot be read, 1 if no
#   config file exists. The two failures are distinguished because "you asked for a file I cannot
#   read" is a user error every caller should refuse, while "there is no config" is normal for a
#   script whose every setting has a default.
########################################
load_config() {
  # A named file wins outright, and an unreadable one is an error rather than a quiet fall back to the
  # search: naming a file excludes the alternatives, so silently loading a different config — with
  # different backup targets or credentials in it — would be worse than refusing.
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    if [[ ! -r "${CONFIG_FILE}" ]]; then
      log_error "CONFIG_FILE is set to '${CONFIG_FILE}', which does not exist or is not readable."
      return 2
    fi
    _source_config "${CONFIG_FILE}"
    return
  fi

  local script_dir
  script_dir=$(cd "$(dirname "$0")" && pwd -P)
  local config_path_local="${script_dir}/${SCRIPT_NAME}.conf"

  local prefix
  prefix=$(_get_script_prefix)
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

  _source_config "${config_to_load}"
}

########################################
# Loads configuration for a script that can run without one.
# An absent config is normal for such a script, since every setting has a default — but a CONFIG_FILE
# naming a file that cannot be read is a user error, because carrying on would apply the very defaults
# the caller believes they have overridden. Callers redirect stdout themselves when they do not want
# _source_config's "Loading configuration from" line; the refusal goes to stderr either way.
# Globals:
#   CONFIG_FILE, SCRIPT_NAME
# Returns:
#   0 whether or not a config was found, 1 when CONFIG_FILE cannot be read (load_config has logged why).
########################################
load_optional_config() {
  local status=0
  load_config || status=$?
  (( status != 2 ))
}

########################################
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
########################################
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
        # The declared attributes distinguish an array from a plain string: ${#var[@]} is 1 for a
        # scalar, so a length check alone accepts any non-empty value and the type is never verified.
        local declaration="" attributes=""
        if declaration=$(declare -p "${var_name}" 2>/dev/null); then
          attributes="${declaration#declare -}"
          attributes="${attributes%% *}"
        fi

        if [[ -z "${declaration}" ]]; then
          log_error "Required setting '${var_name}' is missing or empty."
          has_errors=true
        elif [[ "${attributes}" != *[aA]* ]]; then
          log_error "Required setting '${var_name}' must be an array, e.g. ${var_name}=(one two)."
          has_errors=true
        elif eval "(( \${#${var_name}[@]} == 0 ))"; then
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

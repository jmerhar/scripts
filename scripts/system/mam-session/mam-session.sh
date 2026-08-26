#!/usr/bin/env bash
#
# Keeps a MyAnonamouse dynamic-seedbox session pointed at this machine's current address.
#
# The tracker binds a session to the address and network it was created from, and announces fail once
# either changes — silently, in the sense that the client keeps trying and the tracker keeps refusing.
# The dynamic-seedbox endpoint exists to re-point such a session, and is the supported way to automate
# this: it takes the session cookie and reads the address from the request itself.
#
# What it is given is a session created in the tracker's security settings with dynamic seedbox allowed,
# never an account password. That is not only the safer secret to hold — a session can be revoked in one
# click, an account cannot — it is the only thing the endpoint accepts: an ordinary login session is
# refused as the wrong session type.
#
# The endpoint is called sparingly, and that is the point of most of what follows. It is a private
# tracker's API; a script that polled it every minute would be the script that got an account
# suspended. So a call happens only when the address appears to have changed, or when a minimum
# interval has passed, and the address the tracker itself reports is what gets remembered.
#
# The session cookie can be rotated by the tracker, so whatever comes back is kept and used next time,
# and the cookie is passed in a file rather than on the command line, where every other user on the
# machine could read it out of the process list.
#
# Usage:
#   ./mam-session.sh [OPTIONS]

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../../lib/colors.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/colors.sh"
# @include ../../lib/colors.sh
# shellcheck source=../../lib/cli.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/cli.sh"
# @include ../../lib/cli.sh
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
# shellcheck source=../../lib/config.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/config.sh"
# @include ../../lib/config.sh

# --- Environment seams ---
# The endpoint and the clock, so a test can describe a tracker and an elapsed interval rather than wait
# for one. The endpoint is a seam as much for safety as for testing: nothing in a test should be able to
# reach a private tracker.
: "${MAM_ENDPOINT:=https://t.myanonamouse.net/json/dynamicSeedbox.php}"
: "${NOW:=}"
readonly MAM_ENDPOINT

# --- Global State (option flags) ---
_force=false
_dry_run=false
_quiet=false
_status=false
_no_color=false

# Resolved settings, filled in by apply_config.
_state_dir=""
_ip_service="https://api.ipify.org"
_min_interval=3600
_timeout=20

# Paths within the state directory, set by apply_config.
_jar=""
_last_ip_file=""
_last_call_file=""
_last_result_file=""

# --- Color Variables (set by setup_colors "${_no_color}") ---

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME, _min_interval
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Point a MyAnonamouse dynamic-seedbox session at this machine's current address,
when the address has changed.

Options:
  -f, --force     Call the tracker even when the address looks unchanged and the
                  minimum interval has not passed.
  -s, --status    Show what is stored — last address, last call, session age — and
                  call nothing.
  -n, --dry-run   Say what would happen without calling the tracker or writing state.
  -q, --quiet     Say nothing unless something changed or failed, for cron.
  -C, --no-color  Disable colored output.
  -d, --debug     Enable verbose debug logging.
  -h, --help      Show this help message.

The session cookie is read from the configuration file (e.g. /etc/${SCRIPT_NAME}.conf),
which must not be readable by other users. Create the session in the tracker's
security settings with dynamic seedbox allowed; an ordinary login session is
refused, and no account password is ever needed here.

Calls are made at most once every ${_min_interval} seconds unless --force says otherwise,
because this is a private tracker's API and needless requests are the kind of
thing accounts are suspended for.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _force, _status, _dry_run, _quiet, _no_color
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        _force=true
        shift
        ;;
      -s|--status)
        _status=true
        shift
        ;;
      -n|--dry-run)
        _dry_run=true
        shift
        ;;
      -q|--quiet)
        _quiet=true
        shift
        ;;
      -C|--no-color)
        _no_color=true
        shift
        ;;
      -d|--debug)
        enable_debug_mode
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      -*)
        die_usage "Unknown option '$1'."
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  reject_positionals "${positional[@]+"${positional[@]}"}"
}

########################################
# Resolves the settings, and refuses a configuration other users can read.
#
# The permission check is not ceremony: the session in that file is enough to act as the account on the
# tracker, and the version of this script that lived in a bin directory carried its session in a
# world-readable file. A warning would be ignored, so this refuses.
# Globals:
#   CONFIG_FILE, STATE_DIR, IP_SERVICE, MIN_INTERVAL, TIMEOUT, and the resolved globals.
# Arguments:
#   None
# Returns:
#   0 when the settings are usable, 1 otherwise.
########################################
apply_config() {
  local config_path="${CONFIG_FILE:-}"
  if [[ -n "${config_path}" && -f "${config_path}" ]]; then
    local mode
    mode="$(stat_mode "${config_path}")"
    if [[ -n "${mode}" && "${mode: -2}" != "00" ]]; then
      log_error "'${config_path}' is readable by other users (mode ${mode}), and it holds a tracker session. Run: chmod 600 '${config_path}'"
      return 1
    fi
  fi

  _state_dir="${STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/${SCRIPT_NAME}}"
  _ip_service="${IP_SERVICE-${_ip_service}}"
  _min_interval="${MIN_INTERVAL:-${_min_interval}}"
  _timeout="${TIMEOUT:-${_timeout}}"

  if [[ ! "${_min_interval}" =~ ^[0-9]+$ ]]; then
    log_error "MIN_INTERVAL must be a whole number of seconds, got '${_min_interval}'."
    return 1
  fi
  if [[ ! "${_timeout}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "TIMEOUT must be a positive whole number of seconds, got '${_timeout}'."
    return 1
  fi

  _jar="${_state_dir}/session.cookies"
  _last_ip_file="${_state_dir}/last-address"
  _last_call_file="${_state_dir}/last-call"
  _last_result_file="${_state_dir}/last-result"
}

########################################
# Prints a file's permission bits, or nothing when they cannot be read.
#
# Its own accessor rather than platform.sh's, because no other script needs the mode and the two
# platforms spell the format differently.
# Globals:
#   None
# Arguments:
#   path: File to inspect.
# Outputs:
#   The mode as digits, e.g. 600.
########################################
stat_mode() {
  if stat -c '%a' / &>/dev/null; then
    stat -c '%a' "$1" 2>/dev/null
    return
  fi
  stat -f '%Lp' "$1" 2>/dev/null
}

########################################
# Prints the current time as seconds since the epoch, honouring the NOW seam.
# Globals:
#   NOW
# Arguments:
#   None
# Outputs:
#   The epoch seconds.
########################################
now_seconds() {
  if [[ -n "${NOW}" ]]; then
    printf '%s' "${NOW}"
    return
  fi
  date +%s
}

########################################
# Creates the state directory, private to this user.
#
# The session cookie lives here, so the directory is created with no access for anyone else rather than
# left to whatever the umask happens to be.
# Globals:
#   _state_dir
# Arguments:
#   None
# Returns:
#   0 on success, 1 when the directory cannot be made.
########################################
prepare_state_dir() {
  if [[ ! -d "${_state_dir}" ]]; then
    mkdir -p "${_state_dir}" || return 1
  fi
  chmod 700 "${_state_dir}" 2>/dev/null || true
}

########################################
# Writes the configured session into a fresh cookie jar.
#
# A jar rather than a command-line argument, because arguments are visible to every other user on the
# machine through the process list — a session cookie handed over that way is a session cookie shared
# with anyone who runs ps at the wrong moment. The format is the one curl reads and writes, so whatever
# the tracker rotates the cookie to is kept by the same file.
# Globals:
#   MAM_ID, _jar
# Arguments:
#   None
# Returns:
#   0 when a jar holding a session exists, 1 when there is no session to write.
########################################
seed_jar() {
  if [[ -s "${_jar}" ]] && grep -q 'mam_id' "${_jar}" 2>/dev/null; then
    log_debug "Using the session stored in ${_jar}."
    return 0
  fi

  if [[ -z "${MAM_ID:-}" ]]; then
    log_error "No session available. Set MAM_ID in the configuration file to a session created in the tracker's security settings with dynamic seedbox allowed."
    return 1
  fi

  # The tracker's own domain, over TLS, expiring far enough out that curl does not drop it; the tracker
  # decides the real lifetime and rotates the value when it wants to.
  local host="${MAM_ENDPOINT#*://}"
  host="${host%%/*}"
  umask 077
  printf '#HttpOnly_%s\tFALSE\t/\tTRUE\t2145916800\tmam_id\t%s\n' "${host}" "${MAM_ID}" > "${_jar}"
  chmod 600 "${_jar}" 2>/dev/null || true
  log_debug "Seeded a cookie jar from the configured session."
}

########################################
# Prints this machine's public address according to the configured service.
#
# Only used to decide whether the tracker is worth calling, so a service that is down or slow is not an
# error: the caller falls back to calling the tracker, which reports the address itself.
# Globals:
#   _ip_service, _timeout
# Arguments:
#   None
# Outputs:
#   The address, or nothing.
########################################
current_address() {
  [[ -n "${_ip_service}" ]] || return 0
  local address
  address="$(curl -fsS --max-time "${_timeout}" "${_ip_service}" 2>/dev/null || true)"
  address="${address//[[:space:]]/}"
  # Anything that is not an address is a captive portal or an error page, not an answer.
  [[ "${address}" =~ ^[0-9a-fA-F.:]+$ ]] || return 0
  printf '%s' "${address}"
}

########################################
# Calls the endpoint and prints its reply, as "http-status<TAB>body".
# Globals:
#   MAM_ENDPOINT, _jar, _timeout
# Arguments:
#   None
# Outputs:
#   The status and body, tab-separated.
########################################
call_endpoint() {
  local body status
  body="$(mktemp "${TMPDIR:-/tmp}/mam-session.XXXXXX")"
  status="$(curl -sS --max-time "${_timeout}" -o "${body}" -w '%{http_code}' -b "${_jar}" -c "${_jar}" "${MAM_ENDPOINT}" 2>/dev/null || printf 'no-response')"
  printf '%s\t%s' "${status}" "$(cat "${body}")"
  rm -f "${body}"
}

########################################
# Turns the tracker's refusal into the setting that has to change.
#
# The endpoint reports why it refused, and each reason has a different fix that only a person with the
# tracker's settings open can apply. Printing the raw message and leaving it there is what makes a tool
# like this feel broken, when in fact it is reporting something actionable.
# Globals:
#   Color globals.
# Arguments:
#   message: The tracker's message.
#   asn: The network the tracker saw, if it said.
# Outputs:
#   Advice on stderr.
########################################
explain_refusal() {
  local message="$1" asn="${2:-}"
  local lower="${message,,}"

  if [[ "${lower}" == *"session type"* || "${lower}" == *"not allowed this function"* ]]; then
    log_error "This session is not allowed to set a dynamic seedbox, which is the only thing it is used for here. In the tracker's security settings, open the session and enable 'allow session to set dynamic seedbox' — or create a session with that enabled and put it in MAM_ID."
    return 0
  fi
  if [[ "${lower}" == *"asn"* ]]; then
    log_error "The tracker will not accept this session from network ${asn:-this one}. In its security settings, open the session and add this network under 'add additional ASN via IP address'."
    return 0
  fi
  if [[ "${lower}" == *"ip"* && "${lower}" == *"mismatch"* ]]; then
    log_error "The session is locked to a different address. In the tracker's security settings, open the session and allow the current address."
    return 0
  fi
  if [[ "${lower}" == *"invalid session"* ]]; then
    log_error "The tracker does not recognise this session. It has been revoked, or it was not created with dynamic seedbox allowed — an ordinary login session is refused. Create a new one in the tracker's security settings and put it in MAM_ID."
    return 0
  fi
  log_error "The tracker refused: ${message}"
}

########################################
# Prints what is stored, for working out why a run is not doing what was expected.
# Globals:
#   State paths, NOW and color globals.
# Arguments:
#   None
########################################
print_status() {
  local last_ip="unknown" last_call="never" session="none" last_result="nothing yet"
  [[ -s "${_last_ip_file}" ]] && last_ip="$(cat "${_last_ip_file}")"
  [[ -s "${_last_result_file}" ]] && last_result="$(cat "${_last_result_file}")"
  if [[ -s "${_last_call_file}" ]]; then
    local when
    when="$(cat "${_last_call_file}")"
    local age=$(( $(now_seconds) - when ))
    last_call="${age}s ago"
  fi
  [[ -s "${_jar}" ]] && session="stored"

  printf '%s\n' "${_C_BOLD}${_C_GREEN}${SCRIPT_NAME} state${_C_RESET}"
  printf '  %s\n' "state directory : ${_state_dir}"
  printf '  %s\n' "session         : ${session}"
  printf '  %s\n' "last address    : ${last_ip}"
  printf '  %s\n' "last call       : ${last_call}"
  printf '  %s\n' "last result     : ${last_result}"
  printf '  %s\n' "address service : ${_ip_service:-none, the tracker is asked directly}"
}

########################################
# Decides whether the tracker is worth calling, and says why not when it is not.
# Globals:
#   _force, _min_interval, state paths
# Arguments:
#   address: This machine's address, or empty when it could not be determined.
# Outputs:
#   The reason for skipping, when skipping.
# Returns:
#   0 to call, 1 to skip.
########################################
should_call() {
  local address="$1"

  if [[ "${_force}" == true ]]; then
    log_debug "Calling because --force was given."
    return 0
  fi

  if [[ -n "${address}" && -s "${_last_ip_file}" ]]; then
    local last
    last="$(cat "${_last_ip_file}")"
    if [[ "${address}" == "${last}" ]]; then
      printf '%s' "the address is still ${address}"
      return 1
    fi
    log_debug "The address changed from ${last} to ${address}."
    return 0
  fi

  # No address to compare, so the interval is the only guard left against calling on every timer tick.
  if [[ -s "${_last_call_file}" ]]; then
    local when age
    when="$(cat "${_last_call_file}")"
    age=$(( $(now_seconds) - when ))
    if (( age < _min_interval )); then
      printf '%s' "the tracker was called ${age}s ago, and calls are limited to one every ${_min_interval}s"
      return 1
    fi
  fi
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 when the session is current or was updated, 1 when the tracker refused or the setup is unusable.
########################################
main() {
  parse_options "$@"
  setup_colors "${_no_color}"
  [[ "${_no_color}" == true ]] && disable_log_colors
  [[ "${_quiet}" == true ]] && _LOG_QUIET=true

  load_optional_config >/dev/null || exit 1
  apply_config || exit 1

  if ! command -v curl &>/dev/null; then
    log_error "'curl' was not found, and the tracker is reached over HTTP."
    exit 1
  fi
  if ! command -v jq &>/dev/null; then
    log_error "'jq' was not found, and the tracker answers in JSON."
    exit 1
  fi

  if [[ "${_status}" == true ]]; then
    print_status
    exit 0
  fi

  if ! prepare_state_dir; then
    log_error "Could not create the state directory '${_state_dir}'."
    exit 1
  fi

  local address
  address="$(current_address)"
  log_debug "Address according to ${_ip_service:-nothing}: ${address:-unknown}"

  local reason=""
  if ! reason="$(should_call "${address}")"; then
    log_info "Nothing to do: ${reason}."
    exit 0
  fi

  if [[ "${_dry_run}" == true ]]; then
    log_info "Would ask the tracker to point the session at ${address:-this machine}."
    exit 0
  fi

  seed_jar || exit 1

  local reply status body
  reply="$(call_endpoint)"
  status="${reply%%$'\t'*}"
  body="${reply#*$'\t'}"
  log_debug "The tracker answered ${status}."

  if [[ "${status}" == "no-response" || -z "${body}" ]]; then
    log_error "No answer from the tracker. It may be down, or the network may be."
    exit 1
  fi

  local parsed
  parsed="$(printf '%s' "${body}" | jq -r '[(.Success | tostring), (.msg // ""), (.ip // ""), (.ASN // "" | tostring), (.AS // "")] | @tsv' 2>/dev/null || true)"
  if [[ -z "${parsed}" ]]; then
    log_error "The tracker answered ${status} with something that is not the JSON this expects."
    exit 1
  fi

  local success message reported_ip asn as_name
  IFS=$'\t' read -r success message reported_ip asn as_name <<<"${parsed}"

  if [[ "${success}" != "true" ]]; then
    explain_refusal "${message}" "${asn:+ASN ${asn}${as_name:+ (${as_name})}}"
    # Recorded even on refusal: the next run must not retry immediately, since a refusal that needs a
    # settings change will refuse just as fast the second time. The message is kept too, so --status can
    # answer why a run from a timer has been quiet.
    now_seconds > "${_last_call_file}"
    printf 'refused: %s' "${message}" > "${_last_result_file}"
    exit 1
  fi

  now_seconds > "${_last_call_file}"
  printf 'accepted: %s' "${message:-done}" > "${_last_result_file}"
  if [[ -n "${reported_ip}" ]]; then
    printf '%s' "${reported_ip}" > "${_last_ip_file}"
  fi
  chmod 600 "${_jar}" "${_last_call_file}" "${_last_ip_file}" "${_last_result_file}" 2>/dev/null || true

  local where="${reported_ip:-this machine}"
  [[ -n "${asn}" ]] && where+=" on ASN ${asn}${as_name:+ (${as_name})}"
  log_info "The session now points at ${where}. The tracker said: ${message:-done}."
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

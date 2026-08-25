#!/usr/bin/env bash
#
# Reports the SMART findings that actually predict a disk failing.
#
# A drive's own health verdict is close to useless on its own: it stays "PASSED" until the drive has all
# but given up. What predicts a failure is a handful of attributes — sectors reallocated, sectors pending
# reallocation, sectors that could not be read during a scan — and each drive's own failure thresholds
# for everything else it measures. This reads all of that and says what is worth acting on, so it can be
# run from cron and be silent when there is nothing to say.
#
# Two decisions here came from measurement rather than documentation. `smartctl --scan` suggests a device
# type per device, and on a SATA disk behind a common controller that suggestion is `scsi`, which returns
# no model and no attributes at all; letting smartctl auto-detect returns everything, so the scan is used
# for the device list and its type only as a fallback. And smartctl's exit status is a bit field in which
# a failing disk sets a bit — so a non-zero status is not evidence that the read failed, and only an
# unparseable document is.
#
# Usage:
#   ./smart-check.sh [OPTIONS] [DEVICE...]

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
# shellcheck source=../../lib/program.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/program.sh"
# @include ../../lib/program.sh

# --- Environment seams ---
# smartctl itself, so a test can describe a fleet of disks rather than read the one it is running on, and
# the privilege escalation, because a test needs the double's output to come back rather than be swallowed
# by whatever stands in for sudo.
: "${SMARTCTL_BIN:=smartctl}"
: "${SUDO_BIN:=sudo}"
readonly SMARTCTL_BIN SUDO_BIN

# --- Global State (option flags) ---
_no_color=false
_quiet=false
_wear_opt=""
_temp_opt=""
_crc_opt=""
_devices=()

# Resolved settings, filled in by apply_config.
_wear_min=20
_temp_max=60
_crc_max=0

# Serial numbers already reported, so a disk reachable by two paths is examined once.
_seen_serials=()

# Outcome counters, reported by print_summary and reflected in the exit status.
_checked=0
_failing=0
_warned=0
_unreadable=0

# --- Color Variables (set by setup_colors "${_no_color}") ---

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME, and the threshold defaults.
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [DEVICE...]

Report the SMART findings worth acting on, for the named devices or for every
device smartctl can find.

Options:
  -w, --wear PERCENT  Warn below this much rated life left on a solid-state drive (default ${_wear_min}).
  -t, --temp CELSIUS  Warn above this temperature (default ${_temp_max}).
  -c, --crc COUNT     Warn above this many interface CRC errors (default ${_crc_max}).
  -q, --quiet         Print only devices with something to report, for cron.
  -C, --no-color      Disable colored output.
  -d, --debug         Enable verbose debug logging.
  -h, --help          Show this help message.

Reading SMART data needs root; sudo is used when this is not already root.

Exit status is 0 when every device is healthy, 1 when one is failing, and 2 when
the only findings were warnings.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _wear_opt, _temp_opt, _crc_opt, _quiet, _no_color, _devices
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -w|--wear)
        require_option_value "$@"
        _wear_opt="$2"
        shift 2
        ;;
      -t|--temp)
        require_option_value "$@"
        _temp_opt="$2"
        shift 2
        ;;
      -c|--crc)
        require_option_value "$@"
        _crc_opt="$2"
        shift 2
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
      --)
        shift
        _devices+=("$@")
        break
        ;;
      -*)
        die_usage "Unknown option '$1'."
        ;;
      *)
        _devices+=("$1")
        shift
        ;;
    esac
  done
}

########################################
# Resolves the thresholds from the options and the config file, the option winning.
# Globals:
#   WEAR_MIN, TEMP_MAX, CRC_MAX, DEVICES, and the resolved globals.
# Arguments:
#   None
# Returns:
#   0 when the settings are usable, 1 otherwise.
########################################
apply_config() {
  _wear_min="${_wear_opt:-${WEAR_MIN:-${_wear_min}}}"
  _temp_max="${_temp_opt:-${TEMP_MAX:-${_temp_max}}}"
  _crc_max="${_crc_opt:-${CRC_MAX:-${_crc_max}}}"

  # A configured device list applies only when none were named on the command line, which is what lets a
  # cron entry hold the list and a person still ask about one disk.
  if (( ${#_devices[@]} == 0 )) && declare -p DEVICES &>/dev/null && (( ${#DEVICES[@]} > 0 )); then
    _devices=("${DEVICES[@]}")
  fi

  local name value
  for name in _wear_min _temp_max _crc_max; do
    value="${!name}"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
      log_error "The ${name#_} threshold must be a whole number, got '${value}'."
      return 1
    fi
  done
}

########################################
# Prints the smartctl command, prefixed with sudo when this is not already root.
# Globals:
#   SMARTCTL_BIN, SUDO_BIN, EUID
# Arguments:
#   None
# Outputs:
#   The command words, one per line.
########################################
smartctl_command() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf '%s\n' "${SUDO_BIN}"
  fi
  printf '%s\n' "${SMARTCTL_BIN}"
}

########################################
# Prints every device smartctl can find, as "path<TAB>suggested-type".
#
# The suggested type is carried along but not used unless auto-detection fails: on a SATA disk behind a
# common controller the suggestion is `scsi`, and asking for that returns a document with no model and no
# attributes in it.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   One device per line.
########################################
scan_devices() {
  local -a command=()
  local word
  while IFS= read -r word; do
    command+=("${word}")
  done < <(smartctl_command)

  "${command[@]}" --scan 2>/dev/null | awk '$1 ~ /^\// { type = ""; for (i = 2; i < NF; i++) if ($i == "-d") type = $(i + 1); print $1 "\t" type }'
}

########################################
# Prints one device's SMART document, as JSON.
#
# Auto-detection first, and the scanned suggestion only if that produced nothing usable. smartctl's exit
# status is ignored on purpose: it is a bit field, and one of its bits means the disk is failing — the
# very case this must not discard.
# Globals:
#   None
# Arguments:
#   device: The device path.
#   suggested_type: The type from the scan, possibly empty.
# Outputs:
#   The JSON document, or nothing when the device could not be read.
########################################
device_json() {
  local device="$1" suggested_type="${2:-}"
  local -a command=()
  local word
  while IFS= read -r word; do
    command+=("${word}")
  done < <(smartctl_command)

  local json
  json="$("${command[@]}" -j -H -A -i "${device}" 2>/dev/null || true)"
  if usable_json "${json}"; then
    printf '%s' "${json}"
    return 0
  fi

  if [[ -n "${suggested_type}" ]]; then
    log_debug "Auto-detection told us nothing about ${device}; retrying as -d ${suggested_type}."
    json="$("${command[@]}" -j -H -A -i -d "${suggested_type}" "${device}" 2>/dev/null || true)"
    if usable_json "${json}"; then
      printf '%s' "${json}"
      return 0
    fi
  fi

  return 1
}

########################################
# Reports whether a smartctl document says anything about a drive.
#
# A document that parses but names no model and carries no attributes is what an unsupported device type
# produces, and treating it as a healthy disk would report a fleet as fine without having read any of it.
# Globals:
#   None
# Arguments:
#   json: The document.
# Returns:
#   0 when the document describes a drive, 1 otherwise.
########################################
usable_json() {
  [[ -n "$1" ]] || return 1
  printf '%s' "$1" | jq -e 'has("model_name") or (.ata_smart_attributes.table? | length > 0) or has("nvme_smart_health_information_log")' &>/dev/null
}

########################################
# Prints the findings for one device document, as "level<TAB>message" lines.
# Globals:
#   _wear_min, _temp_max, _crc_max
# Arguments:
#   json: The device document.
# Outputs:
#   One finding per line; nothing for a healthy drive.
########################################
findings_for() {
  local prog
  prog=$(load_program smart-findings.jq)  # @embed smart-findings.jq
  local -a args=(-r)
  # As JSON numbers rather than strings, which is what lets the filter compare them; apply_config has
  # already refused anything that is not a whole number.
  args+=(--argjson wear_min "${_wear_min}")
  args+=(--argjson temp_max "${_temp_max}")
  args+=(--argjson crc_max "${_crc_max}")
  printf '%s' "$1" | jq "${args[@]}" "${prog}" 2>/dev/null
}

########################################
# Prints the one-line description of a device: what it is, and how warm.
# Globals:
#   Color globals.
# Arguments:
#   json: The device document.
# Outputs:
#   The description.
########################################
describe() {
  printf '%s' "$1" | jq -r '[(.model_name // "unknown model"), (.serial_number // "no serial"), (if (.rotation_rate // 0) == 0 then "solid state" else "\(.rotation_rate) rpm" end), (if .temperature.current then "\(.temperature.current)C" else "temperature unknown" end)] | join(", ")' 2>/dev/null
}

########################################
# Examines one device and reports on it.
# Globals:
#   Counters, _seen_serials, _quiet, and color globals.
# Arguments:
#   device: The device path.
#   suggested_type: The type from the scan, possibly empty.
########################################
check_device() {
  local device="$1" suggested_type="${2:-}"

  local json
  if ! json="$(device_json "${device}" "${suggested_type}")"; then
    log_warn "Could not read SMART data from ${device}."
    _unreadable=$(( _unreadable + 1 ))
    return 0
  fi

  # A disk reachable by two paths would otherwise be reported, and counted, twice.
  local serial
  serial="$(printf '%s' "${json}" | jq -r '.serial_number // empty' 2>/dev/null)"
  if [[ -n "${serial}" ]]; then
    local seen
    for seen in "${_seen_serials[@]+"${_seen_serials[@]}"}"; do
      if [[ "${seen}" == "${serial}" ]]; then
        log_debug "${device} is the same drive as one already examined (serial ${serial})."
        return 0
      fi
    done
    _seen_serials+=("${serial}")
  fi

  _checked=$(( _checked + 1 ))

  local -a findings=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && findings+=("${line}")
  done < <(findings_for "${json}")

  local worst="ok"
  local level message
  for line in "${findings[@]+"${findings[@]}"}"; do
    level="${line%%$'\t'*}"
    [[ "${level}" == "fail" ]] && worst="fail"
    [[ "${level}" == "warn" && "${worst}" != "fail" ]] && worst="warn"
  done

  case "${worst}" in
    fail) _failing=$(( _failing + 1 )) ;;
    warn) _warned=$(( _warned + 1 )) ;;
  esac

  if [[ "${worst}" == "ok" && "${_quiet}" == true ]]; then
    return 0
  fi

  local header
  header="${device}: $(describe "${json}")"
  case "${worst}" in
    fail) printf '%s\n' "${_C_BOLD}${_C_RED}${header}${_C_RESET}" ;;
    warn) printf '%s\n' "${_C_BOLD}${_C_YELLOW}${header}${_C_RESET}" ;;
    *) printf '%s\n' "${_C_GREEN}${header}${_C_RESET}" ;;
  esac

  for line in "${findings[@]+"${findings[@]}"}"; do
    level="${line%%$'\t'*}"
    message="${line#*$'\t'}"
    if [[ "${level}" == "fail" ]]; then
      printf '%s\n' "  ${_C_RED}FAILING: ${message}${_C_RESET}"
    else
      printf '%s\n' "  ${_C_YELLOW}warning: ${message}${_C_RESET}"
    fi
  done

  [[ "${worst}" == "ok" ]] && printf '%s\n' "  ${_C_DIM}nothing to report${_C_RESET}"
  return 0
}

########################################
# Prints what the run found.
# Globals:
#   Counters, _quiet, and color globals.
# Arguments:
#   None
########################################
print_summary() {
  if [[ "${_quiet}" == true && "${_failing}" -eq 0 && "${_warned}" -eq 0 && "${_unreadable}" -eq 0 ]]; then
    return 0
  fi

  local line="${_checked} device(s) examined"
  (( _failing > 0 )) && line+=", ${_failing} failing"
  (( _warned > 0 )) && line+=", ${_warned} with warnings"
  (( _unreadable > 0 )) && line+=", ${_unreadable} unreadable"
  if (( _failing == 0 && _warned == 0 && _unreadable == 0 )); then
    line+=", all healthy"
  fi
  printf '\n%s\n' "${_C_BOLD}${_C_BRIGHT_GREEN}${line}.${_C_RESET}"
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 when every device is healthy, 1 when one is failing or unreadable, 2 for warnings alone.
########################################
main() {
  parse_options "$@"
  setup_colors "${_no_color}"
  [[ "${_no_color}" == true ]] && disable_log_colors

  load_optional_config >/dev/null || exit 1
  apply_config || exit 1

  if ! command -v "${SMARTCTL_BIN}" &>/dev/null; then
    log_error "'${SMARTCTL_BIN}' was not found. Install smartmontools."
    exit 1
  fi
  if ! command -v jq &>/dev/null; then
    log_error "'jq' was not found, and the SMART data is read as JSON."
    exit 1
  fi

  if (( ${#_devices[@]} > 0 )); then
    local device
    for device in "${_devices[@]}"; do
      check_device "${device}" ""
    done
  else
    local line path type
    while IFS=$'\t' read -r path type; do
      [[ -n "${path}" ]] || continue
      check_device "${path}" "${type}"
    done < <(scan_devices)
  fi

  if (( _checked == 0 && _unreadable == 0 )); then
    log_error "No SMART-capable device was found. Name one explicitly, or check that this is running as root."
    exit 1
  fi

  print_summary

  (( _failing == 0 && _unreadable == 0 )) || exit 1
  (( _warned == 0 )) || exit 2
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

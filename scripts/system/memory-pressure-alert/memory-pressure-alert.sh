#!/usr/bin/env bash
#
# memory-pressure-alert.sh — warn while a Mac is filling up, not once it has
# already ground to a halt.
#
# macOS does not run out of memory so much as it slides: pages compress, then
# swap grows, and the machine stays usable for days. Then free swap reaches zero
# and everything stalls at once — a load average in the hundreds, every process
# blocked on memory, and no single culprit visible in Activity Monitor.
#
# "Memory used" cannot warn about that, because it is pinned near the installed
# total at all times. The numbers that move are:
#
#   * swap in use — the leading indicator. It accrues over days of uptime and is
#     the only one that is near zero on a healthy machine, so a modest threshold
#     gives days of notice.
#   * free-memory percentage (kern.memorystatus_level) — what the kernel itself
#     watches. It falls as the stall approaches.
#   * the compressor — how much has been squeezed rather than paged out.
#
# The alert names the heaviest applications, and it measures them by resident
# plus *compressed* memory. Resident size alone is actively misleading here: a
# browser holding tens of gigabytes across dozens of helper processes reports a
# few hundred megabytes each, so the real cause looks innocent while some idle
# background process looks like the problem. Totals are aggregated per
# application, since blame belongs to the app, not to its 56th renderer.
#
# Designed to be run from a launchd agent every few minutes. It raises nothing
# and exits 0 while the machine is healthy, so it can be left running
# indefinitely.
#
# Usage:
#   ./memory-pressure-alert.sh [OPTIONS]

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

# --- Constants ---
# The three readings come from the environment when set. They are live kernel
# state that cannot be conjured on demand, so pointing them at fixtures is what
# makes the threshold logic and the reporting testable at all; unset, they run
# the real commands.
: "${SWAPUSAGE_CMD:=sysctl -n vm.swapusage}"
: "${PRESSURE_CMD:=sysctl -n kern.memorystatus_level}"
: "${VMSTAT_CMD:=vm_stat}"
: "${PS_CMD:=ps -Ao rss=,comm=}"
: "${TOP_CMD:=top -l 1 -stats command,mem,cmprs -n 400}"
: "${NOTIFY_CMD:=osascript}"
readonly SWAPUSAGE_CMD PRESSURE_CMD VMSTAT_CMD PS_CMD TOP_CMD NOTIFY_CMD

# How many applications the alert names. Enough to identify the cause without
# turning a notification into a list nobody reads on a lock screen.
readonly TOP_OFFENDERS=3

# --- Configuration Defaults ---
# Swap first: on a healthy machine it is near zero, so any sustained growth is
# already news. The pressure figure is a confirming signal rather than an early
# one — by the time free memory is low, the slide is under way.
SWAP_WARN_MB=2048
PRESSURE_WARN_PERCENT=25
COMPRESSOR_WARN_MB=8192

########################################
# Print the usage text.
# Outputs:
#   Writes the usage message to stdout.
########################################
show_usage() {
  cat <<USAGE
${_C_BOLD}Usage:${_C_RESET} ${SCRIPT_NAME} [OPTIONS]

Warns while a Mac is filling up — growing swap and falling free memory — rather
than once it has already stalled. Names the heaviest applications by resident
plus compressed memory, aggregated per application.

Raises nothing and exits 0 while healthy, so it suits a launchd agent.

${_C_BOLD}Options:${_C_RESET}
  -s, --swap-mb MB        Warn at this much swap in use (default: ${SWAP_WARN_MB})
  -p, --pressure PERCENT  Warn when free memory falls below this (default: ${PRESSURE_WARN_PERCENT})
  -c, --compressor MB     Warn at this much compressed memory (default: ${COMPRESSOR_WARN_MB})
  -r, --report            Print the current readings and exit, whatever their values
  -n, --no-notify         Print to stdout instead of sending a notification
      --no-color          Disable coloured output
  -d, --debug             Enable debug logging
  -h, --help              Show this help message

${_C_BOLD}Exit Codes:${_C_RESET}
  0  Healthy, or a report was printed
  1  Usage error
  2  A threshold was crossed and an alert was raised
USAGE
}

########################################
# Read swap in use, in whole MB.
# Globals:
#   SWAPUSAGE_CMD
# Outputs:
#   Writes the integer MB to stdout, or 0 when the figure cannot be read.
########################################
read_swap_mb() {
  local raw
  raw=$(${SWAPUSAGE_CMD} 2>/dev/null) || raw=""
  # vm.swapusage reports "total = 1024.00M used = 512.25M free = 511.75M".
  # Sizes carry an M suffix in every macOS release that has this sysctl, so the
  # suffix is stripped rather than interpreted.
  local used
  used=$(printf '%s\n' "${raw}" | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  [[ -z ${used} ]] && { printf '0\n'; return 0; }
  printf '%.0f\n' "${used}"
}

########################################
# Read the kernel's free-memory percentage.
# Globals:
#   PRESSURE_CMD
# Outputs:
#   Writes the integer percentage to stdout, or 100 when it cannot be read.
########################################
read_free_percent() {
  local level
  level=$(${PRESSURE_CMD} 2>/dev/null) || level=""
  # A missing reading must not look like an emergency, so it reads as healthy —
  # this runs unattended, and a false alarm every few minutes trains the user to
  # ignore the real one.
  [[ ${level} =~ ^[0-9]+$ ]] || { printf '100\n'; return 0; }
  printf '%s\n' "${level}"
}

########################################
# Read compressed memory, in whole MB.
# Globals:
#   VMSTAT_CMD
# Outputs:
#   Writes the integer MB to stdout, or 0 when it cannot be read.
########################################
read_compressor_mb() {
  local out pages page_size
  out=$(${VMSTAT_CMD} 2>/dev/null) || out=""
  pages=$(printf '%s\n' "${out}" \
    | sed -n 's/^Pages occupied by compressor: *\([0-9]*\)\..*$/\1/p')
  [[ -z ${pages} ]] && { printf '0\n'; return 0; }
  # vm_stat states its own page size, which differs between Intel and Apple
  # silicon; reading it back avoids assuming either.
  page_size=$(printf '%s\n' "${out}" \
    | sed -n 's/^Mach Virtual Memory Statistics: (page size of \([0-9]*\) bytes).*$/\1/p')
  [[ -z ${page_size} ]] && page_size=16384
  printf '%s\n' $(( pages * page_size / 1048576 ))
}

########################################
# List the heaviest applications by resident plus compressed memory.
# Globals:
#   TOP_CMD, TOP_OFFENDERS
# Outputs:
#   Writes "<MB> <processes> <app>" lines, heaviest first.
########################################
read_top_offenders() {
  local prog
  prog=$(load_program offenders.awk)  # @embed offenders.awk
  ${TOP_CMD} 2>/dev/null \
    | awk -v want="${TOP_OFFENDERS}" "${prog}" \
    | sort -rn \
    | head -n "${TOP_OFFENDERS}"
}

########################################
# Format the readings as a single human-readable line.
# Arguments:
#   $1 - swap MB, $2 - free percent, $3 - compressor MB
# Outputs:
#   Writes the summary to stdout.
########################################
format_readings() {
  printf 'swap %s MB · free %s%% · compressed %s MB\n' "$1" "$2" "$3"
}

########################################
# Deliver a message, as a notification or on stdout.
# Globals:
#   NOTIFY_CMD, SCRIPT_NAME
# Arguments:
#   $1 - the message body
#   $2 - "true" to print instead of notifying
# Returns:
#   0 always — a failed notification must not mask the condition it describes.
########################################
deliver() {
  local body=$1 print_only=$2
  if [[ ${print_only} == true ]]; then
    printf '%s\n' "${body}"
    return 0
  fi
  # A notification is best-effort: under heavy memory pressure osascript is
  # itself liable to be slow or refused, and the log line is what survives.
  ${NOTIFY_CMD} -e "display notification \"${body//\"/}\" with title \"Memory pressure\"" \
    >/dev/null 2>&1 || log_error "Could not post the notification: ${body}"
  return 0
}

########################################
# Main entry point.
# Globals:
#   All configuration and command globals.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 healthy or reported, 2 alert raised. Usage errors exit 1 via die_usage.
########################################
main() {
  local opt_report=false opt_no_notify=false wanted_color=auto
  # CLI values are held separately from the config globals and applied after the
  # config is read. Writing them straight into the globals would let the config
  # file silently overwrite an explicit flag, since it is loaded afterwards.
  local opt_swap="" opt_pressure="" opt_compressor=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--swap-mb)
        require_option_value "$1" "${2:-}"
        opt_swap=$2
        shift 2
        ;;
      -p|--pressure)
        require_option_value "$1" "${2:-}"
        opt_pressure=$2
        shift 2
        ;;
      -c|--compressor)
        require_option_value "$1" "${2:-}"
        opt_compressor=$2
        shift 2
        ;;
      -r|--report)
        opt_report=true
        shift
        ;;
      -n|--no-notify)
        opt_no_notify=true
        shift
        ;;
      --no-color)
        wanted_color=never
        shift
        ;;
      -d|--debug)
        enable_debug_mode
        shift
        ;;
      -h|--help)
        setup_colors "${wanted_color}"
        show_usage
        return 0
        ;;
      *)
        setup_colors "${wanted_color}"
        die_usage "Unknown option '$1'."
        ;;
    esac
  done

  setup_colors "${wanted_color}"
  load_optional_config
  # Explicit flags win over the config file.
  [[ -n ${opt_swap} ]] && SWAP_WARN_MB=${opt_swap}
  [[ -n ${opt_pressure} ]] && PRESSURE_WARN_PERCENT=${opt_pressure}
  [[ -n ${opt_compressor} ]] && COMPRESSOR_WARN_MB=${opt_compressor}

  local swap_mb free_percent compressor_mb readings
  swap_mb=$(read_swap_mb)
  free_percent=$(read_free_percent)
  compressor_mb=$(read_compressor_mb)
  readings=$(format_readings "${swap_mb}" "${free_percent}" "${compressor_mb}")
  log_debug "${readings}"

  if [[ ${opt_report} == true ]]; then
    printf '%s\n' "${readings}"
    read_top_offenders | while read -r mb procs app; do
      printf '  %6s MB  %3s proc  %s\n' "${mb}" "${procs}" "${app}"
    done
    return 0
  fi

  local -a reasons=()
  (( swap_mb >= SWAP_WARN_MB )) && reasons+=("swap ${swap_mb} MB")
  (( free_percent <= PRESSURE_WARN_PERCENT )) && reasons+=("only ${free_percent}% free")
  (( compressor_mb >= COMPRESSOR_WARN_MB )) && reasons+=("${compressor_mb} MB compressed")

  if (( ${#reasons[@]} == 0 )); then
    log_debug "Healthy — no threshold crossed."
    return 0
  fi

  local offenders
  # Named in the alert because identifying the cause is the whole point: without
  # it the user is told the machine is filling up and left to guess by what.
  offenders=$(read_top_offenders | awk '{printf "%s %.1f GB; ", $3, $1/1024}' | sed 's/; $//')
  local body
  body=$(printf '%s. Heaviest: %s' \
    "$(IFS=', '; printf '%s' "${reasons[*]}")" "${offenders:-unknown}")
  log_error "${body}"
  deliver "${body}" "${opt_no_notify}"
  # 2 rather than 1, matching dmarc-report: 1 is what cli.sh's die_usage exits for
  # a usage error, so a raised condition needs its own code to stay distinguishable.
  return 2
}

# Guarded so the test harness can source this file and call individual functions;
# an unguarded call would run the whole tool the moment it is sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

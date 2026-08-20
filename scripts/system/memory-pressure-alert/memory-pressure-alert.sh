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
# Free memory is useless as a signal here, because macOS keeps almost none: it
# lends the rest to the file cache and reclaims it on demand, so "free" sits near
# zero on a perfectly healthy machine. The numbers that move are:
#
#   * swap in use — the leading indicator. It accrues over days of uptime and is
#     the only one that is near zero on a healthy machine, so a modest threshold
#     gives days of notice.
#   * memory used — counted the way Activity Monitor and Stats count it, as
#     anonymous plus wired plus compressed pages, with the file cache and
#     purgeable pages excluded because the kernel can take those back at will.
#     A naive total-minus-free reads ~99% at all times and says nothing.
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
: "${MEMSIZE_CMD:=sysctl -n hw.memsize}"
: "${VMSTAT_CMD:=vm_stat}"
: "${PS_CMD:=ps -Ao rss=,comm=}"
: "${TOP_CMD:=top -l 1 -stats command,mem,cmprs -n 400}"
: "${NOTIFY_CMD:=osascript}"
# The launchd installation targets are seams for the same reason: --install
# writes into the user's real agent directory and loads it for real, which a test
# must be able to redirect somewhere harmless.
: "${LAUNCHCTL_CMD:=launchctl}"
: "${LAUNCH_AGENTS_DIR:=${HOME}/Library/LaunchAgents}"
: "${AGENT_LOG_DIR:=${HOME}/Library/Logs}"
readonly SWAPUSAGE_CMD MEMSIZE_CMD VMSTAT_CMD PS_CMD TOP_CMD NOTIFY_CMD
readonly LAUNCHCTL_CMD LAUNCH_AGENTS_DIR AGENT_LOG_DIR

# How many applications the alert names. Enough to identify the cause without
# turning a notification into a list nobody reads on a lock screen.
readonly TOP_OFFENDERS=3

# launchd identifies an agent by a reverse-DNS label, which is also the plist's
# basename, so the two can never drift apart.
readonly AGENT_LABEL="si.merhar.memory-pressure-alert"

# How often the installed agent runs. Swap accrues over days, so five minutes is
# far more often than the signal changes — chosen to keep the notice prompt
# without the check ever being noticeable.
readonly DEFAULT_INTERVAL_SECONDS=300

# --- Configuration Defaults ---
# Swap first: on a healthy machine it is near zero, so any sustained growth is
# already news. Used memory is the confirming signal — it climbs through the day
# and sits high on a machine that is coping, so only a high threshold means
# trouble.
SWAP_WARN_MB=2048
USED_WARN_PERCENT=85
COMPRESSOR_WARN_MB=8192

# The threshold's meaning inverted when the reading became "used" rather than "free", so an old
# setting left in a config file would mean the opposite of what its author intended — 25 would read
# as "warn above 25% used", which is always. The old name is therefore refused rather than honoured.
readonly RETIRED_CONFIG_KEY="PRESSURE_WARN_PERCENT"

########################################
# Print the usage text.
# Outputs:
#   Writes the usage message to stdout.
########################################
show_usage() {
  cat <<USAGE
${_C_BOLD}Usage:${_C_RESET} ${SCRIPT_NAME} [OPTIONS]

Warns while a Mac is filling up — growing swap and rising memory use — rather
than once it has already stalled. Names the heaviest applications by resident
plus compressed memory, aggregated per application.

Raises nothing and exits 0 while healthy, so it suits a launchd agent.

${_C_BOLD}Options:${_C_RESET}
  -s, --swap-mb MB        Warn at this much swap in use (default: ${SWAP_WARN_MB})
  -u, --used PERCENT      Warn at this much memory in use (default: ${USED_WARN_PERCENT})
  -c, --compressor MB     Warn at this much compressed memory (default: ${COMPRESSOR_WARN_MB})
  -r, --report            Print the current readings and exit, whatever their values
  -n, --no-notify         Print to stdout instead of sending a notification
      --install           Install a launchd agent that runs this periodically
      --uninstall         Remove the launchd agent
  -i, --interval SECONDS  How often the agent runs, with --install (default: ${DEFAULT_INTERVAL_SECONDS})
      --no-color          Disable coloured output
  -d, --debug             Enable debug logging
  -h, --help              Show this help message

${_C_BOLD}Exit Codes:${_C_RESET}
  0  Healthy, a report was printed, or the agent was installed or removed
  1  Usage error, or the agent could not be loaded
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
# Read used memory as a percentage of the total.
#
# Counted the way Activity Monitor and Stats count it: anonymous, wired and
# compressed pages, with the file cache and purgeable pages subtracted because the
# kernel reclaims those on demand and they are not a shortage. A plain
# total-minus-free would read about 99% on any healthy Mac and never move.
#
# All of it comes from one vm_stat call, so every figure describes the same instant
# — sampling them separately would let the parts disagree and push the total past
# 100%.
# Globals:
#   VMSTAT_CMD, MEMSIZE_CMD
# Outputs:
#   Writes the integer percentage to stdout, or 0 when it cannot be read.
########################################
read_used_percent() {
  local out total
  out=$(${VMSTAT_CMD} 2>/dev/null) || out=""
  total=$(${MEMSIZE_CMD} 2>/dev/null) || total=""
  # A missing reading must not look like an emergency: this runs unattended, and a
  # false alarm every few minutes teaches the user to ignore the real one.
  [[ ${total} =~ ^[0-9]+$ ]] && (( total > 0 )) || { printf '0\n'; return 0; }

  local prog
  prog=$(load_program used-percent.awk)  # @embed used-percent.awk
  printf '%s\n' "${out}" | awk -v total="${total}" "${prog}"
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
#   $1 - swap MB, $2 - used percent, $3 - compressor MB
# Outputs:
#   Writes the summary to stdout.
########################################
format_readings() {
  printf 'swap %s MB · used %s%% · compressed %s MB\n' "$1" "$2" "$3"
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
# Print the path of the launchd agent's plist.
# Globals:
#   LAUNCH_AGENTS_DIR, AGENT_LABEL
# Outputs:
#   Writes the path to stdout.
########################################
agent_plist_path() {
  printf '%s/%s.plist\n' "${LAUNCH_AGENTS_DIR}" "${AGENT_LABEL}"
}

########################################
# Print the path launchd should invoke.
#
# The directory is resolved physically but a symlinked file is left as it is: a
# Homebrew install is a symlink into the versioned Cellar, and an agent pointed at
# the stable symlink keeps working across upgrades, where one pointed into the
# Cellar breaks at the next version bump.
# Outputs:
#   Writes the absolute path to stdout.
########################################
self_path() {
  printf '%s/%s\n' "$(cd "$(dirname "$0")" && pwd -P)" "$(basename "$0")"
}

########################################
# Escape a string for inclusion in XML character data.
#
# Paths reach the plist from $0 and $HOME, so they are not under this script's control: an ampersand
# in a directory name is legal on macOS and would otherwise produce a plist that is not well-formed,
# which launchd rejects wholesale rather than reading around.
# Arguments:
#   $1 - the string to escape
# Outputs:
#   Writes the escaped string to stdout.
########################################
xml_escape() {
  # Ampersand first: escaping it after the others would corrupt the entities they introduce.
  local out=${1//&/\&amp;}
  out=${out//</\&lt;}
  printf '%s\n' "${out//>/\&gt;}"
}

########################################
# Render the launchd agent plist.
#
# Thresholds are deliberately not passed as arguments: the agent reads the config
# file like any other invocation, so tuning one is editing that file rather than
# rewriting and reloading an agent. Output is redirected to a log file because a
# launchd agent's stdout and stderr are otherwise discarded, which leaves "it
# never warned me" impossible to investigate.
# Globals:
#   AGENT_LABEL, AGENT_LOG_DIR
# Arguments:
#   $1 - absolute path to the executable
#   $2 - interval between runs, in seconds
# Outputs:
#   Writes the plist XML to stdout.
########################################
render_agent_plist() {
  local program interval log_path
  program=$(xml_escape "$1")
  interval=$2
  log_path=$(xml_escape "${AGENT_LOG_DIR}/${AGENT_LABEL}.log")
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>${AGENT_LABEL}</string>
  <key>ProgramArguments</key>  <array><string>${program}</string></array>
  <key>StartInterval</key>     <integer>${interval}</integer>
  <key>RunAtLoad</key>         <true/>
  <key>StandardOutPath</key>   <string>${log_path}</string>
  <key>StandardErrorPath</key> <string>${log_path}</string>
</dict>
</plist>
PLIST
}

########################################
# Install the launchd agent and load it.
#
# Idempotent, so reinstalling is how the interval is changed: an already-loaded
# agent keeps running with the plist it was loaded from, so the old one is
# unloaded before the new one is loaded rather than only rewritten on disk.
# Globals:
#   LAUNCHCTL_CMD, LAUNCH_AGENTS_DIR, AGENT_LOG_DIR, AGENT_LABEL
# Arguments:
#   $1 - interval between runs, in seconds
# Returns:
#   0 on success, 1 if launchd refused to load the agent.
########################################
install_agent() {
  local interval=$1 plist program
  plist=$(agent_plist_path)
  program=$(self_path)

  mkdir -p "${LAUNCH_AGENTS_DIR}" "${AGENT_LOG_DIR}"
  render_agent_plist "${program}" "${interval}" >"${plist}"

  # Absent on a first install, so this failing is the normal case and says
  # nothing about whether the load below will succeed.
  ${LAUNCHCTL_CMD} unload "${plist}" >/dev/null 2>&1 || true

  if ! ${LAUNCHCTL_CMD} load "${plist}"; then
    log_error "Wrote ${plist}, but launchctl refused to load it."
    return 1
  fi
  log_info "Installed — runs ${program} every ${interval}s."
  log_info "Agent: ${plist}"
  log_info "Log:   ${AGENT_LOG_DIR}/${AGENT_LABEL}.log"
  return 0
}

########################################
# Unload the launchd agent and remove its plist.
# Globals:
#   LAUNCHCTL_CMD
# Returns:
#   0 always — an agent that is already absent is the desired end state.
########################################
uninstall_agent() {
  local plist
  plist=$(agent_plist_path)
  if [[ ! -f "${plist}" ]]; then
    log_info "Not installed (no ${plist})."
    return 0
  fi
  # Unloaded before the plist goes, since launchctl needs the file to identify
  # what to stop; a stale in-memory job would otherwise keep running until logout.
  ${LAUNCHCTL_CMD} unload "${plist}" >/dev/null 2>&1 || true
  rm -f "${plist}"
  log_info "Uninstalled — removed ${plist}."
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
  local opt_swap="" opt_used="" opt_compressor=""
  local opt_install=false opt_uninstall=false opt_interval=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--swap-mb)
        require_option_value "$1" "${2:-}"
        opt_swap=$2
        shift 2
        ;;
      -u|--used)
        require_option_value "$1" "${2:-}"
        opt_used=$2
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
      --install)
        opt_install=true
        shift
        ;;
      --uninstall)
        opt_uninstall=true
        shift
        ;;
      -i|--interval)
        require_option_value "$1" "${2:-}"
        opt_interval=$2
        shift 2
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

  # Handled before the config is read, because installing the agent does not
  # depend on any threshold: the agent reads the config itself at each run.
  if [[ ${opt_install} == true && ${opt_uninstall} == true ]]; then
    die_usage "--install and --uninstall cannot be combined."
  fi
  if [[ -n ${opt_interval} && ${opt_install} != true ]]; then
    die_usage "--interval applies only to --install."
  fi
  if [[ ${opt_install} == true ]]; then
    local interval=${opt_interval:-${DEFAULT_INTERVAL_SECONDS}}
    # Rejected here rather than left to launchd, which accepts a nonsensical
    # StartInterval by ignoring the key and running the agent only at load.
    [[ ${interval} =~ ^[1-9][0-9]*$ ]] \
      || die_usage "--interval must be a whole number of seconds above zero."
    if install_agent "${interval}"; then
      return 0
    fi
    return 1
  fi
  if [[ ${opt_uninstall} == true ]]; then
    uninstall_agent
    return 0
  fi

  load_optional_config

  # Said out loud rather than ignored quietly: a config written against the old free-memory threshold
  # would otherwise keep its setting silently dropped, and the user would believe a threshold was in
  # force that is not.
  if [[ -n ${!RETIRED_CONFIG_KEY:-} ]]; then
    log_error "${RETIRED_CONFIG_KEY} is no longer read — the reading is now memory *used*, so its" \
      "meaning inverted. Replace it with USED_WARN_PERCENT (default ${USED_WARN_PERCENT})."
  fi

  # Explicit flags win over the config file.
  [[ -n ${opt_swap} ]] && SWAP_WARN_MB=${opt_swap}
  [[ -n ${opt_used} ]] && USED_WARN_PERCENT=${opt_used}
  [[ -n ${opt_compressor} ]] && COMPRESSOR_WARN_MB=${opt_compressor}

  local swap_mb used_percent compressor_mb readings
  swap_mb=$(read_swap_mb)
  used_percent=$(read_used_percent)
  compressor_mb=$(read_compressor_mb)
  readings=$(format_readings "${swap_mb}" "${used_percent}" "${compressor_mb}")
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
  (( used_percent >= USED_WARN_PERCENT )) && reasons+=("${used_percent}% memory used")
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

#!/usr/bin/env bash
#
# mdcheck-progress.sh — report how far a paused MD RAID "check" has got, with a
# schedule-aware finish estimate.
#
# Debian/Ubuntu run their monthly array scrub via mdadm's `mdcheck` systemd
# units: mdcheck_start.timer kicks off a `check` on the first Sunday of the
# month and mdcheck_continue.timer resumes it for a fixed window every night,
# pausing the check (writing `idle` to sync_action) when the window closes.
#
# The catch: `/proc/mdstat` and `mdadm --detail` only show a percentage while a
# window is actively running. During the day, when the check is paused, both
# report nothing — the only record of where it stopped is the sector offset
# mdcheck saves in /var/lib/mdcheck/MD_UUID_<uuid>. This tool reads that offset
# and turns it back into a percentage.
#
# It also estimates when the check will finish. Because the scrub only advances
# during the nightly windows, a naive rate would place the finish in the middle
# of an idle day. Instead the estimate is derived entirely from state already on
# the system: the average speed WHILE CHECKING (progress so far divided by the
# active time actually elapsed inside past windows), projected across future
# windows whose length and start time are read from the systemd units. No
# history file is kept — every run recomputes from the current schedule, so if
# the schedule ever changes the estimate simply follows the new one.
#
# Assumptions (all comfortably true for a normal nightly scrub): the check speed
# is roughly uniform across the array, and the nightly windows do not overlap.
#
# Usage:
#   ./mdcheck-progress.sh [OPTIONS] [ARRAY...]
#
# ARRAY may be given as `md0` or `/dev/md0`; with none, every array is reported.

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/common.sh"
# @include ../../lib/common.sh

# --- Constants ---
# The four paths this tool reads are taken from the environment when set. They are the machine's RAID
# state, which cannot be conjured on demand, so being able to point them at a fixture tree is what makes
# the progress arithmetic and the checkpoint resolution exercisable at all; unset, they are the real ones.
: "${MDSTAT:=/proc/mdstat}"
: "${SYS_BLOCK:=/sys/block}"
: "${MDCHECK_STATE_DIR:=/var/lib/mdcheck}"
: "${MDADM_CONF:=/etc/mdadm/mdadm.conf}"
readonly MDSTAT SYS_BLOCK MDCHECK_STATE_DIR MDADM_CONF
readonly CONTINUE_TIMER="mdcheck_continue.timer"
readonly CONTINUE_SERVICE="mdcheck_continue.service"
readonly START_SERVICE="mdcheck_start.service"
# Fallback nightly window length if it cannot be read from the units (6 hours),
# matching mdadm's own MDADM_CHECK_DURATION default.
readonly DEFAULT_WINDOW_SEC=21600
readonly SECTOR_BYTES=512

# --- Option state ---
_no_color=false
declare -a _filters=()

# --- Colour palette ---
_C_RESET="" _C_BOLD="" _C_DIM="" _C_GREEN="" _C_YELLOW=""

# --- Schedule (populated once by load_schedule) ---
_window_sec="${DEFAULT_WINDOW_SEC}"  # nightly window length, seconds
_window_tod=0                        # nightly window start, seconds past midnight
_next_window=0                       # epoch of the next window start (0 if unknown)
_check_start=0                       # epoch the current month's check began (0 if unknown)

########################################
# Print usage information.
########################################
show_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [ARRAY...]

Reports the progress of an MD RAID "check" (Debian's monthly mdcheck scrub),
including while it is paused between nightly windows, with a schedule-aware
estimate of when it will finish.

ARRAY may be given as 'md0' or '/dev/md0'. With no ARRAY, every array is shown.

Options:
  -C, --no-color   Disable coloured output.
  -d, --debug      Enable verbose debug logging.
  -h, --help       Show this help and exit.
EOF
}

########################################
# Initialise the colour palette, honouring --no-color and TTY detection.
# Globals:
#   _no_color, _C_*
########################################
setup_colors() {
  if [[ "${_no_color}" == "true" || ! -t 1 ]]; then
    return
  fi
  _C_RESET=$(tput sgr0)
  _C_BOLD=$(tput bold)
  _C_DIM=$(tput setaf 8)
  _C_GREEN=$(tput setaf 2)
  _C_YELLOW=$(tput setaf 3)
}

########################################
# Parse command-line options into option-state globals.
# Globals:
#   _no_color, _filters
# Arguments:
#   All command-line arguments.
########################################
parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -C | --no-color) _no_color=true; shift ;;
      -d | --debug) enable_debug_mode; shift ;;
      -h | --help) show_usage; exit 0 ;;
      --) shift; _filters+=("$@"); break ;;
      -*) log_error "Unknown option '$1'. Use --help for usage."; exit 1 ;;
      *) _filters+=("${1#/dev/}"); shift ;;
    esac
  done
}

########################################
# Convert an epoch to a human-readable local timestamp.
# Arguments:
#   Epoch seconds.
# Outputs:
#   e.g. "Tue 2026-08-04 02:14 CEST".
########################################
fmt_ts() {
  date -d "@$1" +'%a %Y-%m-%d %H:%M %Z'
}

########################################
# Parse a date string (e.g. from `systemctl show`) into epoch seconds.
# Arguments:
#   A date string, or empty.
# Outputs:
#   Epoch seconds, or empty on failure.
########################################
to_epoch() {
  [[ -n "$1" && "$1" != "n/a" ]] || return 0
  date -d "$1" +%s 2>/dev/null || true
}

########################################
# Return the epoch of local midnight on the day containing the given epoch.
# Arguments:
#   Epoch seconds.
# Outputs:
#   Epoch of that day's 00:00:00 local time.
########################################
midnight_of() {
  date -d "$(date -d "@$1" +%F) 00:00:00" +%s
}

########################################
# Format a byte count as a human-readable binary size (KiB..TiB).
# Arguments:
#   Byte count.
# Outputs:
#   e.g. "6.77 TiB".
########################################
human_bytes() {
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.2f %s"), b, u[i]
  }'
}

########################################
# Read the configured mdcheck schedule from the systemd units into globals.
# Falls back to sane defaults when a value cannot be read, so the tool still
# works (with reduced ETA accuracy) on a non-standard setup.
# Globals:
#   _window_sec, _window_tod, _next_window, _check_start
########################################
load_schedule() {
  local duration_str
  local env_line
  env_line=$(systemctl show "${CONTINUE_SERVICE}" -p Environment --value 2>/dev/null || true)
  duration_str=$(grep -oE 'MDADM_CHECK_DURATION=[^"]+' <<<"${env_line}" | cut -d= -f2- || true)
  if [[ -n "${duration_str}" ]]; then
    local secs
    secs=$(date -u -d "1970-01-01 ${duration_str}" +%s 2>/dev/null || true)
    [[ "${secs}" =~ ^[0-9]+$ && "${secs}" -gt 0 ]] && _window_sec="${secs}"
  fi
  log_debug "window length: ${_window_sec}s"

  local next_str
  next_str=$(systemctl show "${CONTINUE_TIMER}" -p NextElapseUSecRealtime --value 2>/dev/null || true)
  _next_window=$(to_epoch "${next_str}")
  _next_window="${_next_window:-0}"
  if (( _next_window > 0 )); then
    _window_tod=$(( _next_window - $(midnight_of "${_next_window}") ))
  fi
  log_debug "next window: ${_next_window} (tod=${_window_tod}s)"

  local start_str
  start_str=$(systemctl show "${START_SERVICE}" -p ExecMainStartTimestamp --value 2>/dev/null || true)
  _check_start=$(to_epoch "${start_str}")
  _check_start="${_check_start:-0}"
  log_debug "check start: ${_check_start}"
}

########################################
# Sum the active checking time between two epochs, counting only the parts that
# fall inside nightly windows. The first window begins when the check started
# (mdcheck_start does not wait for the nightly slot); every later day's window
# begins at the configured time of day.
# Globals:
#   _window_tod, _window_sec
# Arguments:
#   check_start epoch, end epoch.
# Outputs:
#   Active seconds elapsed.
########################################
active_seconds() {
  local cs="$1" until="$2"
  local total=0 end
  end=$(( until < cs + _window_sec ? until : cs + _window_sec ))
  (( end > cs )) && total=$(( end - cs ))

  local day ws we
  day=$(( $(midnight_of "${cs}") + 86400 ))
  while (( day + _window_tod < until )); do
    ws=$(( day + _window_tod ))
    we=$(( ws + _window_sec ))
    end=$(( until < we ? until : we ))
    (( end > ws )) && total=$(( total + end - ws ))
    day=$(( day + 86400 ))
  done
  echo "${total}"
}

########################################
# Project a required amount of active checking time forward across nightly
# windows, starting no earlier than a given epoch, to a wall-clock finish time.
# Globals:
#   _window_tod, _window_sec
# Arguments:
#   Remaining active seconds, earliest epoch work can resume.
# Outputs:
#   "<finish-epoch> <windows-spanned>".
########################################
project_finish() {
  local rem="$1" t="$2"
  local windows=0 day ws we avail
  while true; do
    day=$(midnight_of "${t}")
    ws=$(( day + _window_tod ))
    we=$(( ws + _window_sec ))
    (( t < ws )) && t="${ws}"
    if (( t >= we )); then
      t=$(( day + 86400 + _window_tod ))
      continue
    fi
    windows=$(( windows + 1 ))
    avail=$(( we - t ))
    if (( rem <= avail )); then
      echo "$(( t + rem )) ${windows}"
      return
    fi
    rem=$(( rem - avail ))
    t=$(( day + 86400 + _window_tod ))
  done
}

########################################
# Resolve the mdcheck checkpoint file for an array, without needing root.
# Tries the array UUID from mdadm.conf; if exactly one array and one checkpoint
# file exist, pairs them directly as a fallback.
# Globals:
#   MDADM_CONF, MDCHECK_STATE_DIR
# Arguments:
#   Array name (e.g. md0).
# Outputs:
#   Path to the checkpoint file, or empty if none.
########################################
checkpoint_file() {
  local md="$1" uuid
  uuid=$(awk -v dev="/dev/${md}" '
    $1 == "ARRAY" && $2 == dev {
      for (i = 3; i <= NF; i++) if ($i ~ /^UUID=/) { sub(/^UUID=/, "", $i); print $i }
    }' "${MDADM_CONF}" 2>/dev/null || true)
  if [[ -n "${uuid}" && -f "${MDCHECK_STATE_DIR}/MD_UUID_${uuid}" ]]; then
    echo "${MDCHECK_STATE_DIR}/MD_UUID_${uuid}"
    return
  fi

  # Fallback: unambiguous single-array / single-file case.
  local files=("${MDCHECK_STATE_DIR}"/MD_UUID_*)
  local arrays=("${SYS_BLOCK}"/md*)
  if [[ ${#files[@]} -eq 1 && -f "${files[0]}" && ${#arrays[@]} -eq 1 ]]; then
    echo "${files[0]}"
  fi
}

########################################
# Read the current live check speed for an array from /proc/mdstat.
# Arguments:
#   Array name (e.g. md0).
# Outputs:
#   Speed in sectors/second, or empty if not currently syncing.
########################################
live_speed_sectors() {
  local md="$1" kbps
  local stanza
  stanza=$(sed -n "/^${md} :/,/^\$/p" "${MDSTAT}")
  kbps=$(grep -oE 'speed=[0-9]+K' <<<"${stanza}" | grep -oE '[0-9]+' || true)
  # An `if` (rather than `[[ ]] &&`) guarantees a zero exit even when no speed
  # is found, so the caller's `$(...)` assignment cannot trip `set -o errexit`.
  if [[ -n "${kbps}" ]]; then
    echo $(( kbps * 1024 / SECTOR_BYTES ))
  fi
}

########################################
# Print the progress report for a single array.
# Globals:
#   Schedule globals, colour palette.
# Arguments:
#   Array name (e.g. md0).
########################################
report_array() {
  local md="$1"
  local sysfs="${SYS_BLOCK}/${md}/md"
  if [[ ! -d "${sysfs}" || ! -r "${sysfs}/level" || ! -r "${sysfs}/component_size" ]]; then
    log_error "${md}: not an MD array."
    return
  fi

  local level action="idle" comp_kib
  level=$(< "${sysfs}/level")
  [[ -r "${sysfs}/sync_action" ]] && action=$(< "${sysfs}/sync_action")
  comp_kib=$(< "${sysfs}/component_size")
  local max_sectors=$(( comp_kib * 2 ))
  local total_bytes=$(( comp_kib * 1024 ))

  local header="${_C_BOLD}${md}${_C_RESET} (${level})"

  local ckpt done_sectors until_epoch active=false speed_sectors=""
  ckpt=$(checkpoint_file "${md}")

  if [[ "${action}" != "idle" && -r "${sysfs}/sync_completed" ]]; then
    # A window is running right now: take the live position and speed.
    local completed
    completed=$(< "${sysfs}/sync_completed")
    if [[ "${completed}" == *" "* ]]; then
      done_sectors="${completed%% *}"
      max_sectors="${completed##* }"
    fi
    active=true
    until_epoch=$(date +%s)
    speed_sectors=$(live_speed_sectors "${md}")
  elif [[ -n "${ckpt}" ]]; then
    # Paused between windows: the checkpoint holds the saved sector offset.
    done_sectors=$(< "${ckpt}")
    until_epoch=$(stat -c %Y "${ckpt}")
  else
    printf '%s — no check in progress\n' "${header}"
    return
  fi

  if [[ ! "${done_sectors:-}" =~ ^[0-9]+$ ]] || (( max_sectors == 0 )); then
    printf '%s — unable to read progress\n' "${header}"
    return
  fi

  local remaining=$(( max_sectors - done_sectors ))
  (( remaining < 0 )) && remaining=0

  printf '%s — %smonthly check%s\n' "${header}" "${_C_DIM}" "${_C_RESET}"

  # Progress line.
  local pct
  pct=$(awk -v d="${done_sectors}" -v m="${max_sectors}" 'BEGIN { printf "%.1f", d * 100 / m }')
  local done_h total_h
  done_h=$(human_bytes $(( done_sectors * SECTOR_BYTES )))
  total_h=$(human_bytes "${total_bytes}")
  local progress_line="${_C_BOLD}${pct}%${_C_RESET}  (${done_h} / ${total_h} per device)"
  printf '  %-12s %s\n' "progress" "${progress_line}"

  # State line.
  if [[ "${active}" == "true" ]]; then
    printf '  %-12s %schecking now%s\n' "state" "${_C_GREEN}" "${_C_RESET}"
  else
    printf '  %-12s paused (idle between nightly windows)\n' "state"
  fi

  # Rate: live when active, otherwise the average achieved while checking.
  local avg_active=""
  if (( _check_start > 0 && _check_start < until_epoch )); then
    avg_active=$(active_seconds "${_check_start}" "${until_epoch}")
  fi
  local rate_sectors="${speed_sectors}"
  if [[ -z "${rate_sectors}" && -n "${avg_active}" && "${avg_active}" -gt 0 ]]; then
    rate_sectors=$(( done_sectors / avg_active ))
  fi
  if [[ -n "${rate_sectors}" && "${rate_sectors}" -gt 0 ]]; then
    local mbps
    mbps=$(awk -v s="${rate_sectors}" -v b="${SECTOR_BYTES}" 'BEGIN { printf "%.0f", s * b / 1e6 }')
    if [[ "${active}" == "true" ]]; then
      printf '  %-12s %s MB/s (current)\n' "rate" "${mbps}"
    else
      printf '  %-12s %s MB/s while checking\n' "rate" "${mbps}"
    fi
  fi

  # Schedule line.
  if (( _next_window > 0 )); then
    local win_h
    win_h=$(awk -v s="${_window_sec}" 'BEGIN { printf "%g", s / 3600 }')
    local next_h
    next_h=$(date -d "@${_next_window}" +'%a %H:%M')
    printf '  %-12s %s h nightly, next window %s\n' "schedule" "${win_h}" "${next_h}"
  fi

  # Finish estimate.
  if (( remaining == 0 )); then
    printf '  %-12s %scomplete%s\n' "est. finish" "${_C_GREEN}" "${_C_RESET}"
    return
  fi
  if [[ -z "${rate_sectors}" || "${rate_sectors}" -le 0 ]]; then
    printf '  %-12s unavailable (cannot determine check rate)\n' "est. finish"
    return
  fi

  local rem_active=$(( remaining / rate_sectors ))
  local start_epoch
  if [[ "${active}" == "true" ]]; then
    start_epoch=$(date +%s)
  else
    start_epoch="${_next_window}"
  fi
  if (( start_epoch <= 0 )); then
    printf '  %-12s unavailable (unknown nightly schedule)\n' "est. finish"
    return
  fi

  local finish windows
  read -r finish windows < <(project_finish "${rem_active}" "${start_epoch}")
  local win_note="${windows} more window"
  (( windows != 1 )) && win_note+="s"
  local finish_h
  finish_h=$(fmt_ts "${finish}")
  printf '  %-12s %s%s%s  (%s)\n' "est. finish" "${_C_BOLD}${_C_YELLOW}" "${finish_h}" "${_C_RESET}" "${win_note}"
}

########################################
# Enumerate the arrays to report, honouring any ARRAY filters.
# Globals:
#   _filters
# Outputs:
#   One array name per line.
########################################
select_arrays() {
  if [[ ${#_filters[@]} -gt 0 ]]; then
    printf '%s\n' "${_filters[@]}"
    return
  fi
  local path
  for path in "${SYS_BLOCK}"/md*; do
    [[ -d "${path}/md" ]] && basename "${path}"
  done
}

########################################
# Main entry point.
# Arguments:
#   Command-line arguments.
########################################
main() {
  parse_options "$@"
  setup_colors

  if [[ ! -r "${MDSTAT}" ]]; then
    log_error "${MDSTAT} not found — this tool requires Linux MD RAID."
    exit 1
  fi

  local arrays
  mapfile -t arrays < <(select_arrays)
  if [[ ${#arrays[@]} -eq 0 ]]; then
    log_error "No MD arrays found."
    exit 1
  fi

  load_schedule

  local md first=true
  for md in "${arrays[@]}"; do
    [[ "${first}" == "true" ]] || printf '\n'
    first=false
    report_array "${md}"
  done
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

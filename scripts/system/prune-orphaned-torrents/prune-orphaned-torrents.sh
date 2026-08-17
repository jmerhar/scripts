#!/usr/bin/env bash
#
# Finds orphaned media files left behind by *arr hard-linking and removes the
# corresponding torrents from a Deluge daemon.
#
# Sonarr/Radarr hard-link completed downloads from a torrent temp/seed folder
# into an organised library that Plex reads from. Deleting media from Plex
# removes only the organised hard link, leaving the temp copy behind with a link
# count of 1 — wasted space that keeps seeding forever.
#
# This script scans the configured temp folders for such orphaned files, maps
# each one back to its Deluge torrent via the Deluge Web JSON-RPC API, and
# interactively prompts — per torrent — whether to remove it (and its data).
#
# Because the still-wanted files keep their second (Plex) hard link, removing a
# torrent's data only frees the orphaned temp copies; in-use media survives.
#
# Orphaned files that belong to no torrent at all (e.g. leftovers from a torrent
# that was already removed) are offered separately for direct deletion.
#
# All system-specific values (paths, exclusions, Deluge endpoint/password) live
# in a configuration file discovered next to the script or under <prefix>/etc/.
#
# Usage:
#   ./prune-orphaned-torrents.sh [-n|--dry-run] [-y|--yes] [-C|--no-color] [-d|--debug]

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../../lib/colors.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/colors.sh"
# @include ../../lib/colors.sh
# shellcheck source=../../lib/platform.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/platform.sh"
# @include ../../lib/platform.sh
# shellcheck source=../../lib/prompt.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/prompt.sh"
# @include ../../lib/prompt.sh
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
# shellcheck source=../../lib/config.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/config.sh"
# @include ../../lib/config.sh
# shellcheck source=../../lib/program.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/program.sh"
# @include ../../lib/program.sh

# --- Global State (option flags) ---
_dry_run=false
_assume_yes=false
_no_color=false

# JSON array of orphaned absolute file paths (populated by find_orphans).
_orphans_json="[]"
# JSON array of exclusion glob patterns (populated by main from EXCLUDE_PATTERNS).
_excludes_json="[]"
# Validated scan directories that actually exist (populated by prepare_scan_dirs).
_scan_dirs=()
# Path to the curl cookie jar holding the Deluge session (created in main).
_cookie_jar=""

# Holds the most recent line entered by the user (set by prompt_key).
_answer=""

# Turns a NUL-delimited stream on stdin into a JSON array of its non-empty entries. Shared by the two
# places that read NUL-delimited data, so they cannot drift apart.
readonly _JQ_SPLIT_NUL='split("\u0000") | map(select(length > 0))'

# --- Color Variables (set by setup_colors "${_no_color}") ---

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Find orphaned media files left by *arr hard-linking and remove the
corresponding torrents from Deluge. Orphaned files that belong to no torrent
are offered for direct deletion.

All settings are read from a configuration file (e.g., /etc/${SCRIPT_NAME}.conf).

Options:
  -n, --dry-run   Show what would be removed without contacting the daemon to remove anything.
  -y, --yes       Remove every matched torrent without prompting (non-interactive).
  -C, --no-color  Disable colored output.
  -d, --debug     Enable verbose debug logging.
  -h, --help      Show this help message.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _dry_run, _assume_yes, _no_color
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)
        _dry_run=true
        shift
        ;;
      -y|--yes)
        _assume_yes=true
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
      *)
        log_error "Unknown option '$1'. Use --help for usage."
        exit 1
        ;;
    esac
  done
}

########################################
# Formats a size in bytes into a human-readable string (KB, MB, GB, etc.).
# Globals:
#   None
# Arguments:
#   size: The size in bytes.
# Outputs:
#   A formatted string such as "1.23 GB".
########################################
format_size() {
  local prog
  prog=$(load_program ../../lib/format-size.awk)  # @embed ../../lib/format-size.awk
  awk -v s="${1:-0}" "${prog}"
}

########################################
# Formats a duration in seconds into a short human-readable age string.
# Globals:
#   None
# Arguments:
#   seconds: The age in seconds.
# Outputs:
#   A string such as "12d 4h" or "3h 7m".
########################################
format_age() {
  local secs="${1:-0}"
  (( secs < 0 )) && secs=0
  local days=$(( secs / 86400 ))
  local hours=$(( (secs % 86400) / 3600 ))
  if (( days > 0 )); then
    printf '%dd %dh' "${days}" "${hours}"
  else
    local mins=$(( (secs % 3600) / 60 ))
    printf '%dh %dm' "${hours}" "${mins}"
  fi
}

########################################
# Validates the configured SCAN_DIRS, keeping only directories that exist.
# Globals:
#   SCAN_DIRS, _scan_dirs
# Arguments:
#   None
# Outputs:
#   Logs a warning for each missing directory.
# Returns:
#   0 if at least one directory is valid, 1 otherwise.
########################################
prepare_scan_dirs() {
  local dir
  _scan_dirs=()
  for dir in "${SCAN_DIRS[@]}"; do
    # Strip trailing slashes so find's output matches the absolute paths built
    # from Deluge's (rtrimstr-normalised) save path; otherwise a configured
    # "/path/" would yield "/path//file" and never match.
    while [[ "${dir}" == */ && ${#dir} -gt 1 ]]; do
      dir="${dir%/}"
    done
    if [[ -d "${dir}" ]]; then
      _scan_dirs+=("${dir}")
    else
      log_info "Skipping non-existent scan directory: ${dir}"
    fi
  done

  if [[ ${#_scan_dirs[@]} -eq 0 ]]; then
    log_error "None of the configured SCAN_DIRS exist."
    return 1
  fi
}

########################################
# Scans the validated directories for orphaned files (link count 1), excluding
# filenames matching EXCLUDE_PATTERNS, and stores the result as a JSON array of
# absolute paths in _orphans_json.
#
# find emits NUL-delimited paths (so any filename is handled) piped straight
# into jq; the NUL stream is never stored in a shell variable, which cannot hold
# NUL bytes.
# Globals:
#   _scan_dirs, EXCLUDE_PATTERNS, _orphans_json
# Arguments:
#   None
########################################
find_orphans() {
  local exclude_args=()
  local pattern
  for pattern in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
    exclude_args+=(! -iname "${pattern}")
  done

  local -a find_args=("${_scan_dirs[@]}" -type f -links 1)
  find_args+=("${exclude_args[@]}" -print0)
  # `|| true` stops a partial find failure (e.g. an unreadable subdirectory) from aborting the script
  # under errexit/pipefail; paths found so far are still piped to jq.
  _orphans_json=$({ find "${find_args[@]}" || true; } | jq -Rs "${_JQ_SPLIT_NUL}")
}

########################################
# Performs a single Deluge Web JSON-RPC call.
# Globals:
#   DELUGE_URL, _cookie_jar
# Arguments:
#   method: The JSON-RPC method name (e.g., "core.get_torrents_status").
#   params: A JSON array string of parameters (e.g., '[]').
# Outputs:
#   Prints the compact JSON ".result" on success.
# Returns:
#   0 on success, 1 on transport or API error.
########################################
deluge_rpc() {
  local method="$1"
  local params="$2"

  local payload
  payload=$(jq -nc --arg m "${method}" --argjson p "${params}" '{method: $m, params: $p, id: 1}')

  # The payload is sent via stdin (--data @-) rather than as a -d argument so the Deluge password in
  # the auth.login body never appears in this process's argv (visible to other users via ps / /proc).
  # curl's -d strips the trailing newline the here-string adds, which is harmless for JSON anyway.
  local -a curl_args=(-fsS -c "${_cookie_jar}" -b "${_cookie_jar}")
  curl_args+=(-H 'Content-Type: application/json')
  curl_args+=(--data @- "${DELUGE_URL}")

  local response
  if ! response=$(curl "${curl_args[@]}" <<<"${payload}"); then
    log_error "Deluge request failed (method: ${method})."
    return 1
  fi

  # curl -f only fails on HTTP >= 400; a wrong URL or reverse-proxy login page
  # can still return 200 with an empty or non-JSON body. Validate before parsing
  # so a misconfiguration produces a clear message instead of a raw jq error
  # (which, under errexit, would otherwise abort the whole script).
  if [[ -z "${response}" ]] || ! jq -e . >/dev/null 2>&1 <<<"${response}"; then
    log_error "Deluge returned an empty or non-JSON response (method: ${method}). Is DELUGE_URL the Web UI /json endpoint?"
    return 1
  fi

  local api_error
  api_error=$(jq -r 'if .error then (.error.message // (.error | tostring)) else empty end' <<<"${response}")
  if [[ -n "${api_error}" ]]; then
    log_error "Deluge API error (method: ${method}): ${api_error}"
    return 1
  fi

  jq -c '.result' <<<"${response}"
}

########################################
# Authenticates against the Deluge Web UI and ensures it is connected to a
# daemon, connecting to the first configured host as a fallback.
# Globals:
#   DELUGE_PASSWORD
# Arguments:
#   None
# Returns:
#   0 on success; exits non-zero on failure.
########################################
deluge_connect() {
  local params result
  params=$(jq -nc --arg p "${DELUGE_PASSWORD}" '[$p]')
  result=$(deluge_rpc "auth.login" "${params}") || exit 1
  if [[ "${result}" != "true" ]]; then
    log_error "Deluge authentication failed. Check DELUGE_PASSWORD and DELUGE_URL."
    exit 1
  fi
  log_debug "Authenticated with the Deluge Web UI."

  local connected
  connected=$(deluge_rpc "web.connected" "[]") || exit 1
  if [[ "${connected}" == "true" ]]; then
    return 0
  fi

  log_debug "Web UI not connected to a daemon; attempting to connect."
  local hosts host_id
  hosts=$(deluge_rpc "web.get_hosts" "[]") || exit 1
  host_id=$(jq -r '.[0][0] // empty' <<<"${hosts}")
  if [[ -z "${host_id}" ]]; then
    log_error "No Deluge daemon hosts are configured in the Web UI."
    exit 1
  fi
  params=$(jq -nc --arg h "${host_id}" '[$h]')
  deluge_rpc "web.connect" "${params}" >/dev/null || exit 1
  log_debug "Connected to daemon host ${host_id}."
}

########################################
# Queries Deluge for the status of all torrents.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The torrents-status JSON object (info-hash -> status) on stdout.
########################################
fetch_torrent_status() {
  local fields='["name", "download_location", "save_path", "total_size", "files", "time_added"]'
  deluge_rpc "core.get_torrents_status" "[{}, ${fields}]"
}

########################################
# Given the torrents-status JSON, emits one compact JSON object per torrent that
# has at least one orphaned media file.
#
# Each torrent's files are resolved to absolute paths (applying the optional
# DELUGE_PATH_PREFIX -> LOCAL_PATH_PREFIX rewrite), classified as media or
# sidecar via EXCLUDE_PATTERNS, and split into orphaned (in the orphan set) and
# still-hard-linked media. A torrent is only emitted if at least one orphaned
# media file is "significant" (>= MIN_MEDIA_RATIO of the torrent's largest media
# file), so tiny extras (deleted scenes, advert clips) don't flag it. Records
# are sorted oldest-first by time_added.
#
# Each emitted object has: hash, name, total_size, freed, time_added, n_orphan,
# n_media, and the orphaned/linked file arrays ({path, size}).
# Globals:
#   _orphans_json, _excludes_json, MIN_MEDIA_RATIO,
#   DELUGE_PATH_PREFIX, LOCAL_PATH_PREFIX
# Arguments:
#   status: The torrents-status JSON object.
# Outputs:
#   Newline-delimited compact JSON candidate objects on stdout.
########################################
compute_candidates() {
  local status="$1"
  local dprefix="${DELUGE_PATH_PREFIX:-}" lprefix="${LOCAL_PATH_PREFIX:-}"
  dprefix="${dprefix%/}"
  lprefix="${lprefix%/}"

  local -a args=(-c)
  args+=(--argjson orphans "${_orphans_json}")
  args+=(--argjson excludes "${_excludes_json}")
  args+=(--argjson minratio "${MIN_MEDIA_RATIO:-0.1}")
  args+=(--arg dprefix "${dprefix}")
  args+=(--arg lprefix "${lprefix}")

  local prog
  prog=$(load_program candidates.jq)  # @embed candidates.jq
  jq "${args[@]}" "${prog}" <<<"${status}"
}

########################################
# Given the torrents-status JSON, prints the orphaned files that belong to NO
# torrent at all (true strays) as a JSON array of absolute paths. These have no
# torrent to remove, so they are candidates for direct file deletion.
#
# An orphan that belongs to a torrent which compute_candidates filtered out
# (e.g. a tiny extra in a still-seeding torrent) is intentionally NOT a stray:
# the file is part of a live torrent and must not be deleted directly.
# Globals:
#   _orphans_json, DELUGE_PATH_PREFIX, LOCAL_PATH_PREFIX
# Arguments:
#   status: The torrents-status JSON object.
# Outputs:
#   A JSON array of absolute stray file paths on stdout.
########################################
compute_strays() {
  local status="$1"
  local dprefix="${DELUGE_PATH_PREFIX:-}" lprefix="${LOCAL_PATH_PREFIX:-}"
  dprefix="${dprefix%/}"
  lprefix="${lprefix%/}"

  local -a args=(-c)
  args+=(--argjson orphans "${_orphans_json}")
  args+=(--arg dprefix "${dprefix}")
  args+=(--arg lprefix "${lprefix}")

  local prog
  prog=$(load_program strays.jq)  # @embed strays.jq
  jq "${args[@]}" "${prog}" <<<"${status}"
}

########################################
# Sends a remove request for a single torrent (including its data).
# Globals:
#   None
# Arguments:
#   hash: The torrent's info-hash.
# Returns:
#   0 if Deluge confirmed removal, 1 otherwise.
########################################
remove_torrent() {
  local hash="$1"
  local params result
  params=$(jq -nc --arg h "${hash}" '[$h, true]')
  if ! result=$(deluge_rpc "core.remove_torrent" "${params}"); then
    return 1
  fi
  [[ "${result}" == "true" ]]
}

########################################
# Prints an indented, size-annotated list of files from a candidate's JSON.
# Globals:
#   _C_DIM, _C_RESET
# Arguments:
#   json:    The candidate JSON object.
#   key:     Which file array to print ("orphaned" or "linked").
#   heading: A pre-colored heading line printed before the files (if any).
########################################
print_file_list() {
  local json="$1" key="$2" heading="$3"

  local count
  count=$(jq --arg k "${key}" '.[$k] | length' <<<"${json}")
  (( count > 0 )) || return 0

  printf '%s\n' "${heading}"
  local path size
  while IFS=$'\t' read -r path size; do
    printf '%s\n' "${_C_DIM}        ${path} ($(format_size "${size}"))${_C_RESET}"
  done < <(jq -r --arg k "${key}" '.[$k][] | [.path, (.size | tostring)] | @tsv' <<<"${json}")
}

########################################
# Prints the per-torrent summary block. For torrents where only some media
# files are orphaned, also lists exactly which files will be freed and which
# will be kept (still hard-linked elsewhere), so the user can decide.
# Globals:
#   _C_*
# Arguments:
#   json:     The candidate JSON object.
#   age_secs: The torrent's age in seconds.
########################################
print_candidate() {
  local json="$1" age_secs="$2"

  local name total_size n_orphan n_media freed
  IFS=$'\t' read -r name total_size n_orphan n_media freed < <(
    jq -r '[.name, .total_size, .n_orphan, .n_media, .freed] | @tsv' <<<"${json}"
  )

  printf '\n%s\n' "${_C_BOLD}${_C_CYAN}${name}${_C_RESET}"
  printf '%s\n' "${_C_DIM}  size: $(format_size "${total_size}")  |  age: $(format_age "${age_secs}")  |  orphaned: ${n_orphan}/${n_media} media files  |  frees: $(format_size "${freed}")${_C_RESET}"

  if (( n_orphan < n_media )); then
    printf '%s\n' "${_C_BOLD}${_C_YELLOW}  ! $(( n_media - n_orphan )) of ${n_media} media files are still hard-linked (in use elsewhere); removing frees only the orphaned copies.${_C_RESET}"
    print_file_list "${json}" orphaned "${_C_GREEN}      will free (orphaned, only in the temp folder):${_C_RESET}"
    print_file_list "${json}" linked "${_C_YELLOW}      will keep (still hard-linked / in use elsewhere):${_C_RESET}"
  fi
}

########################################
# Iterates over candidate torrents, prompting for removal (unless --yes or
# --dry-run), performs removals, and prints a final report.
#
# Candidates are passed as an argument (not via stdin) so that the interactive
# prompt_key prompt keeps reading from the terminal.
# Globals:
#   _dry_run, _assume_yes, _C_*
# Arguments:
#   candidates: Newline-delimited compact JSON candidate objects.
########################################
prompt_and_remove() {
  local candidates="$1"
  local -a rows=()
  mapfile -t rows <<<"${candidates}"

  local now
  now=$(date +%s)

  local removed=0 freed_total=0
  local assume_yes="${_assume_yes}"
  local row hash name freed time_added

  for row in "${rows[@]}"; do
    [[ -n "${row}" ]] || continue
    IFS=$'\t' read -r hash name freed time_added < <(
      jq -r '[.hash, .name, .freed, .time_added] | @tsv' <<<"${row}"
    )

    print_candidate "${row}" "$(( now - time_added ))"

    if [[ "${_dry_run}" == true ]]; then
      printf '%s\n' "${_C_MAGENTA}  [dry-run] would remove this torrent and its data.${_C_RESET}"
      removed=$(( removed + 1 ))
      freed_total=$(( freed_total + freed ))
      continue
    fi

    local do_remove=false
    if [[ "${assume_yes}" == true ]]; then
      do_remove=true
    else
      while true; do
        printf '%s' "${_C_BOLD}${_C_CYAN}  Remove this torrent and its data? ${_C_RESET}${_C_DIM}[(y)es/(n)o/(a)ll/(q)uit] ${_C_RESET}"
        if ! prompt_key; then
          printf '\n%s\n' "${_C_DIM}No more input; quitting.${_C_RESET}"
          print_report "${removed}" "${freed_total}"
          return 0
        fi
        case "${_answer,,}" in
          y) do_remove=true; break ;;
          n) do_remove=false; break ;;
          a) assume_yes=true; do_remove=true; break ;;
          q)
            printf '%s\n' "${_C_DIM}Quitting.${_C_RESET}"
            print_report "${removed}" "${freed_total}"
            return 0
            ;;
        esac
      done
    fi

    if [[ "${do_remove}" == true ]]; then
      if remove_torrent "${hash}"; then
        log_info "Removed: ${name}"
        removed=$(( removed + 1 ))
        freed_total=$(( freed_total + freed ))
      else
        log_error "Failed to remove: ${name}"
      fi
    fi
  done

  print_report "${removed}" "${freed_total}"
}

########################################
# Prints the final summary of torrents removed and space freed.
# Globals:
#   _dry_run, _C_*
# Arguments:
#   removed: Number of torrents removed.
#   freed_total: Total bytes freed.
########################################
print_report() {
  local removed="$1" freed_total="$2"

  local verb="Removed"
  [[ "${_dry_run}" == true ]] && verb="Would remove"

  printf '\n%s\n' "${_C_BOLD}${_C_GREEN}${verb} ${removed} torrent(s), freeing $(format_size "${freed_total}").${_C_RESET}"
}

########################################
# Removes directories that became empty after deleting a stray file, walking up
# from the given directory but never removing a scan root itself (or anything
# outside the scan roots). rmdir only removes genuinely empty directories, so a
# directory that still holds other files stops the walk.
# Globals:
#   _scan_dirs
# Arguments:
#   dir: The directory to start pruning from (the deleted file's parent).
########################################
prune_empty_dirs() {
  local dir="$1" root under
  while true; do
    under=""
    for root in "${_scan_dirs[@]}"; do
      if [[ "${dir}" == "${root}/"* ]]; then
        under="${root}"
        break
      fi
    done
    # Stop if the directory is not strictly inside a scan root (never remove the
    # scan root or anything above it).
    [[ -n "${under}" && "${dir}" != "${under}" ]] || break
    rmdir "${dir}" 2>/dev/null || break
    dir=$(dirname "${dir}")
  done
}

########################################
# Iterates over stray orphaned files (those belonging to no torrent), prompting
# to delete each one directly with rm, then pruning any folders left empty.
# Globals:
#   _dry_run, _assume_yes, _C_*
# Arguments:
#   strays_json: JSON array of absolute stray file paths.
########################################
prompt_and_remove_strays() {
  local strays_json="$1"
  local -a strays=()
  # NUL-delimited read so any filename (spaces/newlines) is handled safely
  # before an irreversible rm.
  mapfile -d '' -t strays < <(jq -j '.[] | . + "\u0000"' <<<"${strays_json}")

  printf '\n%s\n' "${_C_BOLD}${_C_CYAN}Stray files (orphaned, not part of any torrent):${_C_RESET}"

  local deleted=0 freed_total=0
  local assume_yes="${_assume_yes}"
  local f size

  for f in "${strays[@]}"; do
    [[ -n "${f}" ]] || continue
    # A file that vanished between the scan and here counts as zero rather than aborting the run:
    # the point of the walk is to total what is still there.
    size=$(stat_size "${f}" 2>/dev/null || echo 0)

    printf '\n%s\n' "${_C_DIM}  ${f} ($(format_size "${size}"))${_C_RESET}"

    if [[ "${_dry_run}" == true ]]; then
      printf '%s\n' "${_C_MAGENTA}  [dry-run] would delete this file.${_C_RESET}"
      deleted=$(( deleted + 1 ))
      freed_total=$(( freed_total + size ))
      continue
    fi

    local do_delete=false
    if [[ "${assume_yes}" == true ]]; then
      do_delete=true
    else
      while true; do
        printf '%s' "${_C_BOLD}${_C_CYAN}  Delete this file? ${_C_RESET}${_C_DIM}[(y)es/(n)o/(a)ll/(q)uit] ${_C_RESET}"
        if ! prompt_key; then
          printf '\n%s\n' "${_C_DIM}No more input; quitting.${_C_RESET}"
          print_stray_report "${deleted}" "${freed_total}"
          return 0
        fi
        case "${_answer,,}" in
          y) do_delete=true; break ;;
          n) do_delete=false; break ;;
          a) assume_yes=true; do_delete=true; break ;;
          q)
            printf '%s\n' "${_C_DIM}Quitting.${_C_RESET}"
            print_stray_report "${deleted}" "${freed_total}"
            return 0
            ;;
        esac
      done
    fi

    if [[ "${do_delete}" == true ]]; then
      if rm -f -- "${f}"; then
        log_info "Deleted: ${f}"
        deleted=$(( deleted + 1 ))
        freed_total=$(( freed_total + size ))
        prune_empty_dirs "$(dirname "${f}")"
      else
        log_error "Failed to delete: ${f}"
      fi
    fi
  done

  print_stray_report "${deleted}" "${freed_total}"
}

########################################
# Prints the final summary of stray files deleted and space freed.
# Globals:
#   _dry_run, _C_*
# Arguments:
#   deleted: Number of files deleted.
#   freed_total: Total bytes freed.
########################################
print_stray_report() {
  local deleted="$1" freed_total="$2"

  local verb="Deleted"
  [[ "${_dry_run}" == true ]] && verb="Would delete"

  printf '\n%s\n' "${_C_BOLD}${_C_GREEN}${verb} ${deleted} stray file(s), freeing $(format_size "${freed_total}").${_C_RESET}"
}

########################################
# Main entry point.
# Globals:
#   Many (via function calls and configuration).
# Arguments:
#   Command-line arguments.
########################################
main() {
  parse_options "$@"
  load_config || { log_error "Configuration file not found."; exit 1; }
  validate_config "array:SCAN_DIRS" "DELUGE_URL" "DELUGE_PASSWORD" || exit 1
  if [[ -n "${MIN_MEDIA_RATIO:-}" && ! "${MIN_MEDIA_RATIO}" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
    log_error "MIN_MEDIA_RATIO must be a number between 0 and 1 (got '${MIN_MEDIA_RATIO}')."
    exit 1
  fi
  setup_colors "${_no_color}"

  # Convert the configured exclusion globs into a JSON array for the matcher.
  local -a patterns=("${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}")
  _excludes_json=$(printf '%s\0' "${patterns[@]}" | jq -Rs "${_JQ_SPLIT_NUL}")

  prepare_scan_dirs || exit 1

  log_info "Scanning for orphaned files..."
  find_orphans
  local orphan_count
  orphan_count=$(jq 'length' <<<"${_orphans_json}")
  if [[ "${orphan_count}" -eq 0 ]]; then
    printf '%s\n' "${_C_BRIGHT_GREEN}No orphaned files found.${_C_RESET}"
    exit 0
  fi
  log_info "Found ${orphan_count} orphaned file(s)."

  _cookie_jar=$(mktemp)
  trap 'rm -f "${_cookie_jar}"' EXIT

  deluge_connect

  local status
  status=$(fetch_torrent_status) || exit 1
  log_debug "Deluge returned $(jq 'length' <<<"${status}") torrent(s)."

  # Partition the orphans: torrents worth removing (compute_candidates) and
  # files belonging to no torrent at all (compute_strays). Orphans that belong
  # to a still-seeding torrent the gate filtered out fall into neither and are
  # left untouched.
  local candidates strays n_strays
  candidates=$(compute_candidates "${status}")
  strays=$(compute_strays "${status}")
  n_strays=$(jq 'length' <<<"${strays}")

  if [[ -z "${candidates}" && "${n_strays}" -eq 0 ]]; then
    printf '%s\n' "${_C_BRIGHT_GREEN}Nothing to prune: every orphaned file belongs to a torrent still seeding wanted media.${_C_RESET}"
    exit 0
  fi

  if [[ -n "${candidates}" ]]; then
    prompt_and_remove "${candidates}"
  fi

  if [[ "${n_strays}" -gt 0 ]]; then
    prompt_and_remove_strays "${strays}"
  fi
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

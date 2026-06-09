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
# All system-specific values (paths, exclusions, Deluge endpoint/password) live
# in a configuration file discovered next to the script or under <prefix>/etc/.
#
# Usage:
#   ./prune-orphaned-torrents.sh [-n|--dry-run] [-y|--yes] [-C|--no-color] [-d|--debug]

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../lib/common.sh"
# @include ../lib/common.sh

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

# Holds the most recent line entered by the user (set by read_answer).
_answer=""

# --- Color Variables (set by setup_colors) ---
_C_CYAN=""
_C_GREEN=""
_C_BRIGHT_GREEN=""
_C_YELLOW=""
_C_MAGENTA=""
_C_WHITE=""
_C_DIM=""
_C_BOLD=""
_C_RESET=""

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
corresponding torrents from Deluge.

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
# Configures color variables based on terminal capability and user preference.
# Globals:
#   _no_color, _C_CYAN, _C_GREEN, _C_BRIGHT_GREEN, _C_YELLOW, _C_MAGENTA,
#   _C_WHITE, _C_DIM, _C_BOLD, _C_RESET
# Arguments:
#   None
########################################
setup_colors() {
  if [[ "${_no_color}" == true ]]; then
    return
  fi
  if [[ ! -t 1 ]]; then
    return
  fi
  _C_CYAN=$'\033[36m'
  _C_GREEN=$'\033[32m'
  _C_BRIGHT_GREEN=$'\033[92m'
  _C_YELLOW=$'\033[33m'
  _C_MAGENTA=$'\033[35m'
  _C_WHITE=$'\033[97m'
  _C_DIM=$'\033[2m'
  _C_BOLD=$'\033[1m'
  _C_RESET=$'\033[0m'
}

########################################
# Reads a single line of input from the user into the global _answer.
# The color escapes are written straight to the terminal (not captured) so the
# user's typed input appears in bright white; the input itself is returned via
# the _answer global rather than stdout, so callers must not use command
# substitution (which would capture the escape codes too).
# Globals:
#   _answer, _C_WHITE, _C_RESET
# Arguments:
#   None
# Returns:
#   0 if a line was read, non-zero on EOF.
########################################
read_answer() {
  printf '%s' "${_C_WHITE}"
  _answer=""
  local rc=0
  # Propagate EOF (e.g. Ctrl-D, or non-interactive/empty stdin) so callers can
  # stop instead of spinning forever re-prompting. The `|| rc=$?` also keeps
  # errexit from firing on a non-zero read.
  read -r _answer || rc=$?
  printf '%s' "${_C_RESET}"
  return "${rc}"
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
  awk -v s="${1:-0}" 'BEGIN {
    split("B KB MB GB TB PB", u, " ");
    if (s == 0) { print "0 B"; exit }
    i = 1;
    while (s >= 1024 && i < 6) { s /= 1024; i++ }
    printf "%.2f %s\n", s, u[i]
  }'
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

  _orphans_json=$(
    # `|| true` stops a partial find failure (e.g. an unreadable subdirectory)
    # from aborting the script under errexit/pipefail; paths found so far are
    # still piped to jq.
    { find "${_scan_dirs[@]}" -type f -links 1 "${exclude_args[@]}" -print0 || true; } \
      | jq -Rs 'split("\u0000") | map(select(length > 0))'
  )
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
  payload=$(jq -nc --arg m "${method}" --argjson p "${params}" \
    '{method: $m, params: $p, id: 1}')

  local response
  # The payload is sent via stdin (--data @-) rather than as a -d argument so
  # the Deluge password in the auth.login body never appears in this process's
  # argv (visible to other users via ps / /proc). curl's -d strips the trailing
  # newline the here-string adds, which is harmless for the JSON body anyway.
  if ! response=$(curl -fsS \
    -c "${_cookie_jar}" -b "${_cookie_jar}" \
    -H 'Content-Type: application/json' \
    --data @- "${DELUGE_URL}" <<<"${payload}"); then
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
# Queries Deluge for all torrents and emits one compact JSON object per torrent
# that has at least one orphaned media file.
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
#   None
# Outputs:
#   Newline-delimited compact JSON candidate objects on stdout.
########################################
fetch_candidates() {
  local status
  status=$(deluge_rpc "core.get_torrents_status" \
    '[{}, ["name", "download_location", "save_path", "total_size", "files", "time_added"]]') || exit 1

  # Normalise the optional path-translation prefixes by stripping trailing
  # slashes, so the jq rewrite can append "/rest" without doubling or dropping a
  # separator regardless of how the user wrote them in the config.
  local dprefix="${DELUGE_PATH_PREFIX:-}" lprefix="${LOCAL_PATH_PREFIX:-}"
  dprefix="${dprefix%/}"
  lprefix="${lprefix%/}"

  jq -c \
    --argjson orphans "${_orphans_json}" \
    --argjson excludes "${_excludes_json}" \
    --argjson minratio "${MIN_MEDIA_RATIO:-0.1}" \
    --arg dprefix "${dprefix}" \
    --arg lprefix "${lprefix}" '
    ($orphans | map({(.): true}) | add // {}) as $set
    | def glob_to_regex($g):
        "^" + ($g
          | gsub("(?<c>[.+^$()\\[\\]{}|\\\\])"; "\\\(.c)")
          | gsub("\\*"; ".*")
          | gsub("\\?"; ".")) + "$";
    ($excludes | map(glob_to_regex(.))) as $exre
    | def is_media($p):
        ($p | split("/") | last) as $b
        | (any($exre[]; . as $re | ($b | test($re; "i"))) | not);
    [ to_entries[]
      | .key as $hash
      | .value as $t
      # Skip torrents with no save location (e.g. metadata-only/error state):
      # rtrimstr would error on a null base and abort the whole program, and
      # such a torrent can never own a scanned orphan anyway.
      | (($t.download_location // $t.save_path // "") | rtrimstr("/")) as $base
      | select($base != "")
      | (($t.files // []) | map(. + {abs:
          (($base + "/" + .path)
           | if ($dprefix | length) > 0 and (. == $dprefix or startswith($dprefix + "/"))
             then $lprefix + .[($dprefix | length):]
             else . end)})) as $files
      | ($files | map(select(is_media(.abs)))) as $media
      | (($media | map(.size) | max) // 0) as $maxsize
      | ($media | map(select($set[.abs]))) as $orphaned
      | ($media | map(select($set[.abs] | not))) as $linked
      # Candidate only if at least one orphaned media file is "significant" —
      # at least $minratio of the torrent largest media file. This ignores
      # extras/spam (deleted scenes, release-group advert clips) that are tiny
      # next to the real feature and would otherwise flag a still-wanted torrent.
      | select(any($orphaned[]; .size >= ($maxsize * $minratio)))
      | { hash: $hash,
          name: $t.name,
          total_size: ($t.total_size // 0 | floor),
          freed: ($orphaned | map(.size) | add // 0 | floor),
          time_added: ($t.time_added // 0 | floor),
          n_orphan: ($orphaned | length),
          n_media: ($media | length),
          orphaned: [ $orphaned[] | {path: .abs, size: (.size // 0 | floor)} ],
          linked:   [ $linked[]   | {path: .abs, size: (.size // 0 | floor)} ] } ]
    | sort_by(.time_added)
    | .[]
  ' <<<"${status}"
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
# read_answer prompt keeps reading from the terminal.
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
        if ! read_answer; then
          printf '\n%s\n' "${_C_DIM}No more input; quitting.${_C_RESET}"
          print_report "${removed}" "${freed_total}"
          return 0
        fi
        case "${_answer,,}" in
          y|yes) do_remove=true; break ;;
          n|no) do_remove=false; break ;;
          a|all) assume_yes=true; do_remove=true; break ;;
          q|quit)
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
  setup_colors

  # Convert the configured exclusion globs into a JSON array for the matcher.
  _excludes_json=$(
    printf '%s\0' "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}" \
      | jq -Rs 'split("\u0000") | map(select(length > 0))'
  )

  prepare_scan_dirs || exit 1

  log_info "Scanning for orphaned files..."
  find_orphans
  if [[ "$(jq 'length' <<<"${_orphans_json}")" -eq 0 ]]; then
    printf '%s\n' "${_C_BRIGHT_GREEN}No orphaned files found.${_C_RESET}"
    exit 0
  fi

  _cookie_jar=$(mktemp)
  trap 'rm -f "${_cookie_jar}"' EXIT

  deluge_connect

  local candidates
  candidates=$(fetch_candidates)
  if [[ -z "${candidates}" ]]; then
    printf '%s\n' "${_C_BRIGHT_GREEN}Orphaned files found, but none belong to a known Deluge torrent.${_C_RESET}"
    exit 0
  fi

  prompt_and_remove "${candidates}"
}

main "$@"

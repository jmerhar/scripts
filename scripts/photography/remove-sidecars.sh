#!/usr/bin/env bash
#
# Finds and deletes "sidecar" files (e.g., JPEGs) when a corresponding RAW photo
# file with the same base name exists in the same directory.
#
# This is useful for cleaning up photo collections where you only want to keep
# the RAW file for archival purposes once you have finished editing.
#
# The script traverses a directory tree, prompts the user with what it finds,
# and then deletes the files upon confirmation.
#
# Usage:
#   ./remove-sidecars.sh [-n|--dry-run] [-C|--no-color] [DIRECTORY]

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../lib/common.sh"
# @include ../lib/common.sh

# --- Global State ---
_dry_run=false
_no_color=false
_target_dir="."

# User-defined file extensions.
_sidecar_exts=()
_raw_exts=()

# Parallel arrays describing the sidecars queued for deletion: _del_paths[i] is a
# sidecar file path and _del_exts[i] is the RAW extension it is a sidecar for.
# Indexed arrays are used (rather than a delimited string) so that filenames
# containing spaces are handled safely.
_del_paths=()
_del_exts=()

# Bytes recovered per RAW extension, accumulated by delete_files() and reported
# by print_report(). Populated once per run (deletion is not recursive).
declare -A _ext_size=()

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

# Holds the most recent line entered by the user (set by read_answer).
_answer=""

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
Usage: ${SCRIPT_NAME} [OPTIONS] [DIRECTORY]

Find and delete sidecar files when a corresponding RAW file exists.

Options:
  -n, --dry-run   Show what would be deleted without actually deleting.
  -C, --no-color  Disable colored output.
  -h, --help      Show this help message.

If no directory is given, the current directory is used.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _dry_run, _no_color, _target_dir
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)
        _dry_run=true
        shift
        ;;
      -C|--no-color)
        _no_color=true
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        log_error "Unknown option '$1'. Use --help for usage."
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#positional[@]} -gt 1 ]]; then
    log_error "Expected at most one directory argument, got ${#positional[@]}."
    exit 1
  fi

  if [[ ${#positional[@]} -eq 1 ]]; then
    _target_dir="${positional[0]}"
    if [[ ! -d "${_target_dir}" ]]; then
      log_error "'${_target_dir}' is not a directory."
      exit 1
    fi
  fi
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
# Detects the platform's stat flavor and defines get_size().
# Globals:
#   None
# Arguments:
#   None
########################################
detect_platform() {
  if stat -c '%s' / &>/dev/null; then
    get_size() { stat -c '%s' "$1"; }
  else
    get_size() { stat -f '%z' "$1"; }
  fi
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
########################################
read_answer() {
  printf '%s' "${_C_WHITE}"
  _answer=""
  # Guard against EOF (e.g., piped/empty input) which would trip errexit.
  read -r _answer || true
  printf '%s' "${_C_RESET}"
}

########################################
# Prompts the user to define which extensions are sidecars and which are RAW.
# Globals:
#   _sidecar_exts, _raw_exts, _C_CYAN, _C_DIM, _C_BOLD, _C_RESET
# Arguments:
#   None
# Outputs:
#   Populates the global _sidecar_exts and _raw_exts arrays.
########################################
define_extensions() {
  local sidecars_default="JPG jpg JPEG jpeg"
  local raws_default="RW2 CR2 DNG dng"

  printf '%s' "${_C_BOLD}${_C_CYAN}What extensions do your sidecars have? ${_C_RESET}"
  printf '%s' "${_C_DIM}[${sidecars_default}] ${_C_RESET}"
  read_answer
  read -ra _sidecar_exts <<<"${_answer:-${sidecars_default}}"

  printf '%s' "${_C_BOLD}${_C_CYAN}What extensions do your raw photos have? ${_C_RESET}"
  printf '%s' "${_C_DIM}[${raws_default}] ${_C_RESET}"
  read_answer
  read -ra _raw_exts <<<"${_answer:-${raws_default}}"

  printf '\n'
}

########################################
# Recursively traverses a directory tree. For each directory it collects the
# files (grouped by base name) and identifies sidecars: when a RAW file exists
# for a base name, every matching sidecar in the same directory is queued for
# deletion. Symlinks are skipped to avoid cycles and unexpected traversal.
#
# The identification logic is inlined here (rather than a separate function) so
# that the per-directory maps stay local to this invocation — recursion would
# otherwise clobber a shared copy before the parent directory is processed.
# Globals:
#   _raw_exts, _sidecar_exts, _del_paths, _del_exts,
#   _C_DIM, _C_YELLOW, _C_RESET
# Arguments:
#   dir: The directory to start traversing from.
########################################
traverse_tree() {
  local dir="$1"

  printf '%s\n' "${_C_DIM}${_C_YELLOW}Scanning directory ${dir}${_C_RESET}"

  # Collect files in this directory, grouped by base name. Keys are
  # "${base}/${ext}" — safe because a single-directory filename has no slash and
  # the extension (matched as [^.]+) has no dot or slash.
  local -A ext_present=()
  local -A basenames=()
  local entry fname base ext

  while IFS= read -r -d '' entry; do
    # Skip symlinks.
    [[ -L "${entry}" ]] && continue

    if [[ -d "${entry}" ]]; then
      traverse_tree "${entry}"
      continue
    fi

    fname="$(basename "${entry}")"
    # Require a non-empty extension after the last dot (mirrors ^(.*)\.([^.]+)$).
    [[ "${fname}" == *.* ]] || continue
    ext="${fname##*.}"
    [[ -n "${ext}" ]] || continue
    base="${fname%.*}"

    ext_present["${base}/${ext}"]=1
    basenames["${base}"]=1
  done < <(find "${dir}" -maxdepth 1 -mindepth 1 -print0)

  # Identify sidecars for the files collected above.
  [[ ${#basenames[@]} -gt 0 ]] || return 0

  local name raw_ext sidecar_ext found_raw_ext
  for name in "${!basenames[@]}"; do
    found_raw_ext=""

    # Check whether a RAW file exists for this base name.
    for raw_ext in "${_raw_exts[@]+"${_raw_exts[@]}"}"; do
      if [[ -n "${ext_present["${name}/${raw_ext}"]:-}" ]]; then
        found_raw_ext="${raw_ext}"
        break
      fi
    done

    # If no RAW file was found for this name, leave everything untouched.
    [[ -n "${found_raw_ext}" ]] || continue

    # A RAW file exists, so queue any matching sidecars for deletion.
    for sidecar_ext in "${_sidecar_exts[@]+"${_sidecar_exts[@]}"}"; do
      if [[ -n "${ext_present["${name}/${sidecar_ext}"]:-}" ]]; then
        _del_paths+=("${dir}/${name}.${sidecar_ext}")
        _del_exts+=("${found_raw_ext}")
      fi
    done
  done
}

########################################
# Formats a size in bytes into a human-readable string (KB, MB, GB, etc.).
# Globals:
#   None
# Arguments:
#   size: The size in bytes (may be fractional, e.g. an average).
# Outputs:
#   A formatted string such as "1.23 MB".
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
# Returns the sorted, unique list of RAW extensions that have queued sidecars.
# Globals:
#   _del_exts
# Arguments:
#   None
# Outputs:
#   One RAW extension per line, sorted.
########################################
queued_raw_exts() {
  [[ ${#_del_exts[@]} -gt 0 ]] || return 0
  printf '%s\n' "${_del_exts[@]}" | sort -u
}

########################################
# Counts how many queued sidecars correspond to a given RAW extension.
# Globals:
#   _del_exts
# Arguments:
#   raw_ext: The RAW extension to count.
# Outputs:
#   The count on stdout.
########################################
count_for_ext() {
  local raw_ext="$1" e count=0
  for e in "${_del_exts[@]+"${_del_exts[@]}"}"; do
    [[ "${e}" == "${raw_ext}" ]] && count=$((count + 1))
  done
  printf '%s' "${count}"
}

########################################
# Prints a summary of found sidecars, grouped by RAW type.
# Globals:
#   _C_BOLD, _C_GREEN, _C_RESET
# Arguments:
#   None
########################################
print_summary() {
  local raw_ext count
  printf '\n%s\n' "${_C_BOLD}${_C_GREEN}Found sidecars for the following RAW types:${_C_RESET}"
  while IFS= read -r raw_ext; do
    count="$(count_for_ext "${raw_ext}")"
    printf '%s\n' "${_C_BOLD}${_C_GREEN}- ${count} sidecars for ${raw_ext} files${_C_RESET}"
  done < <(queued_raw_exts)
}

########################################
# Prints, per RAW type, how many sidecars were found in each directory.
# Globals:
#   _del_paths, _del_exts, _C_BOLD, _C_GREEN, _C_YELLOW, _C_RESET
# Arguments:
#   None
########################################
print_directories() {
  local raw_ext i dir
  while IFS= read -r raw_ext; do
    printf '\n%s\n' "${_C_BOLD}${_C_GREEN}Found sidecars for ${raw_ext} files in the following directories:${_C_RESET}"

    local -A count=()
    for i in "${!_del_paths[@]}"; do
      [[ "${_del_exts[i]}" == "${raw_ext}" ]] || continue
      dir="$(dirname "${_del_paths[i]}")"
      count["${dir}"]=$(( ${count["${dir}"]:-0} + 1 ))
    done

    while IFS= read -r dir; do
      printf '%s\n' "${_C_BOLD}${_C_YELLOW}$(printf '[%5d] %s' "${count["${dir}"]}" "${dir}")${_C_RESET}"
    done < <(printf '%s\n' "${!count[@]}" | sort)
  done < <(queued_raw_exts)
}

########################################
# Prompts the user with a summary and asks what action to take.
# Globals:
#   _C_BOLD, _C_CYAN, _C_DIM, _C_RESET
# Arguments:
#   None
# Returns:
#   0 if the user chooses to delete, 1 otherwise.
########################################
prompt_action() {
  print_summary

  local answer="s"
  while [[ "${answer}" == "s" ]]; do
    printf '\n%s' "${_C_BOLD}${_C_CYAN}Would you like to (d)elete them, (s)ee a list of directories, or (q)uit? ${_C_RESET}"
    printf '%s' "${_C_DIM}[d/s/Q] ${_C_RESET}"
    read_answer
    answer="${_answer,,}"
    [[ "${answer}" == "s" ]] && print_directories
  done

  [[ "${answer}" == "d" ]]
}

########################################
# Deletes (or, in dry-run mode, lists) the queued sidecar files, then reports.
# Globals:
#   _dry_run, _del_paths, _del_exts, _ext_size, _C_MAGENTA, _C_RESET
# Arguments:
#   None
########################################
delete_files() {
  local verb="Deleting"
  [[ "${_dry_run}" == true ]] && verb="Would delete"

  local total_size=0
  local raw_ext i file size

  # Group the deletion listing by RAW type (sorted), matching the summary and
  # report ordering.
  while IFS= read -r raw_ext; do
    for i in "${!_del_paths[@]}"; do
      [[ "${_del_exts[i]}" == "${raw_ext}" ]] || continue
      file="${_del_paths[i]}"
      size="$(get_size "${file}" 2>/dev/null || echo 0)"

      printf '%s\n' "${_C_MAGENTA}$(printf '%s %s (%s), a sidecar for a %s file' \
        "${verb}" "${file}" "$(format_size "${size}")" "${raw_ext}")${_C_RESET}"

      total_size=$((total_size + size))
      _ext_size["${raw_ext}"]=$(( ${_ext_size["${raw_ext}"]:-0} + size ))

      if [[ "${_dry_run}" != true ]]; then
        rm -- "${file}" || log_error "Could not delete ${file}"
      fi
    done
  done < <(queued_raw_exts)

  print_report "${total_size}"
}

########################################
# Prints a final report summarizing the space recovered, per RAW type.
# Globals:
#   _dry_run, _ext_size, _C_BOLD, _C_GREEN, _C_RESET
# Arguments:
#   total_size: The total bytes recovered.
########################################
print_report() {
  local total_size="$1"
  [[ "${total_size}" -gt 0 ]] || return 0

  local recovered_phrase="was recovered"
  [[ "${_dry_run}" == true ]] && recovered_phrase="would be recovered"

  printf '\n%s\n' "${_C_BOLD}${_C_GREEN}In total $(format_size "${total_size}") of disk space ${recovered_phrase}:${_C_RESET}"

  local raw_ext count avg
  while IFS= read -r raw_ext; do
    count="$(count_for_ext "${raw_ext}")"
    [[ "${count}" -gt 0 ]] || continue
    avg="$(awk -v b="${_ext_size["${raw_ext}"]}" -v c="${count}" 'BEGIN { print b / c }')"
    printf '%s\n' "${_C_BOLD}${_C_GREEN}$(printf -- '- %s by deleting %d sidecars for %s files (average %s per file).' \
      "$(format_size "${_ext_size["${raw_ext}"]}")" "${count}" "${raw_ext}" "$(format_size "${avg}")")${_C_RESET}"
  done < <(queued_raw_exts)
}

########################################
# Main entry point.
# Globals:
#   _dry_run, _target_dir, _del_paths, _C_BRIGHT_GREEN, _C_RESET
# Arguments:
#   Command-line arguments.
########################################
main() {
  parse_options "$@"
  setup_colors
  detect_platform

  define_extensions
  traverse_tree "${_target_dir}"

  if [[ ${#_del_paths[@]} -eq 0 ]]; then
    printf '%s\n' "${_C_BRIGHT_GREEN}No sidecar files found to delete.${_C_RESET}"
    exit 0
  fi

  if [[ "${_dry_run}" == true ]]; then
    delete_files
  elif prompt_action; then
    delete_files
  fi
}

main "$@"

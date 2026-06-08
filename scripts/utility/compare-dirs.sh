#!/usr/bin/env bash
#
# Recursively compares two directories and reports differences in existence,
# size, timestamps, and checksums. Reports missing directories at the top level
# rather than enumerating all their contents.
#
# Usage:
#   ./compare-dirs.sh [OPTIONS] <dir1> <dir2>

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../lib/common.sh"
# @include ../lib/common.sh

# --- Global State ---
_opt_timestamps=false
_opt_checksums=false
_opt_no_color=false
_dir1=""
_dir2=""
_count_left_only=0
_count_right_only=0
_count_differences=0

# --- Color Variables (set by setup_colors) ---
_C_RED=""
_C_GREEN=""
_C_YELLOW=""
_C_CYAN=""
_C_BOLD=""
_C_RESET=""

########################################
# Prints the script's usage instructions.
# Globals:
#   SCRIPT_NAME
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <dir1> <dir2>

Recursively compare two directories and report differences.

Options:
  -t, --timestamps   Also compare file modification times
  -c, --checksums    Also compare file checksums (sha256)
  -n, --no-color     Disable colored output
  -h, --help         Show this help message

Output markers:
  ←  Item exists only in LEFT directory
  →  Item exists only in RIGHT directory
  ≠  Item differs between directories
  ⚡ Type mismatch (e.g., file vs directory)
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Supports long options and combined short options (e.g., -tc).
# Globals:
#   _opt_timestamps, _opt_checksums, _opt_no_color, _dir1, _dir2
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--timestamps)
        _opt_timestamps=true
        shift
        ;;
      -c|--checksums)
        _opt_checksums=true
        shift
        ;;
      -n|--no-color)
        _opt_no_color=true
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
        local combined="${1#-}"
        shift
        for (( i=0; i<${#combined}; i++ )); do
          case "${combined:$i:1}" in
            t) _opt_timestamps=true ;;
            c) _opt_checksums=true ;;
            n) _opt_no_color=true ;;
            h) show_usage; exit 0 ;;
            *)
              log_error "Unknown option: -${combined:$i:1}"
              show_usage
              exit 1
              ;;
          esac
        done
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#positional[@]} -ne 2 ]]; then
    log_error "Expected exactly 2 directory arguments, got ${#positional[@]}."
    show_usage
    exit 1
  fi

  _dir1="${positional[0]}"
  _dir2="${positional[1]}"

  if [[ ! -d "${_dir1}" ]]; then
    log_error "'${_dir1}' is not a directory."
    exit 1
  fi
  if [[ ! -d "${_dir2}" ]]; then
    log_error "'${_dir2}' is not a directory."
    exit 1
  fi

  # Resolve to absolute paths for display
  _dir1="$(cd "${_dir1}" && pwd)"
  _dir2="$(cd "${_dir2}" && pwd)"
}

########################################
# Detects platform-specific tools and defines helper functions.
# Defines get_size(), get_mtime(), and get_checksum() based on
# available system utilities.
# Globals:
#   _opt_checksums
########################################
detect_platform() {
  # Detect stat flavor
  if stat -c '%s' / &>/dev/null; then
    get_size() { stat -c '%s' "$1"; }
    get_mtime() { stat -c '%Y' "$1"; }
  else
    get_size() { stat -f '%z' "$1"; }
    get_mtime() { stat -f '%m' "$1"; }
  fi

  # Detect checksum tool
  if command -v sha256sum &>/dev/null; then
    get_checksum() { sha256sum "$1" | cut -d' ' -f1; }
  elif command -v shasum &>/dev/null; then
    get_checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }
  else
    if [[ "${_opt_checksums}" == true ]]; then
      log_error "No checksum tool found (sha256sum or shasum). Checksum comparison disabled."
      _opt_checksums=false
    fi
    get_checksum() { echo "NO_CHECKSUM_TOOL"; }
  fi
}

########################################
# Configures color variables based on terminal capability and user preference.
# Globals:
#   _opt_no_color, _C_RED, _C_GREEN, _C_YELLOW, _C_CYAN, _C_BOLD, _C_RESET
########################################
setup_colors() {
  if [[ "${_opt_no_color}" == true ]]; then
    return
  fi
  if [[ ! -t 1 ]]; then
    return
  fi
  _C_RED=$'\033[31m'
  _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'
  _C_CYAN=$'\033[36m'
  _C_BOLD=$'\033[1m'
  _C_RESET=$'\033[0m'
}

########################################
# Formats an epoch timestamp as a human-readable date string.
# Arguments:
#   ts: Unix epoch timestamp.
# Outputs:
#   Prints formatted date to stdout.
########################################
format_mtime() {
  local ts="$1"
  if date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; then
    return
  fi
  # BSD date fallback
  date -r "${ts}" '+%Y-%m-%d %H:%M:%S'
}

########################################
# Formats a byte count with thousands separators.
# Arguments:
#   size: File size in bytes.
# Outputs:
#   Prints formatted size to stdout.
########################################
format_size() {
  printf "%'d bytes" "$1"
}

########################################
# Determines the filesystem type of a path.
# Arguments:
#   path: Filesystem path to inspect.
# Outputs:
#   Prints one of: symlink, directory, file, other.
########################################
get_type() {
  local path="$1"
  if [[ -L "${path}" ]]; then
    echo "symlink"
  elif [[ -d "${path}" ]]; then
    echo "directory"
  elif [[ -f "${path}" ]]; then
    echo "file"
  else
    echo "other"
  fi
}

# --- Output Helpers ---

########################################
# Reports an item found only in the left directory.
# Globals:
#   _C_RED, _C_BOLD, _C_RESET, _count_left_only
# Arguments:
#   Relative path of the item.
########################################
print_left_only() {
  echo "${_C_RED}← LEFT only:  ${_C_BOLD}${1}${_C_RESET}"
  (( _count_left_only++ )) || true
}

########################################
# Reports an item found only in the right directory.
# Globals:
#   _C_GREEN, _C_BOLD, _C_RESET, _count_right_only
# Arguments:
#   Relative path of the item.
########################################
print_right_only() {
  echo "${_C_GREEN}→ RIGHT only: ${_C_BOLD}${1}${_C_RESET}"
  (( _count_right_only++ )) || true
}

########################################
# Reports a file size difference between left and right.
# Globals:
#   _C_YELLOW, _C_BOLD, _C_RESET, _count_differences
# Arguments:
#   path: Relative path of the file.
#   size1: Size in left directory (bytes).
#   size2: Size in right directory (bytes).
########################################
print_size_diff() {
  local path="$1" size1="$2" size2="$3"
  echo "${_C_YELLOW}≠ Size differs: ${_C_BOLD}${path}${_C_RESET}"
  echo "    LEFT:  $(format_size "${size1}")"
  echo "    RIGHT: $(format_size "${size2}")"
  (( _count_differences++ )) || true
}

########################################
# Reports a modification time difference between left and right.
# Globals:
#   _C_YELLOW, _C_BOLD, _C_RESET, _count_differences
# Arguments:
#   path: Relative path of the file.
#   mtime1: Epoch timestamp in left directory.
#   mtime2: Epoch timestamp in right directory.
########################################
print_mtime_diff() {
  local path="$1" mtime1="$2" mtime2="$3"
  echo "${_C_YELLOW}≠ Mtime differs: ${_C_BOLD}${path}${_C_RESET}"
  echo "    LEFT:  $(format_mtime "${mtime1}")"
  echo "    RIGHT: $(format_mtime "${mtime2}")"
  (( _count_differences++ )) || true
}

########################################
# Reports a checksum difference between left and right.
# Globals:
#   _C_YELLOW, _C_BOLD, _C_RESET, _count_differences
# Arguments:
#   Relative path of the file.
########################################
print_checksum_diff() {
  echo "${_C_YELLOW}≠ Checksum differs: ${_C_BOLD}${1}${_C_RESET}"
  (( _count_differences++ )) || true
}

########################################
# Reports a type mismatch (e.g., file vs directory).
# Globals:
#   _C_YELLOW, _C_BOLD, _C_RESET, _count_differences
# Arguments:
#   path: Relative path of the item.
#   type1: Type in left directory.
#   type2: Type in right directory.
########################################
print_type_mismatch() {
  local path="$1" type1="$2" type2="$3"
  echo "${_C_YELLOW}⚡ Type mismatch: ${_C_BOLD}${path}${_C_RESET}"
  echo "    LEFT:  ${type1}"
  echo "    RIGHT: ${type2}"
  (( _count_differences++ )) || true
}

########################################
# Reports a symlink target difference between left and right.
# Globals:
#   _C_YELLOW, _C_BOLD, _C_RESET, _count_differences
# Arguments:
#   path: Relative path of the symlink.
#   target1: Link target in left directory.
#   target2: Link target in right directory.
########################################
print_symlink_diff() {
  local path="$1" target1="$2" target2="$3"
  echo "${_C_YELLOW}≠ Symlink target differs: ${_C_BOLD}${path}${_C_RESET}"
  echo "    LEFT:  -> ${target1}"
  echo "    RIGHT: -> ${target2}"
  (( _count_differences++ )) || true
}

########################################
# Recursively compares two directory trees, printing differences.
# Uses null-delimited I/O internally to handle arbitrary filenames.
# Globals:
#   _dir1, _dir2, _opt_timestamps, _opt_checksums
#   _count_left_only, _count_right_only, _count_differences
# Arguments:
#   prefix: Relative path prefix for the current recursion level (empty
#           string for the top level, "subdir/" for nested levels).
########################################
compare_dirs() {
  local prefix="$1"
  local left="${_dir1}/${prefix}"
  local right="${_dir2}/${prefix}"

  # Build sorted lists of entries (null-delimited for filename safety)
  local -a left_sorted=()
  local -a right_sorted=()

  if [[ -d "${left}" ]]; then
    while IFS= read -r -d '' entry; do
      left_sorted+=("$(basename "${entry}")")
    done < <(find "${left}" -maxdepth 1 -mindepth 1 -print0 | sort -z)
  fi

  if [[ -d "${right}" ]]; then
    while IFS= read -r -d '' entry; do
      right_sorted+=("$(basename "${entry}")")
    done < <(find "${right}" -maxdepth 1 -mindepth 1 -print0 | sort -z)
  fi

  # Use associative arrays for O(1) set membership tests
  local -A left_set=()
  local -A right_set=()
  for e in "${left_sorted[@]+"${left_sorted[@]}"}"; do
    left_set["${e}"]=1
  done
  for e in "${right_sorted[@]+"${right_sorted[@]}"}"; do
    right_set["${e}"]=1
  done

  # Compute merged sorted unique list
  local -a all_entries=()
  if [[ ${#left_sorted[@]} -gt 0 || ${#right_sorted[@]} -gt 0 ]]; then
    while IFS= read -r -d '' entry; do
      all_entries+=("${entry}")
    done < <(printf '%s\0' ${left_sorted[@]+"${left_sorted[@]}"} \
                           ${right_sorted[@]+"${right_sorted[@]}"} | sort -uz)
  fi

  for entry in "${all_entries[@]+"${all_entries[@]}"}"; do
    local rel_path
    if [[ -n "${prefix}" ]]; then
      rel_path="${prefix}${entry}"
    else
      rel_path="${entry}"
    fi

    local in_left="${left_set[${entry}]:-}"
    local in_right="${right_set[${entry}]:-}"

    if [[ -n "${in_left}" && -z "${in_right}" ]]; then
      local type_l
      type_l="$(get_type "${left}${entry}")"
      if [[ "${type_l}" == "directory" ]]; then
        print_left_only "${rel_path}/"
      else
        print_left_only "${rel_path}"
      fi

    elif [[ -z "${in_left}" && -n "${in_right}" ]]; then
      local type_r
      type_r="$(get_type "${right}${entry}")"
      if [[ "${type_r}" == "directory" ]]; then
        print_right_only "${rel_path}/"
      else
        print_right_only "${rel_path}"
      fi

    else
      # Present in both — compare
      local left_path="${left}${entry}"
      local right_path="${right}${entry}"
      local type_l type_r
      type_l="$(get_type "${left_path}")"
      type_r="$(get_type "${right_path}")"

      if [[ "${type_l}" != "${type_r}" ]]; then
        print_type_mismatch "${rel_path}" "${type_l}" "${type_r}"
      elif [[ "${type_l}" == "directory" ]]; then
        compare_dirs "${rel_path}/"
      elif [[ "${type_l}" == "symlink" ]]; then
        local target_l target_r
        target_l="$(readlink "${left_path}")"
        target_r="$(readlink "${right_path}")"
        if [[ "${target_l}" != "${target_r}" ]]; then
          print_symlink_diff "${rel_path}" "${target_l}" "${target_r}"
        fi
      elif [[ "${type_l}" == "file" ]]; then
        local size_l size_r
        size_l="$(get_size "${left_path}")"
        size_r="$(get_size "${right_path}")"

        if [[ "${size_l}" != "${size_r}" ]]; then
          print_size_diff "${rel_path}" "${size_l}" "${size_r}"
        elif [[ "${_opt_checksums}" == true ]]; then
          local cksum_l cksum_r
          cksum_l="$(get_checksum "${left_path}")"
          cksum_r="$(get_checksum "${right_path}")"
          if [[ "${cksum_l}" != "${cksum_r}" ]]; then
            print_checksum_diff "${rel_path}"
          fi
        fi

        if [[ "${_opt_timestamps}" == true ]]; then
          local mtime_l mtime_r
          mtime_l="$(get_mtime "${left_path}")"
          mtime_r="$(get_mtime "${right_path}")"
          if [[ "${mtime_l}" != "${mtime_r}" ]]; then
            print_mtime_diff "${rel_path}" "${mtime_l}" "${mtime_r}"
          fi
        fi
      fi
    fi
  done
}

########################################
# Main entry point.
# Arguments:
#   Command-line arguments.
########################################
main() {
  parse_options "$@"
  detect_platform
  setup_colors

  # Print header
  echo "${_C_CYAN}Comparing:${_C_RESET}"
  echo "  LEFT:  ${_C_BOLD}${_dir1}${_C_RESET}"
  echo "  RIGHT: ${_C_BOLD}${_dir2}${_C_RESET}"
  echo "─────────────────────────────────"
  echo ""

  # Run comparison
  compare_dirs ""

  # Print footer
  echo ""
  echo "─────────────────────────────────"
  local total=$(( _count_left_only + _count_right_only + _count_differences ))
  if [[ ${total} -eq 0 ]]; then
    echo "${_C_GREEN}Directories are identical.${_C_RESET}"
    exit 0
  else
    echo "${_C_CYAN}Summary:${_C_RESET} ${_count_left_only} only in LEFT, ${_count_right_only} only in RIGHT, ${_count_differences} differences"
    exit 1
  fi
}

main "$@"

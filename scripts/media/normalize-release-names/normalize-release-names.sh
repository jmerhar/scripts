#!/usr/bin/env bash
#
# Brings episode filenames to one spelling, so the tools that read them agree about what they say.
#
# A folder of episodes acquired from different places is spelled several ways: spaces in one release,
# underscores in the next, mixed case in a third, and a season-episode number written as "1x02" where the
# rest of the library uses "S01E02". Nothing is wrong with any of them until something has to match them
# — a subtitle sidecar pairing by base name, a link into a season folder, a media server's episode parser
# — and then the odd one out is the file that goes missing.
#
# What this changes is the name and nothing else: separators to dots, case to lower, and the season and
# episode to the S01E02 form. What it deliberately does not do is guess at anything else — a rename that
# reorganised a name would be a rename nobody could review.
#
# Usage:
#   ./normalize-release-names.sh [OPTIONS] [PATH]

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../../lib/colors.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/colors.sh"
# @include ../../lib/colors.sh
# shellcheck source=../../lib/prompt.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/prompt.sh"
# @include ../../lib/prompt.sh
# shellcheck source=../../lib/cli.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/cli.sh"
# @include ../../lib/cli.sh
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
# shellcheck source=../../lib/config.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/config.sh"
# @include ../../lib/config.sh

# --- Global State (option flags) ---
_dry_run=false
_assume_yes=false
_no_color=false
_recursive=false
_keep_case=false
_target="."

# Extensions considered. Subtitles are included because a sidecar has to keep matching the video it
# belongs to, and renaming one without the other is what breaks the pairing.
_extensions=(mkv mp4 avi m4v ts m2ts srt ass ssa sub idx vtt sup nfo)

# Outcome counters, reported by print_summary and reflected in the exit status.
_seen=0
_renamed=0
_conflicts=0

# Holds the most recent key entered by the user (set by prompt_key).
_answer=""

# Answers "rename everything from here on" once the user has said so.
_rename_all=false

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
Usage: ${SCRIPT_NAME} [OPTIONS] [PATH]

Bring episode filenames to one spelling: dots for separators, lower case, and the
season and episode as S01E02.

PATH is a directory, and only its own files are renamed unless --recursive says
otherwise. If it is omitted, the current directory is used.

Options:
  -r, --recursive   Descend into subdirectories.
  -k, --keep-case   Leave the case alone; only separators and the episode number change.
  -y, --yes         Rename without asking.
  -n, --dry-run     Show the renames without performing them.
  -C, --no-color    Disable colored output.
  -d, --debug       Enable verbose debug logging.
  -h, --help        Show this help message.

Directories are never renamed, and a rename that would land on a name already
taken is refused rather than resolved.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _recursive, _keep_case, _assume_yes, _dry_run, _no_color, _target
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--recursive)
        _recursive=true
        shift
        ;;
      -k|--keep-case)
        _keep_case=true
        shift
        ;;
      -y|--yes)
        _assume_yes=true
        shift
        ;;
      -n|--dry-run)
        _dry_run=true
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
        positional+=("$@")
        break
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

  if [[ ${#positional[@]} -gt 1 ]]; then
    die_usage "Expected at most one directory argument, got ${#positional[@]}."
  fi
  if [[ ${#positional[@]} -eq 1 ]]; then
    _target="${positional[0]}"
  fi
}

########################################
# Applies the optional EXTENSIONS override from a loaded config file.
# Globals:
#   EXTENSIONS, _extensions
# Arguments:
#   None
########################################
apply_config() {
  if declare -p EXTENSIONS &>/dev/null && (( ${#EXTENSIONS[@]} > 0 )); then
    _extensions=("${EXTENSIONS[@]}")
  fi
}

########################################
# Prints the normalised form of one filename.
#
# The extension is normalised separately from the rest, so a run of dots is collapsed within the name
# without the dot before the extension being touched. The episode number is rewritten before the case is
# folded, so that both "1x02" and "1X02" are recognised.
# Globals:
#   _keep_case
# Arguments:
#   name: The filename, without any directory part.
# Outputs:
#   The normalised name.
########################################
normalized_name() {
  local name="$1"
  local stem="${name}" extension=""

  if [[ "${name}" == ?*.* ]]; then
    stem="${name%.*}"
    extension="${name##*.}"
  fi

  # Separators first: spaces and underscores become dots, and a run of them becomes one dot. Dashes are
  # left alone, since a release group is written after one and joining that up would lose the boundary.
  # Separators at the ends are trimmed before the conversion rather than dots trimmed after it, so that a
  # name which was hidden to begin with stays hidden — un-hiding a file is not a rename anyone asked for.
  stem="$(printf '%s' "${stem}" | sed -E 's/^[[:space:]_]+//; s/[[:space:]_]+$//; s/[[:space:]_]+/./g; s/\.\.+/./g; s/\.+$//')"

  # A season-episode number written as 1x02 or 12x07, to the form everything else uses.
  stem="$(printf '%s' "${stem}" | sed -E 's/(^|[^0-9A-Za-z])([0-9]{1,2})[xX]([0-9]{2,3})([^0-9]|$)/\1S\2E\3\4/')"
  # And the season number padded, so S1E02 and 1x02 both end as S01E02.
  stem="$(printf '%s' "${stem}" | sed -E 's/(^|[^0-9A-Za-z])[Ss]([0-9])[Ee]([0-9]{2,3})/\1S0\2E\3/')"

  if [[ "${_keep_case}" != true ]]; then
    stem="${stem,,}"
    extension="${extension,,}"
    # The episode marker is the one part worth keeping upper case: it is a token every parser looks for,
    # and the library's own convention writes it that way.
    stem="$(printf '%s' "${stem}" | sed -E 's/(^|[^0-9a-z])s([0-9]{2})e([0-9]{2,3})/\1S\2E\3/')"
  fi

  if [[ -n "${extension}" ]]; then
    printf '%s.%s' "${stem}" "${extension}"
    return 0
  fi
  printf '%s' "${stem}"
}

########################################
# Reports whether a filename carries one of the configured extensions.
# Globals:
#   _extensions
# Arguments:
#   name: The filename to test.
# Returns:
#   0 when the extension is one of them, 1 otherwise.
########################################
is_candidate() {
  local name="$1"
  [[ "${name}" == ?*.* ]] || return 1
  local extension="${name##*.}"
  local candidate
  for candidate in "${_extensions[@]}"; do
    [[ "${extension,,}" == "${candidate,,}" ]] && return 0
  done
  return 1
}

########################################
# Asks whether to perform one rename, remembering an answer of "all".
# Globals:
#   _assume_yes, _rename_all, _answer, and color globals.
# Arguments:
#   from: The current name.
#   to: The proposed name.
# Returns:
#   0 to rename, 1 to leave it, 2 to stop the run.
########################################
confirm_rename() {
  [[ "${_assume_yes}" == true || "${_rename_all}" == true ]] && return 0

  printf '%s' "${_C_BOLD}${_C_CYAN}Rename ${1} -> ${2}? ${_C_RESET}"
  printf '%s' "${_C_DIM}[ (y)es / (N)o / (a)ll / (q)uit ] ${_C_RESET}"
  if ! prompt_key; then
    printf '\n'
    return 2
  fi
  printf '\n'

  case "${_answer}" in
    y|Y) return 0 ;;
    a|A) _rename_all=true; return 0 ;;
    q|Q) return 2 ;;
    *) return 1 ;;
  esac
}

########################################
# Considers one file, renaming it when asked to.
#
# A destination that already exists is refused rather than resolved: the two files are different releases
# of the same episode as often as they are duplicates, and picking one is not this script's decision.
# Globals:
#   Counters, option flags, and color globals.
# Arguments:
#   path: The file to consider.
# Returns:
#   0 normally, 2 when the user asked to stop.
########################################
process_file() {
  local path="$1"
  local dir name
  dir="$(dirname "${path}")"
  name="$(basename "${path}")"

  is_candidate "${name}" || return 0
  _seen=$(( _seen + 1 ))

  local wanted
  wanted="$(normalized_name "${name}")"
  [[ "${wanted}" == "${name}" ]] && return 0

  # On a case-insensitive filesystem a pure case change names the same file, which is not a conflict.
  if [[ -e "${dir}/${wanted}" && ! "${dir}/${wanted}" -ef "${path}" ]]; then
    log_warn "Not renaming '${name}': '${wanted}' already exists."
    _conflicts=$(( _conflicts + 1 ))
    return 0
  fi

  if [[ "${_dry_run}" == true ]]; then
    printf '%s\n' "${_C_CYAN}${name}${_C_RESET} -> ${_C_GREEN}${wanted}${_C_RESET}"
    _renamed=$(( _renamed + 1 ))
    return 0
  fi

  local answer=0
  confirm_rename "${name}" "${wanted}" || answer=$?
  case "${answer}" in
    2) return 2 ;;
    1) return 0 ;;
  esac

  if mv -- "${path}" "${dir}/${wanted}"; then
    printf '%s\n' "${_C_CYAN}${name}${_C_RESET} -> ${_C_GREEN}${wanted}${_C_RESET}"
    _renamed=$(( _renamed + 1 ))
  else
    log_error "Could not rename '${name}'."
    _conflicts=$(( _conflicts + 1 ))
  fi
  return 0
}

########################################
# Walks the target and considers every candidate file, in path order.
#
# The list is collected before anything is renamed, for two reasons: the prompt reads standard input, and
# renaming files while find is still walking the directory is a way to visit a file twice.
# Globals:
#   _target, _recursive
# Arguments:
#   None
########################################
scan_target() {
  local -a files=()
  local -a find_args=("${_target}")
  [[ "${_recursive}" == true ]] || find_args+=(-maxdepth 1)
  find_args+=(-type f -print0)

  local found
  while IFS= read -r -d '' found; do
    [[ -L "${found}" ]] && continue
    files+=("${found}")
  done < <(find "${find_args[@]}" | sort -z)

  local file status
  for file in "${files[@]+"${files[@]}"}"; do
    status=0
    process_file "${file}" || status=$?
    if (( status == 2 )); then
      printf '%s\n' "${_C_DIM}Stopping here.${_C_RESET}"
      return 0
    fi
  done
}

########################################
# Prints what the run found and did.
# Globals:
#   Counters, _dry_run, and color globals.
# Arguments:
#   None
########################################
print_summary() {
  local verb="Renamed"
  [[ "${_dry_run}" == true ]] && verb="Would rename"
  local line="${_seen} file(s) examined; ${verb,} ${_renamed}"
  (( _conflicts > 0 )) && line+=", ${_conflicts} left alone because the name was taken"
  printf '\n%s\n' "${_C_BOLD}${_C_BRIGHT_GREEN}${line}.${_C_RESET}"
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 when nothing was left unresolved, 1 otherwise.
########################################
main() {
  parse_options "$@"
  setup_colors "${_no_color}"
  [[ "${_no_color}" == true ]] && disable_log_colors

  load_optional_config >/dev/null || exit 1
  apply_config

  if [[ ! -d "${_target}" ]]; then
    log_error "'${_target}' is not a directory."
    exit 1
  fi

  scan_target
  print_summary

  (( _conflicts == 0 ))
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

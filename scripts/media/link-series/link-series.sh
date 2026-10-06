#!/usr/bin/env bash
#
# Links episodes from a download folder into a TV series' library folder.
#
# The *arr apps hard-link what they grab, but anything acquired outside them — a manual download, a
# season pack no indexer announced, a re-encode dropped in by hand — stays where it landed. This links
# those episodes into the season folder they belong to, so the library gains them without a second copy
# of the file occupying the disk.
#
# The show and the season are read from the destination directory rather than passed in: point the
# script at a season folder ("Taskmaster/Season 15") and it looks for that season alone, or at a show
# folder ("Taskmaster") and it takes any season.
#
# A release name is matched as the show's words followed by the season, which is how release names are
# built. Punctuation between the words is not compared, because a library folder is the only place the
# real spaces and apostrophes survive: "Agatha Christie's Marple" has to match "Agatha.Christies.Marple".
# Requiring the season to follow the words directly is what keeps a shorter title out of a longer one —
# a "QI" folder must not collect "QI.XL" releases, and both exist in the same library.
#
# Usage:
#   ./link-series.sh [OPTIONS] DIRECTORY

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

# --- Global State (option flags) ---
_dry_run=false
_no_color=false
_quality=""
_link_type_opt=""   # From --symlink; empty means the config's LINK_TYPE, then the default below.
_source_opt=""      # From --temp-dir; empty means the config's TEMP_DIR.
# No default: the show and season are read from this directory's own name, so it is named rather
# than inferred from wherever the caller happens to be standing.
_target_dir=""

# Resolved settings, filled in by apply_config from the options and the config file.
_source_dir=""
_link_type="hard"

# Media extensions considered for linking. May be overridden by a config file (MEDIA_EXTS array).
_media_exts=(mkv mp4 avi m4v ts m2ts)

# What counts as punctuation between a title's words in a release name. Everything that is not
# alphanumeric, so that a title's own spaces, dots, dashes and apostrophes all compare equal to
# whatever the release used in their place — including nothing at all.
readonly _SEP='[^[:alnum:]]'

# The show and zero-padded season derived from the destination directory by detect_context. An empty
# season means the destination is a show folder rather than a season folder, so any season matches.
_show=""
_season=""

# Outcome counters, reported by print_summary and reflected in the exit status.
_linked=0
_skipped=0
_failed=0

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
Usage: ${SCRIPT_NAME} [OPTIONS] DIRECTORY

Link matching episodes from a download folder into a series' library folder.

The show and season come from DIRECTORY itself: a season folder ("Season 15")
looks for that season, a show folder for any season of it. It is required; pass
"." for the current directory.

Options:
  -t, --temp-dir DIR  Search DIR for episodes instead of the configured TEMP_DIR.
  -q, --quality Q     Only link releases whose name contains Q (e.g. 1080p, 720p).
  -s, --symlink       Create symbolic links instead of hard links. Needed when the
                      download folder and the library are on different filesystems.
  -n, --dry-run       Show what would be linked without linking anything.
  -C, --no-color      Disable colored output.
  -d, --debug         Enable verbose debug logging, including the search pattern.
  -h, --help          Show this help message.

The download folder is read from a configuration file (e.g. /etc/${SCRIPT_NAME}.conf)
unless --temp-dir names one.

A file already present in the destination is left alone, so a repeated run links
only what is new.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _dry_run, _no_color, _quality, _link_type_opt, _source_opt, _target_dir
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--temp-dir)
        require_option_value "$@"
        _source_opt="$2"
        shift 2
        ;;
      -q|--quality)
        require_option_value "$@"
        _quality="$2"
        shift 2
        ;;
      -s|--symlink)
        _link_type_opt="symlink"
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

  if [[ ${#positional[@]} -eq 0 ]]; then
    die_usage "A directory is required. Pass '.' to link into the current directory."
  fi
  _target_dir="${positional[0]}"
}

########################################
# Resolves the settings that come from either an option or the config file, the option winning.
#
# The link type is validated here rather than where it is used, because a typo in a config file would
# otherwise surface as a silently hard-linked file: an unrecognised value has to be refused, not
# treated as "not a symlink".
# Globals:
#   TEMP_DIR, MEDIA_EXTS, LINK_TYPE, _source_opt, _source_dir, _media_exts, _link_type_opt, _link_type
# Arguments:
#   None
# Returns:
#   0 when the resulting settings are usable, 1 otherwise.
########################################
apply_config() {
  _source_dir="${_source_opt:-${TEMP_DIR:-}}"

  if declare -p MEDIA_EXTS &>/dev/null && (( ${#MEDIA_EXTS[@]} > 0 )); then
    _media_exts=("${MEDIA_EXTS[@]}")
  fi

  # An option already chose symlink; without one the config decides, and failing that, hard links.
  _link_type="${_link_type_opt:-${LINK_TYPE:-hard}}"
  if [[ "${_link_type}" != "hard" && "${_link_type}" != "symlink" ]]; then
    log_error "LINK_TYPE must be 'hard' or 'symlink', got '${_link_type}'."
    return 1
  fi

  if [[ -z "${_source_dir}" ]]; then
    log_error "No download folder configured. Set TEMP_DIR in the configuration file, or pass --temp-dir."
    return 1
  fi

  if [[ ! -d "${_source_dir}" ]]; then
    log_error "Download folder '${_source_dir}' does not exist or is not a directory."
    return 1
  fi

  # Resolved to an absolute physical path for two reasons. `find` does not descend into a symlinked
  # directory handed to it as an operand, so a download folder that is a symlink would be reported as
  # holding nothing at all; and a symlink made from a relative source would point at a path resolved
  # against the destination directory rather than the folder that was searched.
  _source_dir="$(cd "${_source_dir}" && pwd -P)"
}

########################################
# Derives the show name and season from the destination directory.
#
# A directory whose name begins with "Season <n>" — or is "Specials", which is season 0 in every *arr
# layout — is taken to be a season of the show named by its parent. Anything else is taken to be the
# show folder itself, and then every season matches. The season is zero-padded to two digits because
# that is how release names spell it (S01), and read in base 10 so that a folder called "Season 08"
# is not mistaken for an invalid octal number.
# Globals:
#   _target_dir, _show, _season
# Arguments:
#   None
# Outputs:
#   Logs what it decided at debug level.
# Returns:
#   0 on success, 1 when the destination is not a usable directory.
########################################
detect_context() {
  if [[ ! -d "${_target_dir}" ]]; then
    log_error "'${_target_dir}' is not a directory."
    return 1
  fi
  if [[ ! -w "${_target_dir}" ]]; then
    log_error "'${_target_dir}' is not writable."
    return 1
  fi

  local resolved
  resolved="$(cd "${_target_dir}" && pwd -P)"
  local name="${resolved##*/}"
  local name_lc="${name,,}"

  if [[ "${name_lc}" =~ ^season[[:space:]._-]*([0-9]+) ]]; then
    _season="$(printf '%02d' "$((10#${BASH_REMATCH[1]}))")"
  elif [[ "${name_lc}" == "specials" ]]; then
    _season="00"
  fi

  if [[ -n "${_season}" ]]; then
    local parent="${resolved%/*}"
    _show="${parent##*/}"
    log_debug "Season folder: show '${_show}', season '${_season}'."
  else
    _show="${name}"
    log_debug "Show folder: show '${_show}', any season."
  fi

  if [[ -z "${_show}" ]]; then
    log_error "Could not determine a show name from '${resolved}'."
    return 1
  fi
}

########################################
# Escapes a string so that it matches literally inside an extended regular expression.
# Globals:
#   None
# Arguments:
#   text: The string to escape.
# Outputs:
#   The escaped string on stdout.
########################################
escape_ere() {
  printf '%s' "$1" | sed -E 's/[][\\^$.|?*+(){}]/\\&/g'
}

########################################
# Renders a title as the regular expression its words make, with punctuation left uncompared.
#
# The words are the runs of non-punctuation, joined by "any punctuation, or none": releases replace a
# title's spaces with dots, underscores or dashes, drop its apostrophes and hyphens outright, and a
# folder name is the only place the original spelling survives. Every regular-expression metacharacter
# is punctuation, so the words that come out of this carry none and need no escaping. Characters
# outside ASCII are not punctuation either, so an accented title keeps its letters.
# Globals:
#   _SEP
# Arguments:
#   title: The lowercased title to render.
# Outputs:
#   The pattern on stdout.
########################################
words_pattern() {
  local title="$1"
  local out="" word="" i char

  for (( i = 0; i < ${#title}; i++ )); do
    char="${title:i:1}"
    if [[ "${char}" == [[:punct:][:space:]] ]]; then
      [[ -n "${word}" ]] && out+="${out:+${_SEP}*}${word}"
      word=""
      continue
    fi
    word+="${char}"
  done
  [[ -n "${word}" ]] && out+="${out:+${_SEP}*}${word}"

  printf '%s' "${out}"
}

########################################
# Renders the season part of the pattern: the forms a release spells a season number in.
#
# Three spellings are accepted — "S15", "Season 15" and "15x07" — and each is followed by a non-digit
# so that season 1 cannot match S15. A known season is matched with any amount of zero padding, since
# a folder called "Season 1" and a release called S01 mean the same thing. With no season known, any
# season matches, which is what a run against a show folder wants.
# Globals:
#   _season, _SEP
# Arguments:
#   None
# Outputs:
#   The pattern on stdout.
########################################
season_pattern() {
  # The padded form is what the messages show; the pattern needs the number as written, with its own
  # padding expressed as "any number of zeros" instead.
  local number="[0-9]{1,2}" padded="0*"
  if [[ -n "${_season}" ]]; then
    number="$(( 10#${_season} ))"
  fi

  printf '(s%s%s[^0-9]|season%s*%s%s[^0-9]|%s%sx[0-9])' "${padded}" "${number}" "${_SEP}" "${padded}" "${number}" "${padded}" "${number}"
}

########################################
# Builds the lowercase extended regular expression a release path must match.
#
# Three parts in the order a release name carries them: the show's words, the season, and — when asked
# for — the quality. A trailing "(2009)" in the folder name is a disambiguator the library needs and
# the release usually omits, so it is matched optionally. Between the show and the season there may be
# punctuation but nothing else, which is what stops a title matching a longer one that starts with it.
# The quality is bracketed by punctuation so that "720p" is not found inside "1720p".
# Globals:
#   _show, _season, _quality, _SEP
# Arguments:
#   None
# Outputs:
#   The pattern on stdout.
########################################
build_pattern() {
  local show="${_show,,}"
  local year=""

  if [[ "${show}" =~ ^(.+[^[:space:]])[[:space:]]*\(([0-9]{4})\)$ ]]; then
    show="${BASH_REMATCH[1]}"
    year="${BASH_REMATCH[2]}"
  fi

  local pattern
  pattern="$(words_pattern "${show}")"
  [[ -n "${year}" ]] && pattern+="(${_SEP}*\\(?${year}\\)?)?"
  pattern+="${_SEP}+$(season_pattern)"
  [[ -n "${_quality}" ]] && pattern+=".*${_SEP}$(escape_ere "${_quality,,}")${_SEP}"

  printf '%s' "${pattern}"
}

########################################
# Reports whether a filename carries one of the configured media extensions.
# Globals:
#   _media_exts
# Arguments:
#   name: The filename to test.
# Returns:
#   0 when the extension is a media one, 1 otherwise.
########################################
is_media_file() {
  local name="$1"
  [[ "${name}" == *.* ]] || return 1
  local ext="${name##*.}"
  local ext_lc="${ext,,}" candidate
  for candidate in "${_media_exts[@]}"; do
    [[ "${ext_lc}" == "${candidate,,}" ]] && return 0
  done
  return 1
}

########################################
# Links one release file into the destination directory, or reports why it was not linked.
#
# The destination is tested with -e and -L, so that an existing broken symlink counts as present
# rather than being reported as a link failure a moment later.
# Globals:
#   _target_dir, _link_type, _dry_run, _linked, _skipped, _failed, and color globals.
# Arguments:
#   source: The release file to link.
# Outputs:
#   One line per file describing what happened.
########################################
link_one() {
  local source="$1"
  local name="${source##*/}"
  local destination="${_target_dir}/${name}"

  if [[ -e "${destination}" || -L "${destination}" ]]; then
    printf '%s\n' "${_C_DIM}Skipping ${name} (already in the destination)${_C_RESET}"
    _skipped=$(( _skipped + 1 ))
    return 0
  fi

  if [[ "${_dry_run}" == true ]]; then
    printf '%s\n' "${_C_CYAN}Would ${_link_type} link ${name}${_C_RESET}"
    _linked=$(( _linked + 1 ))
    return 0
  fi

  local -a link=(ln)
  [[ "${_link_type}" == "symlink" ]] && link+=(-s)

  if "${link[@]}" -- "${source}" "${destination}"; then
    printf '%s\n' "${_C_GREEN}Linked ${name}${_C_RESET}"
    _linked=$(( _linked + 1 ))
    return 0
  fi

  _failed=$(( _failed + 1 ))
  if [[ "${_link_type}" == "hard" ]]; then
    log_error "Could not hard link '${name}'. A hard link cannot cross filesystems; try --symlink."
  else
    log_error "Could not symlink '${name}'."
  fi
}

########################################
# Walks the download folder and links every release that matches the pattern.
#
# Matching is against each file's path relative to the download folder, so a release whose name is
# carried by its containing directory rather than by the episode file — which is how a season pack
# arrives — is found too. Paths are lowercased for the comparison instead of the pattern being made
# case-insensitive, so that the behaviour does not depend on a shell option being set.
# Globals:
#   _source_dir, _media_exts, and everything link_one touches.
# Arguments:
#   None
########################################
scan_and_link() {
  local pattern
  pattern="$(build_pattern)"
  log_debug "Search pattern: ${pattern}"
  log_debug "Searching ${_source_dir} for ${_media_exts[*]} files."

  local file relative
  while IFS= read -r -d '' file; do
    is_media_file "${file##*/}" || continue
    relative="${file#"${_source_dir}"/}"
    if [[ "${relative,,}" =~ ${pattern} ]]; then
      link_one "${file}"
    fi
  done < <(find "${_source_dir}" -type f -print0 | sort -z)
}

########################################
# Prints what the run did, or that it found nothing to do.
# Globals:
#   _linked, _skipped, _failed, _dry_run, _show, _season, and color globals.
# Arguments:
#   None
########################################
print_summary() {
  local scope="${_show}"
  [[ -n "${_season}" ]] && scope+=" season ${_season}"

  # Failures are counted separately, and a run whose only outcome was a failure has still matched
  # something: reporting that as "nothing matched" would send the reader looking for a naming problem
  # instead of at the error just printed.
  if (( _linked == 0 && _skipped == 0 && _failed == 0 )); then
    # The pattern is offered because a miss is nearly always a naming difference between the library
    # folder and the release, and seeing what was searched for is what identifies which.
    printf '%s\n' "${_C_YELLOW}No matching releases found for ${scope}. Use --debug to see the search pattern.${_C_RESET}"
    return
  fi

  local verb="Linked"
  [[ "${_dry_run}" == true ]] && verb="Would link"

  local summary="${verb} ${_linked} file(s) for ${scope}"
  (( _skipped > 0 )) && summary+=", skipped ${_skipped} already present"
  (( _failed > 0 )) && summary+=", ${_failed} failed"
  printf '%s\n' "${_C_BOLD}${_C_BRIGHT_GREEN}${summary}.${_C_RESET}"
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 when nothing failed, 1 when a file could not be linked or the setup was unusable.
########################################
main() {
  parse_options "$@"
  setup_colors "${_no_color}"
  [[ "${_no_color}" == true ]] && disable_log_colors

  # Optional, because --temp-dir can supply the one setting that has no default; apply_config is what
  # refuses a run with no download folder from either source. Stdout is dropped to keep the "Loading
  # configuration from" line out of the report.
  load_optional_config >/dev/null || exit 1
  apply_config || exit 1
  detect_context || exit 1

  scan_and_link
  print_summary

  (( _failed == 0 ))
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

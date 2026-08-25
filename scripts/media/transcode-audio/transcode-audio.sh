#!/usr/bin/env bash
#
# Re-encodes the audio of Matroska files to a codec the playback chain can actually decode.
#
# A Dolby Digital Plus track is what a streaming rip usually carries, and a receiver fed over S/PDIF —
# or a TV app that predates the codec — plays it as silence or as stereo. Re-encoding the audio to plain
# AC-3 fixes that, and there is nothing else wrong with such a file: the video, the subtitles, the
# chapters and every track's language are worth keeping exactly as they are.
#
# So the whole job is one ffmpeg pass that copies every stream and re-encodes only the audio ones. That
# preserves each track's language, title and flags without restating them, and keeps commentary and
# second-language tracks that an extract-and-remux would drop. The bitrate is chosen per track from its
# channel count, since one figure cannot suit both a 5.1 track and a stereo commentary.
#
# Re-encoding is lossy and cannot be undone, so the original is kept unless --replace says otherwise,
# and a file whose audio is already in the target codec is passed over rather than encoded again.
#
# Usage:
#   ./transcode-audio.sh [OPTIONS] [PATH]

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
# shellcheck source=../../lib/program.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/program.sh"
# @include ../../lib/program.sh

# --- Global State (option flags) ---
_replace=false
_assume_yes=false
_dry_run=false
_no_color=false
_format_opt=""
_surround_opt=""
_stereo_opt=""
_target="."

# Resolved settings, filled in by apply_config from the options and the config file.
_format="ac3"
_surround_bitrate="640k"
_stereo_bitrate="256k"

# Marker inserted into the name of a converted file, derived from the format in apply_config.
_marker=""

# Outcome counters, reported by print_summary and reflected in the exit status.
_seen=0
_needing=0
_converted=0
_failed=0

# Holds the most recent key entered by the user (set by prompt_key).
_answer=""

# Answers "convert everything from here on" once the user has said so.
_convert_all=false

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

Re-encode the audio of Matroska files to a codec the playback chain can decode,
keeping the video, subtitles, chapters and every track's metadata.

PATH may be a single .mkv file or a directory, which is searched recursively.
If it is omitted, the current directory is used.

Options:
  -f, --format CODEC    Target audio codec (default ${_format}); anything ffmpeg can encode.
  -b, --bitrate RATE    Bitrate for surround tracks (default ${_surround_bitrate}).
      --stereo RATE     Bitrate for mono and stereo tracks (default ${_stereo_bitrate}).
  -r, --replace         Delete the original once the converted file is verified.
  -y, --yes             Do not ask; convert every file that needs it.
  -n, --dry-run         Report what would be converted without encoding anything.
  -C, --no-color        Disable colored output.
  -d, --debug           Enable verbose debug logging, including the ffmpeg command.
  -h, --help            Show this help message.

A file whose audio is already entirely in the target codec is passed over. The
converted file is named after the original with the codec marker inserted, and
takes the place of the original only with --replace — re-encoding is lossy.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _replace, _assume_yes, _dry_run, _no_color, _format_opt, _surround_opt, _stereo_opt, _target
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--format)
        require_option_value "$@"
        _format_opt="$2"
        shift 2
        ;;
      -b|--bitrate)
        require_option_value "$@"
        _surround_opt="$2"
        shift 2
        ;;
      --stereo)
        require_option_value "$@"
        _stereo_opt="$2"
        shift 2
        ;;
      -r|--replace)
        _replace=true
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
    die_usage "Expected at most one path argument, got ${#positional[@]}."
  fi
  if [[ ${#positional[@]} -eq 1 ]]; then
    _target="${positional[0]}"
  fi
}

########################################
# Resolves the settings that come from either an option or the config file, the option winning.
# Globals:
#   AUDIO_FORMAT, SURROUND_BITRATE, STEREO_BITRATE, and the resolved globals they feed.
# Arguments:
#   None
# Returns:
#   0 when the resulting settings are usable, 1 otherwise.
########################################
apply_config() {
  _format="${_format_opt:-${AUDIO_FORMAT:-${_format}}}"
  _surround_bitrate="${_surround_opt:-${SURROUND_BITRATE:-${_surround_bitrate}}}"
  _stereo_bitrate="${_stereo_opt:-${STEREO_BITRATE:-${_stereo_bitrate}}}"

  # A codec name reaches ffmpeg as an encoder name and this script's marker as an uppercase filename
  # token, so it has to be a plain word; anything else is a typo that would otherwise surface as an
  # ffmpeg error halfway through a library.
  if [[ ! "${_format}" =~ ^[A-Za-z0-9_]+$ ]]; then
    log_error "The audio format must be a plain codec name, got '${_format}'."
    return 1
  fi

  local rate
  for rate in "${_surround_bitrate}" "${_stereo_bitrate}"; do
    if [[ ! "${rate}" =~ ^[0-9]+[kKmM]?$ ]]; then
      log_error "A bitrate must look like 640k or 256000, got '${rate}'."
      return 1
    fi
  done

  # The library's own convention: the codec, then CC, as one filename token.
  _marker="${_format^^}.CC"
}

########################################
# Verifies the external tools are present.
# Globals:
#   None
# Returns:
#   0 when everything needed is present, 1 otherwise.
########################################
check_deps() {
  local missing=()
  command -v ffmpeg &>/dev/null || missing+=(ffmpeg)
  command -v ffprobe &>/dev/null || missing+=(ffprobe)
  command -v jq &>/dev/null || missing+=(jq)

  (( ${#missing[@]} == 0 )) && return 0

  log_error "Missing required tool(s): ${missing[*]}"
  cat >&2 <<EOF

Install hints:
  ffmpeg and ffprobe:
    macOS:  brew install ffmpeg
    Debian: sudo apt install ffmpeg
  jq:
    macOS:  brew install jq
    Debian: sudo apt install jq
EOF
  return 1
}

########################################
# Prints one line per audio stream of a file, as "codec channels".
# Globals:
#   None
# Arguments:
#   file: The file to inspect.
# Outputs:
#   Tab-separated codec and channel count, in stream order.
########################################
audio_streams() {
  local prog
  prog=$(load_program audio-streams.jq)  # @embed audio-streams.jq
  local -a probe=(-v error -select_streams a)
  probe+=(-show_entries "stream=codec_name,channels" -of json)
  probe+=(-- "$1")
  ffprobe "${probe[@]}" 2>/dev/null | jq -r "${prog}" 2>/dev/null
}

########################################
# Reports whether any of a file's audio tracks is in some codec other than the target.
# Globals:
#   _format
# Arguments:
#   streams: The audio_streams output.
# Returns:
#   0 when at least one track needs re-encoding, 1 when every track is already the target codec.
########################################
needs_transcode() {
  local codec rest
  while IFS=$'\t' read -r codec rest; do
    [[ -n "${codec}" ]] || continue
    [[ "${codec}" != "${_format}" ]] && return 0
  done <<<"$1"
  return 1
}

########################################
# Prints the per-track bitrate arguments for ffmpeg, one track at a time.
#
# A single -b:a would give a stereo commentary the same bitrate as a 5.1 feature track, wasting space on
# one or starving the other, so each audio stream is addressed by its position within the audio streams.
# Globals:
#   _surround_bitrate, _stereo_bitrate
# Arguments:
#   streams: The audio_streams output.
# Outputs:
#   One ffmpeg argument per line.
########################################
bitrate_args() {
  local codec channels index=0
  while IFS=$'\t' read -r codec channels; do
    [[ -n "${codec}" ]] || continue
    if [[ "${channels}" -gt 2 ]]; then
      printf '%s\n%s\n' "-b:a:${index}" "${_surround_bitrate}"
    else
      printf '%s\n%s\n' "-b:a:${index}" "${_stereo_bitrate}"
    fi
    index=$(( index + 1 ))
  done <<<"$1"
}

########################################
# Prints the name a converted file should take.
#
# The marker replaces the source codec's own token when the name carries one — "DDP5.1" and friends,
# which is what a release names its Dolby Digital Plus track — because leaving that in place would
# describe the file wrongly. Failing that it goes before the release group, and failing that at the end.
# Only the basename is rewritten: a codec token appearing in a parent directory's name is not this
# file's to correct.
# Globals:
#   _marker
# Arguments:
#   file: The source path.
# Outputs:
#   The converted file's full path.
########################################
converted_name() {
  local dir base ext stem
  dir="$(dirname "$1")"
  base="$(basename "$1")"
  ext="${base##*.}"
  stem="${base%.*}"

  local renamed
  renamed="$(printf '%s' "${stem}" | sed -E "s/(^|[ ._-])(DDP?|DD[+]|E-?AC-?3|AAC|DTS(-HD)?|TrueHD|FLAC)([ ._-]?[0-9]([ ._.-]?[0-9])?)?([ ._-]|$)/\\1${_marker}\\6/I")"
  if [[ "${renamed}" != "${stem}" ]]; then
    printf '%s/%s.%s' "${dir}" "${renamed}" "${ext}"
    return 0
  fi

  # No codec token to replace: sit before the release group, which is what follows the last dash.
  if [[ "${stem}" == *-* ]]; then
    printf '%s/%s.%s-%s.%s' "${dir}" "${stem%-*}" "${_marker}" "${stem##*-}" "${ext}"
    return 0
  fi

  printf '%s/%s.%s.%s' "${dir}" "${stem}" "${_marker}" "${ext}"
}

########################################
# Re-encodes one file's audio, leaving everything else alone.
#
# ffmpeg writes to a temporary name in the destination directory and the result is checked before it is
# moved into place, so an interrupted or failed encode cannot leave a half-written file wearing the name
# of a finished one. -nostdin matters as much: without it ffmpeg reads the standard input this script
# takes its answers from, and swallows the next file's keypress.
# Globals:
#   _format, _dry_run, _replace, and the bitrate settings.
# Arguments:
#   file: The source file.
#   streams: Its audio_streams output.
# Returns:
#   0 when the converted file is in place, 1 otherwise.
########################################
transcode_file() {
  local file="$1" streams="$2"
  local output
  output="$(converted_name "${file}")"

  if [[ -e "${output}" ]]; then
    log_warn "'${output}' already exists; leaving it alone."
    return 1
  fi

  local temp="${output}.partial"
  local -a rates=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && rates+=("${line}")
  done < <(bitrate_args "${streams}")

  local -a command=(ffmpeg -nostdin -v error -y -i "${file}")
  command+=(-map 0 -c copy -c:a "${_format}")
  command+=("${rates[@]+"${rates[@]}"}")
  command+=(-map_chapters 0 "${temp}")
  log_debug "Running: ${command[*]}"

  if ! "${command[@]}"; then
    log_error "ffmpeg failed on '${file}'. The file is untouched."
    rm -f "${temp}"
    return 1
  fi
  if [[ ! -s "${temp}" ]]; then
    log_error "ffmpeg produced nothing for '${file}'. The file is untouched."
    rm -f "${temp}"
    return 1
  fi

  # The encode is verified rather than assumed: ffmpeg can exit 0 having copied the audio through when
  # asked for an encoder it does not have, and a library full of files renamed as converted but still
  # carrying the codec nothing can play is worse than a failure.
  local produced
  produced="$(audio_streams "${temp}")"
  if needs_transcode "${produced}"; then
    log_error "'${file}' still has audio that is not ${_format} after encoding. The file is untouched."
    rm -f "${temp}"
    return 1
  fi

  mv "${temp}" "${output}"
  if [[ "${_replace}" == true ]]; then
    rm -f "${file}"
  fi
  return 0
}

########################################
# Asks whether to convert one file, remembering an answer of "all".
# Globals:
#   _assume_yes, _convert_all, _answer, and color globals.
# Arguments:
#   file: The file being offered.
# Returns:
#   0 to convert it, 1 to leave it, 2 to stop the run.
########################################
confirm_transcode() {
  [[ "${_assume_yes}" == true || "${_convert_all}" == true ]] && return 0

  printf '%s' "${_C_BOLD}${_C_CYAN}Re-encode the audio of $(basename "$1")? ${_C_RESET}"
  printf '%s' "${_C_DIM}[ (y)es / (N)o / (a)ll / (q)uit ] ${_C_RESET}"
  if ! prompt_key; then
    printf '\n'
    return 2
  fi
  printf '\n'

  case "${_answer}" in
    y|Y) return 0 ;;
    a|A) _convert_all=true; return 0 ;;
    q|Q) return 2 ;;
    *) return 1 ;;
  esac
}

########################################
# Reports on one file and converts it when asked to.
# Globals:
#   Counters, option flags, and color globals.
# Arguments:
#   file: The file to process.
# Returns:
#   0 normally, 2 when the user asked to stop.
########################################
process_file() {
  local file="$1"
  _seen=$(( _seen + 1 ))

  local streams
  streams="$(audio_streams "${file}")"
  if [[ -z "${streams}" ]]; then
    log_debug "'${file}' has no audio track."
    return 0
  fi

  local name
  name="$(basename "${file}")"
  local summary
  summary="$(printf '%s' "${streams}" | tr '\t' ' ' | tr '\n' ',' | sed 's/,$//')"

  if ! needs_transcode "${streams}"; then
    printf '%s\n' "${_C_DIM}${name}: already ${_format} (${summary})${_C_RESET}"
    return 0
  fi

  _needing=$(( _needing + 1 ))
  printf '%s\n' "${_C_YELLOW}${name}: ${summary}${_C_RESET}"

  if [[ "${_dry_run}" == true ]]; then
    printf '%s\n' "${_C_CYAN}  would write $(basename "$(converted_name "${file}")")${_C_RESET}"
    _converted=$(( _converted + 1 ))
    return 0
  fi

  local answer=0
  confirm_transcode "${file}" || answer=$?
  case "${answer}" in
    2) return 2 ;;
    1) return 0 ;;
  esac

  printf '%s\n' "${_C_CYAN}  encoding to ${_format}${_C_RESET}"
  if transcode_file "${file}" "${streams}"; then
    _converted=$(( _converted + 1 ))
    local note=" (original kept)"
    [[ "${_replace}" == true ]] && note=" (original removed)"
    printf '%s\n' "${_C_GREEN}  wrote $(basename "$(converted_name "${file}")")${note}${_C_RESET}"
  else
    _failed=$(( _failed + 1 ))
  fi
  return 0
}

########################################
# Walks the target and processes every Matroska file, in path order.
#
# The list is collected before anything is processed, because the confirmation prompt reads standard
# input: a loop fed by a process substitution would read the file list as its answers.
# Globals:
#   _target, _marker
# Arguments:
#   None
########################################
scan_target() {
  local -a files=()

  if [[ -f "${_target}" ]]; then
    files=("${_target}")
  else
    local found
    while IFS= read -r -d '' found; do
      [[ -L "${found}" ]] && continue
      # A file this script produced carries the marker, and re-encoding it again would only lose more.
      [[ "$(basename "${found}")" == *"${_marker}"* ]] && continue
      files+=("${found}")
    done < <(find "${_target}" -type f -iname '*.mkv' -print0 | sort -z)
  fi

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
#   Counters, option flags, and color globals.
# Arguments:
#   None
########################################
print_summary() {
  printf '\n%s\n' "${_C_BOLD}${_C_BRIGHT_GREEN}${_seen} file(s) examined; ${_needing} carry audio that is not ${_format}.${_C_RESET}"

  local verb="Converted"
  [[ "${_dry_run}" == true ]] && verb="Would convert"
  local line="${verb} ${_converted} file(s)"
  (( _failed > 0 )) && line+=", ${_failed} failed"
  printf '%s\n' "${_C_BOLD}${_C_GREEN}${line}.${_C_RESET}"
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 when nothing failed, 1 on a failed encode or an unusable setup.
########################################
main() {
  parse_options "$@"
  setup_colors "${_no_color}"
  [[ "${_no_color}" == true ]] && disable_log_colors

  load_optional_config >/dev/null || exit 1
  apply_config || exit 1
  check_deps || exit 1

  if [[ ! -e "${_target}" ]]; then
    log_error "'${_target}' does not exist."
    exit 1
  fi
  if [[ -f "${_target}" && "${_target,,}" != *.mkv ]]; then
    log_error "'${_target}' is not a Matroska file."
    exit 1
  fi

  scan_target
  print_summary

  (( _failed == 0 ))
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

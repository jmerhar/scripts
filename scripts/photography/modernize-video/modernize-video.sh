#!/usr/bin/env bash
#
# Converts video from old cameras into H.264/AAC MP4, carrying the capture date across.
#
# A compact camera or early phone wrote MJPEG, Indeo, MPEG-1 or H.263 into an AVI, MPG, 3GP or MOV.
# Google Photos takes none of those, and the capture date sits in a container field nothing downstream
# reads — so an upload lands at the moment it was uploaded and the clip is lost in the timeline. That
# date is the part that cannot be reconstructed later, and it is the reason this script exists.
#
# Carrying it across is not a matter of copying the metadata over. An AVI records its date in IDIT as a
# naive local wall clock, and ffmpeg reads that as host-local and writes UTC, so `-map_metadata 0` alone
# moves every date by whatever offset the converting machine happens to be at — a different answer in
# winter than in summer, and for a clip shot just after midnight a different day or even year. The date
# is therefore resolved here and passed as an explicit `creation_time` ending in Z, which ffmpeg stores
# verbatim and copies into the Create, Modify, Track and Media dates that readers actually look at.
#
# An embedded date is also not automatically trustworthy: an empty MP4 header reads back as the epoch,
# and stamping a clip 1970 buries it at the very start of a timeline, which is the failure being fixed.
# So a date is used only when it is plausible, and the file's own modification time is the fallback.
# Every file reports which source its date came from, because a silently wrong date is the one outcome
# worth more than a loud failure.
#
# What to do with a file is decided from the codecs ffprobe finds, never from its name: already-modern
# files are reported and left alone, a file whose streams are fine but whose container is not is
# rewrapped losslessly, and everything else is re-encoded.
#
# Usage:
#   ./modernize-video.sh [OPTIONS] [PATH]

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
# shellcheck source=../../lib/platform.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/platform.sh"
# @include ../../lib/platform.sh
# shellcheck source=../../lib/program.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/program.sh"
# @include ../../lib/program.sh

# --- Global State (option flags) ---
_replace=false
_assume_yes=false
_dry_run=false
_no_color=false
_use_mtime=true
_crf_opt=""
_preset_opt=""
_bitrate_opt=""
_date_opt=""
# No default: the directory a mass re-encode runs over is named rather than assumed.
_target=""

# Resolved settings, filled in by apply_config from the options and the config file.
_crf="18"
_preset="slow"
_audio_bitrate="192k"
_video_codec="libx264"
_color_range="limited"
_min_year="1990"
_extensions="avi mpg mpeg mov qt mp4 m4v 3gp 3g2 wmv asf mts m2ts dv"

# The scale filter, derived from _color_range in apply_config.
_filter=""

# The latest year a capture date may claim, derived in apply_config from the clock.
_max_year=""

# Outcome counters, reported by print_summary and reflected in the exit status.
_seen=0
_converted=0
_remuxed=0
_modern=0
_undated=0
_unreadable=0
_failed=0

# Holds the most recent key entered by the user (set by prompt_key).
_answer=""

# Answers "convert everything from here on" once the user has said so.
_convert_all=false

# --- Color Variables (set by setup_colors "${_no_color}") ---

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME, and the resolved settings quoted as defaults.
# Outputs:
#   Writes usage text to stdout.
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] PATH

Convert video from old cameras to H.264/AAC MP4, preserving the capture date so
the result lands in the right place in a photo timeline.

PATH may be a single video file or a directory, which is searched recursively.
It is required; pass "." for the current directory.

Options:
  -q, --crf N           Quality, lower is better (default ${_crf}); 18 is visually transparent.
      --preset NAME     x264 preset (default ${_preset}).
  -b, --audio-bitrate R Bitrate for stereo audio (default ${_audio_bitrate}); mono gets half.
      --date WHEN       Stamp every file with this date, instead of reading one.
                        Either "YYYY-MM-DD HH:MM:SS" or "YYYY-MM-DD", which means midday.
      --no-mtime        Do not fall back to a file's modification time; report it instead.
  -r, --replace         Delete the original once the converted file is verified.
  -y, --yes             Do not ask; convert everything that needs it.
  -n, --dry-run         Report what would be done without converting anything.
  -C, --no-color        Disable colored output.
  -d, --debug           Enable verbose debug logging, including the ffmpeg command.
  -h, --help            Show this help message.

What happens to a file is decided from the codecs it holds, not from its name:

  already modern  H.264 or HEVC with AAC in an MP4 container; reported and left alone.
  rewrapped       Those same streams in another container; copied, losing nothing.
  converted       Anything else; re-encoded, which is lossy and cannot be undone.

The date is taken from the file's own metadata when that is plausible, and from its
modification time otherwise. Which source was used is reported for every file, since
a date that is quietly wrong is worse than one that is loudly missing.

The converted file is named after the original with an .mp4 extension and takes the
place of the original only with --replace. Only the video and audio are carried
over; subtitle tracks and chapters are not, which is why Matroska is not among the
extensions searched by default.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   Every _*_opt and flag above, and _target.
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q|--crf)
        require_option_value "$@"
        _crf_opt="$2"
        shift 2
        ;;
      --preset)
        require_option_value "$@"
        _preset_opt="$2"
        shift 2
        ;;
      -b|--audio-bitrate)
        require_option_value "$@"
        _bitrate_opt="$2"
        shift 2
        ;;
      --date)
        require_option_value "$@"
        _date_opt="$2"
        shift 2
        ;;
      --no-mtime)
        _use_mtime=false
        shift
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
  if [[ ${#positional[@]} -eq 0 ]]; then
    die_usage "A path is required. Pass '.' to convert the current directory."
  fi
  _target="${positional[0]}"
}

########################################
# Normalises a date to "YYYY-MM-DDTHH:MM:SS", without converting it between zones.
#
# The wall clock a file presents is the wall clock written back, so a trailing Z or offset is dropped
# rather than applied. Converting would need the zone the camera was in, which no field records, and
# would move a clip shot near midnight onto the wrong day. A bare date is read as midday, because
# midnight sits on a boundary that viewers group inconsistently.
# Arguments:
#   value: A date as ffprobe or a user wrote it.
# Outputs:
#   The normalised date, or the input unchanged when it is not a date at all.
########################################
normalize_date() {
  local value="$1"
  if [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf '%sT12:00:00' "${value}"
    return 0
  fi
  value="${value/ /T}"
  printf '%s' "${value:0:19}"
}

########################################
# Reports whether a date is one a camera could plausibly have recorded.
#
# An MP4 header that was never filled in reads back as the epoch, and a clip stamped 1970 sorts to the
# very start of a timeline — the failure this script exists to prevent — so an implausible date is
# refused in favour of a fallback rather than trusted because it was embedded.
# Globals:
#   _min_year, _max_year
# Arguments:
#   value: A normalised date.
# Returns:
#   0 when the date is well formed and inside the plausible range, 1 otherwise.
########################################
plausible_date() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 1
  local year="${value:0:4}"
  (( 10#${year} >= 10#${_min_year} )) || return 1
  (( 10#${year} <= 10#${_max_year} )) || return 1
}

########################################
# Resolves the settings that come from either an option or the config file, the option winning.
# Globals:
#   CRF, PRESET, AUDIO_BITRATE, VIDEO_CODEC, COLOR_RANGE, MIN_YEAR, EXTENSIONS and the globals they feed.
# Returns:
#   0 when the resulting settings are usable, 1 otherwise.
########################################
apply_config() {
  _crf="${_crf_opt:-${CRF:-${_crf}}}"
  _preset="${_preset_opt:-${PRESET:-${_preset}}}"
  _audio_bitrate="${_bitrate_opt:-${AUDIO_BITRATE:-${_audio_bitrate}}}"
  _video_codec="${VIDEO_CODEC:-${_video_codec}}"
  _color_range="${COLOR_RANGE:-${_color_range}}"
  _min_year="${MIN_YEAR:-${_min_year}}"
  _extensions="${EXTENSIONS:-${_extensions}}"
  _max_year=$(( $(date +%Y) + 1 ))

  if [[ ! "${_crf}" =~ ^[0-9]+$ ]] || (( 10#${_crf} > 51 )); then
    log_error "The CRF must be a number from 0 to 51, got '${_crf}'."
    return 1
  fi
  if [[ ! "${_audio_bitrate}" =~ ^[0-9]+[kKmM]?$ ]]; then
    log_error "The audio bitrate must look like 192k or 192000, got '${_audio_bitrate}'."
    return 1
  fi
  if [[ ! "${_video_codec}" =~ ^[A-Za-z0-9_]+$ ]]; then
    log_error "The video codec must be a plain encoder name, got '${_video_codec}'."
    return 1
  fi
  if [[ ! "${_min_year}" =~ ^[0-9]{4}$ ]]; then
    log_error "The minimum year must be four digits, got '${_min_year}'."
    return 1
  fi
  # An empty list would reach find as an empty \( \) group, which is a syntax error rather than a
  # walk that matches nothing.
  if [[ ! "${_extensions}" =~ [^[:space:]] ]]; then
    log_error "EXTENSIONS must name at least one extension."
    return 1
  fi

  # A full-range encode keeps the source levels untouched, which is bit-exact but leaves a player that
  # ignores the range flag showing washed-out contrast. Limited range costs a rounding-level remap and
  # cannot be misread, so it is the default; the scale filter states only the output range, letting
  # swscale take the input range from the source rather than assuming every source is full.
  case "${_color_range}" in
    limited)
      _filter="scale=w=trunc(iw/2)*2:h=trunc(ih/2)*2:out_range=limited,format=yuv420p"
      ;;
    full)
      _filter="scale=w=trunc(iw/2)*2:h=trunc(ih/2)*2,format=yuv420p"
      ;;
    *)
      log_error "COLOR_RANGE must be 'limited' or 'full', got '${_color_range}'."
      return 1
      ;;
  esac

  if [[ -n "${_date_opt}" ]]; then
    _date_opt="$(normalize_date "${_date_opt}")"
    if ! plausible_date "${_date_opt}"; then
      log_error "The date must be 'YYYY-MM-DD HH:MM:SS' or 'YYYY-MM-DD' between ${_min_year} and ${_max_year}."
      return 1
    fi
  fi
}

########################################
# Verifies the external tools are present.
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
# Prints one file's facts as "container duration date vcodec acodec channels", tab separated.
#
# ffprobe prints an empty JSON document and exits non-zero for a file that is not video at all, so the
# status is what distinguishes those rather than the output, which parses into a line of defaults.
# Globals:
#   None
# Arguments:
#   file: The file to inspect.
# Outputs:
#   The tab-separated facts.
# Returns:
#   Non-zero when the file cannot be read as media.
########################################
probe_file() {
  local prog
  prog=$(load_program probe.jq)  # @embed probe.jq
  # codec_type is requested even though the program selects on it: naming any field in -show_entries
  # makes ffprobe emit only the named ones, so a document without it holds no stream the program can
  # recognise and every file would read as having neither video nor audio.
  local -a probe=(-v error)
  probe+=(-show_entries "format=format_name,duration")
  probe+=(-show_entries "format_tags=creation_time,major_brand")
  probe+=(-show_entries "stream=codec_type,codec_name,channels")
  probe+=(-of json -- "$1")
  # -nostdin is deliberately absent: ffprobe has no such option and consumes the next argument as its
  # value, failing on every file.
  ffprobe "${probe[@]}" 2>/dev/null | jq -r "${prog}" 2>/dev/null
}

########################################
# Prints whether a video stream should be copied or re-encoded.
# Arguments:
#   codec: The probed video codec name.
# Outputs:
#   "copy" or "encode".
########################################
video_action() {
  case "$1" in
    h264|hevc) printf 'copy' ;;
    *) printf 'encode' ;;
  esac
}

########################################
# Prints what should happen to a file's audio.
# Arguments:
#   codec: The probed audio codec name, or "none" when the file has no audio.
# Outputs:
#   "none", "copy" or "encode".
########################################
audio_action() {
  case "$1" in
    none) printf 'none' ;;
    aac) printf 'copy' ;;
    *) printf 'encode' ;;
  esac
}

########################################
# Prints what a whole file needs: "modern", "remux" or "encode".
#
# Decided from the codecs and the container rather than the extension, so a 3GPP file named .mp4 is
# rewrapped instead of being mistaken for a finished one.
# Arguments:
#   container: The container family from probe_file.
#   vcodec: The probed video codec.
#   acodec: The probed audio codec.
# Outputs:
#   The plan.
########################################
plan_for() {
  local container="$1" vcodec="$2" acodec="$3"
  if [[ "$(video_action "${vcodec}")" == copy && "$(audio_action "${acodec}")" != encode ]]; then
    if [[ "${container}" == mp4 ]]; then
      printf 'modern'
    else
      printf 'remux'
    fi
    return 0
  fi
  printf 'encode'
}

########################################
# Prints the codec name ffprobe will report for an encoder, so the result can be checked.
# Arguments:
#   encoder: An ffmpeg encoder name.
# Outputs:
#   The codec name.
########################################
codec_of_encoder() {
  case "$1" in
    libx264) printf 'h264' ;;
    libx265) printf 'hevc' ;;
    *) printf '%s' "$1" ;;
  esac
}

########################################
# Prints the audio bitrate to use for a track with the given channel count.
#
# One figure cannot suit both a stereo track and the mono one an early phone recorded, so mono takes
# half — generous for a source sampled at 8 kHz, and not worth a second setting.
# Globals:
#   _audio_bitrate
# Arguments:
#   channels: The probed channel count.
# Outputs:
#   The bitrate.
########################################
audio_bitrate_for() {
  local channels="$1"
  if (( 10#${channels:-2} > 1 )); then
    printf '%s' "${_audio_bitrate}"
    return 0
  fi
  local number="${_audio_bitrate%[kKmM]}"
  local suffix="${_audio_bitrate#"${number}"}"
  printf '%s%s' "$(( number / 2 ))" "${suffix}"
}

########################################
# Formats a byte count as a human-readable size.
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
# Prints the date to stamp a file with, and where it came from, tab separated.
#
# Globals:
#   _date_opt, _use_mtime
# Arguments:
#   file: The file being converted.
#   embedded: Its embedded creation_time, possibly empty or implausible.
# Outputs:
#   "<date>\t<source>", where source is "given", "embedded" or "mtime".
# Returns:
#   1 when no date can be established.
########################################
resolve_date() {
  local file="$1" embedded="$2"

  if [[ -n "${_date_opt}" ]]; then
    printf '%s\tgiven' "${_date_opt}"
    return 0
  fi

  local candidate
  candidate="$(normalize_date "${embedded}")"
  if plausible_date "${candidate}"; then
    printf '%s\tembedded' "${candidate}"
    return 0
  fi
  if [[ -n "${embedded}" && "${embedded}" != none ]]; then
    log_warn "'${file}' claims ${candidate}, which is not a plausible capture date; ignoring it."
  fi

  [[ "${_use_mtime}" == true ]] || return 1

  candidate="$(stat_mtime_iso "${file}")" || return 1
  plausible_date "${candidate}" || return 1
  printf '%s\tmtime' "${candidate}"
}

########################################
# Prints the name a converted file should take.
#
# A source already called .mp4 that still needs work gets a marker, because the plain name is the
# source itself — and on a case-insensitive filesystem X.MP4 and X.mp4 are one file, so writing the
# output would truncate the source while ffmpeg was still reading it. The comparison is therefore
# case-insensitive on both platforms rather than only where it has to be.
# Arguments:
#   file: The source path.
# Outputs:
#   The converted file's full path.
########################################
output_name() {
  local dir base stem candidate
  dir="$(dirname "$1")"
  base="$(basename "$1")"
  stem="${base%.*}"
  candidate="${dir}/${stem}.mp4"
  if [[ "${candidate,,}" == "${1,,}" ]]; then
    candidate="${dir}/${stem}.converted.mp4"
  fi
  printf '%s' "${candidate}"
}

########################################
# Reports whether two durations are close enough to be the same recording.
#
# A tolerance rather than equality, because a re-encode rounds to whole frames and a rewrap can round
# to the container timescale. The check exists to catch a whole recording running at the wrong speed,
# which is what reading a frame rate off a stream that misreports it produces.
# Arguments:
#   expected: The source duration in seconds.
#   actual: The converted file's duration in seconds.
# Returns:
#   0 when they match within tolerance.
########################################
durations_match() {
  awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) { d = -d }; tol = a * 0.02; if (tol < 1) { tol = 1 }; exit (d <= tol) ? 0 : 1 }'
}

########################################
# Sets a file's modification time to its capture date.
#
# touch -t takes the same stamp on GNU and BSD, where touch -d does not, so no platform split is needed.
# Arguments:
#   file: The file to stamp.
#   date: A normalised date.
########################################
set_file_date() {
  local file="$1" date="$2"
  local stamp="${date:0:4}${date:5:2}${date:8:2}${date:11:2}${date:14:2}.${date:17:2}"
  touch -t "${stamp}" "${file}"
}

########################################
# Checks a converted file before it is allowed to take its final name.
#
# ffmpeg exiting zero is not enough on its own: asked for an encoder it does not have it can copy the
# stream through instead, and a library full of files named as converted but still holding what nothing
# plays is worse than a failure. The date is checked for the same reason — it is the whole point of the
# conversion, so it is proved rather than assumed.
# Arguments:
#   temp: The file ffmpeg just wrote.
#   expect_date: The date it should carry.
#   expect_duration: The source duration.
#   expect_video: The video codec it should hold.
# Returns:
#   0 when the file is sound, 1 otherwise.
########################################
verify_output() {
  local temp="$1" expect_date="$2" expect_duration="$3" expect_video="$4"

  if [[ ! -s "${temp}" ]]; then
    log_error "ffmpeg produced nothing."
    return 1
  fi

  local facts
  if ! facts="$(probe_file "${temp}")" || (( ${#facts} == 0 )); then
    log_error "the converted file cannot be read back as media."
    return 1
  fi

  local container duration date vcodec acodec channels
  IFS=$'\t' read -r container duration date vcodec acodec channels <<<"${facts}"

  if [[ "${vcodec}" != "${expect_video}" ]]; then
    log_error "the converted file holds ${vcodec} video where ${expect_video} was asked for."
    return 1
  fi
  if ! durations_match "${expect_duration}" "${duration}"; then
    log_error "the converted file runs ${duration}s against the source's ${expect_duration}s."
    return 1
  fi

  local written
  written="$(normalize_date "${date}")"
  if [[ "${written}" != "${expect_date}" ]]; then
    log_error "the converted file carries '${written}' where '${expect_date}' was asked for."
    return 1
  fi
}

########################################
# Converts one file, leaving the original in place unless --replace says otherwise.
#
# ffmpeg writes to a temporary name in the destination directory and the result is checked before it is
# moved into place, so an interrupted run cannot leave a half-written file wearing a finished one's
# name. The last step is a rename rather than a copy because a rename is atomic: the finished name
# appears already complete, where a copy would be observable half-written. What keeps an existing file
# from being written through is the refusal below, not the rename — a destination that already exists is
# never touched, which is what matters where a library file is a hard link to something still wanted.
#
# -nostdin matters as much: without it ffmpeg reads the standard input this script takes its answers
# from and swallows the next file's keypress.
# Globals:
#   The resolved settings and option flags.
# Arguments:
#   file, plan, vcodec, acodec, channels, duration, date
# Returns:
#   0 when the converted file is in place, 1 otherwise.
########################################
convert_file() {
  local file="$1" plan="$2" vcodec="$3" acodec="$4" channels="$5" duration="$6" date="$7"

  local output
  output="$(output_name "${file}")"
  if [[ -e "${output}" ]]; then
    log_warn "'${output}' already exists; leaving it alone."
    return 1
  fi

  local temp="${output}.partial"
  local expect_video="${vcodec}"

  local -a command=(ffmpeg -nostdin -v error -y -i "${file}")
  command+=(-map 0:v:0 -map "0:a?")

  if [[ "${plan}" == remux ]]; then
    command+=(-c copy)
  else
    if [[ "$(video_action "${vcodec}")" == copy ]]; then
      command+=(-c:v copy)
    else
      expect_video="$(codec_of_encoder "${_video_codec}")"
      command+=(-c:v "${_video_codec}" -crf "${_crf}" -preset "${_preset}")
      command+=(-vf "${_filter}")
      [[ "${_color_range}" == limited ]] && command+=(-color_range tv)
    fi
    case "$(audio_action "${acodec}")" in
      none) command+=(-an) ;;
      copy) command+=(-c:a copy) ;;
      *) command+=(-c:a aac -b:a "$(audio_bitrate_for "${channels}")") ;;
    esac
  fi

  # The frame rate is deliberately never set. A stream can misreport it — MPEG-1 here reports double its
  # real rate — and forcing that figure would stretch the whole recording. Left alone, ffmpeg keeps the
  # source timing.
  #
  # The explicit creation_time overrides whatever -map_metadata carried over, which is what keeps the
  # camera's own tags without inheriting the shifted date ffmpeg derives from a naive one.
  command+=(-map_metadata 0 -metadata "creation_time=${date}Z")
  # The format is named rather than left to the extension: the file being written ends in .partial so
  # that an interrupted run cannot leave a finished name on a half-written file, and ffmpeg cannot
  # choose a muxer from that.
  command+=(-f mp4 -movflags +faststart "${temp}")
  log_debug "Running: ${command[*]}"

  if ! "${command[@]}"; then
    log_error "ffmpeg failed on '${file}'. The file is untouched."
    rm -f "${temp}"
    return 1
  fi

  if ! verify_output "${temp}" "${date}" "${duration}" "${expect_video}"; then
    log_error "'${file}' did not convert correctly. The file is untouched."
    rm -f "${temp}"
    return 1
  fi

  mv "${temp}" "${output}"
  set_file_date "${output}" "${date}"
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
confirm_convert() {
  [[ "${_assume_yes}" == true || "${_convert_all}" == true ]] && return 0

  printf '%s' "${_C_BOLD}${_C_CYAN}Convert $(basename "$1")? ${_C_RESET}"
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

  local name
  name="$(basename "${file}")"

  # The length is tested rather than [[ -n ]], because a value that happened to span lines would have
  # its later lines escape into the output under coverage, where conditionals are traced raw.
  local facts
  if ! facts="$(probe_file "${file}")" || (( ${#facts} == 0 )); then
    printf '%s\n' "${_C_DIM}${name}: not a video file${_C_RESET}"
    _unreadable=$(( _unreadable + 1 ))
    return 0
  fi

  local container duration date vcodec acodec channels
  IFS=$'\t' read -r container duration date vcodec acodec channels <<<"${facts}"

  if [[ "${vcodec}" == none ]]; then
    printf '%s\n' "${_C_DIM}${name}: no video stream${_C_RESET}"
    _unreadable=$(( _unreadable + 1 ))
    return 0
  fi

  local plan
  plan="$(plan_for "${container}" "${vcodec}" "${acodec}")"

  local summary="${vcodec}"
  [[ "${acodec}" == none ]] && summary+=", no audio" || summary+=", ${acodec}"

  if [[ "${plan}" == modern ]]; then
    printf '%s\n' "${_C_DIM}${name}: already ${summary} in MP4; left alone${_C_RESET}"
    _modern=$(( _modern + 1 ))
    return 0
  fi

  local resolved
  if ! resolved="$(resolve_date "${file}" "${date}")"; then
    printf '%s\n' "${_C_YELLOW}${name}: no usable capture date; left alone${_C_RESET}"
    _undated=$(( _undated + 1 ))
    return 0
  fi

  local stamp source
  IFS=$'\t' read -r stamp source <<<"${resolved}"

  local wanted
  wanted="$(output_name "${file}")"
  if [[ -e "${wanted}" ]]; then
    printf '%s\n' "${_C_DIM}${name}: already converted as $(basename "${wanted}")${_C_RESET}"
    _modern=$(( _modern + 1 ))
    return 0
  fi

  local verb="convert"
  [[ "${plan}" == remux ]] && verb="rewrap"
  printf '%s\n' "${_C_YELLOW}${name}: ${summary} — ${verb}, dated ${stamp} [${source}]${_C_RESET}"

  if [[ "${_dry_run}" == true ]]; then
    printf '%s\n' "${_C_CYAN}  would write $(basename "${wanted}")${_C_RESET}"
    [[ "${plan}" == remux ]] && _remuxed=$(( _remuxed + 1 )) || _converted=$(( _converted + 1 ))
    return 0
  fi

  local answer=0
  confirm_convert "${file}" || answer=$?
  case "${answer}" in
    2) return 2 ;;
    1) return 0 ;;
  esac

  if convert_file "${file}" "${plan}" "${vcodec}" "${acodec}" "${channels}" "${duration}" "${stamp}"; then
    local note=" (original kept)"
    [[ "${_replace}" == true ]] && note=" (original removed)"
    printf '%s\n' "${_C_GREEN}  wrote $(basename "${wanted}")${note}${_C_RESET}"
    [[ "${plan}" == remux ]] && _remuxed=$(( _remuxed + 1 )) || _converted=$(( _converted + 1 ))
  else
    _failed=$(( _failed + 1 ))
  fi
  return 0
}

########################################
# Walks the target and processes every candidate file, in path order.
#
# The list is collected before anything is processed, because the confirmation prompt reads standard
# input: a loop fed by a process substitution would read the file list as its answers.
# Globals:
#   _target, _extensions
########################################
scan_target() {
  local -a files=()

  if [[ -f "${_target}" ]]; then
    files=("${_target}")
  else
    # Announced before the walk, which on a large tree takes long enough to look like a hang.
    printf '%s\n' "${_C_DIM}Searching $(cd "${_target}" && pwd -P) for video to convert...${_C_RESET}"
    local -a extensions=()
    read -r -a extensions <<<"${_extensions}"
    local -a match=()
    local extension
    for extension in "${extensions[@]+"${extensions[@]}"}"; do
      (( ${#match[@]} > 0 )) && match+=(-o)
      match+=(-iname "*.${extension}")
    done

    local found
    while IFS= read -r -d '' found; do
      [[ -L "${found}" ]] && continue
      files+=("${found}")
    done < <(find "${_target}" -type f \( "${match[@]}" \) -print0 | sort -z)
  fi

  # Before the first prompt, because that prompt offers "all" and its size has to be known to answer.
  local total=0 size=0
  for file in "${files[@]+"${files[@]}"}"; do
    size="$(stat_size "${file}" 2>/dev/null || printf '0')"
    total=$(( total + size ))
  done
  printf '%s\n\n' "${_C_BOLD}Found ${#files[@]} candidate file(s), $(format_size "${total}").${_C_RESET}"

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
#
# Every file is accounted for in one of the counts. A file that was passed over says so and says why,
# because a conversion that quietly skipped half a folder looks exactly like one that had nothing to do.
# Globals:
#   Counters, option flags, and color globals.
########################################
print_summary() {
  printf '\n%s\n' "${_C_BOLD}${_C_BRIGHT_GREEN}${_seen} file(s) examined.${_C_RESET}"

  local verb="Converted"
  local rewrote="rewrapped"
  if [[ "${_dry_run}" == true ]]; then
    verb="Would convert"
    rewrote="would rewrap"
  fi
  printf '%s\n' "${_C_BOLD}${_C_GREEN}${verb} ${_converted}, ${rewrote} ${_remuxed} losslessly.${_C_RESET}"

  (( _modern > 0 )) && printf '%s\n' "${_C_DIM}${_modern} already in a modern form; left alone.${_C_RESET}"
  (( _undated > 0 )) && printf '%s\n' "${_C_YELLOW}${_undated} had no usable capture date; left alone.${_C_RESET}"
  (( _unreadable > 0 )) && printf '%s\n' "${_C_DIM}${_unreadable} could not be read as video.${_C_RESET}"
  (( _failed > 0 )) && printf '%s\n' "${_C_BOLD}${_C_RED}${_failed} failed.${_C_RESET}"
  return 0
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 when nothing failed, 1 on a failed conversion or an unusable setup.
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

  scan_target
  print_summary

  (( _failed == 0 ))
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

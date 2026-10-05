#!/usr/bin/env bash
#
# Resynchronizes drifting subtitles to a video's actual speech.
#
# Many subtitles drift out of sync in ways a single global offset cannot fix —
# most notably "segmented" drift, where broadcast rips have ad breaks cut out so
# the subtitles fall progressively further behind in steps. This script corrects
# that by transcribing the video's audio with Whisper to build a speech-accurate
# reference, then aligning the drifted subtitle to that reference with alass
# (which can apply a different offset to each segment).
#
# Segmented alignment is the wrong tool for a subtitle whose only fault is a
# constant offset: allowed to split such a file, an aligner can place an early
# stretch of it on the wrong side of a pause and leave those minutes further out
# than it found them. So each subtitle is aligned twice, once as a single global
# offset and once segmented, and the two results are scored against the speech
# reference — the segmented one is kept only when it measurably matches better.
# That is what --ad-breaks overrides.
#
# The same pipeline also handles the simpler cases (a constant global offset, or
# a linear speed/framerate error) — see --help.
#
# Usage:
#   ./subtitle-sync.sh [OPTIONS] PATH
#
# PATH may be a directory (processed recursively), a single video file, or a
# single subtitle file, and is required.

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../../lib/lang.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/lang.sh"
# @include ../../lib/lang.sh
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

# --- Global State (option flags; defaults may be overridden by config) ---
_embedded=false        # also sync embedded subtitle tracks
_remux=false           # embedded output: mux into a container copy (else sidecar)
_lang="en"             # target subtitle language
_model="base.en"       # Whisper model
_split_penalty=7       # alass split penalty
_max_words=8           # reference cue granularity (words per line)
_threads=""            # Whisper/alass threads (default: detected CPU count)
_ad_breaks="auto"      # segmented alignment: auto (score both), yes (force), no (single offset)
_ad_breaks_set=false   # whether a mode was asked for by name, rather than defaulted
_min_shift="0.5"       # smallest shift (s) worth rewriting a file for
_fps_guess=false       # re-enable alass FPS guessing (true speed/framerate drift)
_backup_suffix=".bak"  # suffix for backed-up originals
_force=false           # reprocess already-synced files
_use_cache=true        # use/refresh the reference cache
_dry_run=false         # report planned actions only
_no_color=false        # disable colored output
_video=""              # explicit video for a lone-subtitle invocation
_target=""             # positional PATH; no default, since transcription is expensive

# Externally-overridable commands and parameters (see the .conf file).
_whisper_bin="whisper-ctranslate2"
_alass_bin="alass"
_compute_type="int8"
_device="cpu"          # whisper device: cpu, cuda, or auto
_cache_dir=""          # default set in setup_runtime()
_whisper_extra_args=() # extra args appended to the whisper command

# Media containers to discover when walking a directory.
_media_exts=(mkv mp4 m4v avi mov wmv mpg mpeg ts m2ts webm flv ogv 3gp divx vob)

# Text subtitle formats alass can resynchronize (bitmap formats like sup/idx are
# intentionally excluded — they carry no resyncable text timing here).
_subtitle_exts=(srt ass ssa vtt)

# Sidecar filename tokens that describe a subtitle's role rather than its
# language (e.g. "Movie.en.forced.srt"); skipped during language detection.
_sidecar_flags=(forced sdh cc hi default foreign full)

# Run counters for the summary.
_n_synced=0
_n_insync=0            # already within --min-shift of the speech, so left untouched
_n_skipped=0
_n_failed=0
_n_videos_worked=0     # videos that actually transcribed/aligned (for averages)

# Timing in epoch seconds; populated per-step and per-video.
_batch_start=0
_t_extract=0           # last audio-extraction seconds
_t_transcribe=0        # last transcription seconds (0 when the reference was cached)
_t_align_total=0       # accumulated alass alignment seconds for the current video
_ref_cached=false      # whether the current video's reference came from cache

# Scratch directory for transient files (audio, intermediate SRTs); cleaned up
# on exit.
_workdir=""

# How much better a segmented alignment must score than a single global offset to
# be believed, in parts per thousand. Measured across libraries of both kinds:
# subtitles with a constant offset score within a couple of parts per thousand
# either way, while real ad-break drift gains fourteen and upwards, so the
# threshold sits in a wide empty gap rather than on a judgement call.
readonly _split_margin_permille=1005

# The chosen alignment and its profile, published by align_subtitle.
_align_file=""
_align_score=0
_align_cues=-1
_align_runs=-1
_align_max_abs=-1
_align_lo=0
_align_hi=0
_min_shift_ms=0        # --min-shift in milliseconds; derived in setup_runtime

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] PATH

Resynchronize drifting subtitles to a video's speech using a Whisper transcript
as reference and alass for segment-aware alignment.

PATH may be:
  - a directory  (processed recursively; every video is matched to its subtitles)
  - a video file (its matching subtitles are synced)
  - a subtitle   (synced against its sibling video; see --video)
It is required; pass "." for the current directory.

By default only EXTERNAL sidecar subtitles in the target language are synced,
edited in place with the original backed up.

Options:
      --embedded         Also sync embedded subtitle tracks (off by default).
      --remux            With --embedded, mux the corrected track into a copy of
                         the container instead of writing a sidecar .srt.
  -g, --lang LANG        Target subtitle language (default: ${_lang}). Use with
                         --model for non-English (e.g. --lang de --model base).
  -m, --model NAME       Whisper model (default: ${_model}).
      --ad-breaks MODE   Whether to align in segments: 'auto' aligns both ways
                         and keeps whichever matches the speech better, 'yes'
                         forces segments, 'no' forces one global offset
                         (default: ${_ad_breaks}).
  -p, --split-penalty N  alass split penalty; lower splits more aggressively
                         (default: ${_split_penalty}). Not consulted by
                         --ad-breaks no.
      --max-words N      Reference cue granularity, words per line (default: ${_max_words}).
  -t, --threads N        CPU threads for Whisper/alass (default: detected).
      --min-shift S      Smallest shift in seconds worth rewriting a file for;
                         below it the subtitle is reported as already in sync and
                         left untouched (default: ${_min_shift}). 0 rewrites for
                         any shift, which readmits Whisper's own ~0.3s lead.
      --fps-guess        Re-enable alass framerate guessing (for true speed /
                         framerate drift; disabled by default). Implies
                         --ad-breaks no unless one is given.
      --backup-suffix S  Suffix for the backed-up original (default: ${_backup_suffix}).
  -f, --force            Reprocess even if already synced.
      --video FILE       The video to sync against (when PATH is a subtitle).
      --no-cache         Do not use or refresh the Whisper reference cache.
  -n, --dry-run          Report what would be done; change nothing.
  -C, --no-color         Disable colored output.
  -h, --help             Show this help message.

Drift types:
  - Segmented / ad-break drift  -> handled by default (the main use case).
  - Constant global offset      -> handled by default; add --ad-breaks no if a
                                   file is wrongly split into segments.
  - Wrong speed / framerate     -> add --fps-guess.

Requirements (external; not installed by the package):
  - ffmpeg / ffprobe
  - alass                  https://github.com/kaegi/alass
  - whisper-ctranslate2    faster-whisper CLI; e.g. 'uv tool install
                           whisper-ctranslate2', 'pipx install whisper-ctranslate2'
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   All _-prefixed option flags.
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --embedded) _embedded=true; shift ;;
      --remux) _remux=true; shift ;;
      -g|--lang) require_option_value "$@"; _lang="$2"; shift 2 ;;
      -m|--model) require_option_value "$@"; _model="$2"; shift 2 ;;
      -p|--split-penalty) require_option_value "$@"; _split_penalty="$2"; shift 2 ;;
      --max-words) require_option_value "$@"; _max_words="$2"; shift 2 ;;
      -t|--threads) require_option_value "$@"; _threads="$2"; shift 2 ;;
      --ad-breaks) require_option_value "$@"; _ad_breaks="$2"; _ad_breaks_set=true; shift 2 ;;
      --min-shift) require_option_value "$@"; _min_shift="$2"; shift 2 ;;
      --fps-guess) _fps_guess=true; shift ;;
      --backup-suffix) require_option_value "$@"; _backup_suffix="$2"; shift 2 ;;
      -f|--force) _force=true; shift ;;
      --video) require_option_value "$@"; _video="$2"; shift 2 ;;
      --no-cache) _use_cache=false; shift ;;
      -n|--dry-run) _dry_run=true; shift ;;
      -C|--no-color) _no_color=true; shift ;;
      -h|--help) show_usage; exit 0 ;;
      --) shift; positional+=("$@"); break ;;
      -*) log_error "Unknown option '$1'. Use --help for usage."; exit 1 ;;
      *) positional+=("$1"); shift ;;
    esac
  done

  if [[ ${#positional[@]} -gt 1 ]]; then
    log_error "Expected at most one PATH argument, got ${#positional[@]}."
    exit 1
  fi
  if [[ ${#positional[@]} -eq 0 ]]; then
    log_error "A path is required. Pass '.' to sync the current directory."
    show_usage >&2
    exit 1
  fi
  _target="${positional[0]}"

  if [[ "${_remux}" == true && "${_embedded}" != true ]]; then
    log_error "--remux only applies with --embedded."
    exit 1
  fi
  if [[ ! "${_split_penalty}" =~ ^[0-9]+$ ]]; then
    log_error "--split-penalty must be a non-negative integer, got '${_split_penalty}'."
    exit 1
  fi
  if [[ ! "${_max_words}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "--max-words must be a positive integer, got '${_max_words}'."
    exit 1
  fi
  if [[ -n "${_threads}" && ! "${_threads}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "--threads must be a positive integer, got '${_threads}'."
    exit 1
  fi
  validate_settings
}

########################################
# Rejects invalid values for the settings a config file can also supply, so a
# typo in the config is refused rather than silently taking a branch nobody
# asked for. Called once the flags and the config have been merged.
# Globals:
#   _ad_breaks, _min_shift
########################################
validate_settings() {
  case "${_ad_breaks}" in
    auto|yes|no) ;;
    *) log_error "--ad-breaks must be auto, yes or no, got '${_ad_breaks}'."; exit 1 ;;
  esac
  if [[ ! "${_min_shift}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    log_error "--min-shift must be a non-negative number, got '${_min_shift}'."
    exit 1
  fi
}

########################################
# Applies optional overrides from a loaded config file onto the defaults.
# Each scalar is honored only when set and non-empty; arrays only when declared
# non-empty, so a partial or absent config leaves built-in defaults intact.
# Globals:
#   Reads WHISPER_BIN, ALASS_BIN, WHISPER_MODEL, COMPUTE_TYPE, SPLIT_PENALTY,
#   MAX_WORDS_PER_LINE, THREADS, ANCHOR_MAX, BACKUP_SUFFIX, CACHE_DIR,
#   LANG_DEFAULT, WHISPER_EXTRA_ARGS, MEDIA_EXTS, SUBTITLE_EXTS.
#   Writes the corresponding _-prefixed globals (command-line flags win, since
#   this runs before parse_options is consulted only for unset values).
########################################
apply_config() {
  [[ -n "${WHISPER_BIN:-}" ]] && _whisper_bin="${WHISPER_BIN}"
  [[ -n "${ALASS_BIN:-}" ]] && _alass_bin="${ALASS_BIN}"
  [[ -n "${COMPUTE_TYPE:-}" ]] && _compute_type="${COMPUTE_TYPE}"
  [[ -n "${DEVICE:-}" ]] && _device="${DEVICE}"
  [[ -n "${CACHE_DIR:-}" ]] && _cache_dir="${CACHE_DIR}"

  if declare -p WHISPER_EXTRA_ARGS &>/dev/null && (( ${#WHISPER_EXTRA_ARGS[@]} > 0 )); then
    _whisper_extra_args=("${WHISPER_EXTRA_ARGS[@]}")
  fi
  if declare -p MEDIA_EXTS &>/dev/null && (( ${#MEDIA_EXTS[@]} > 0 )); then
    _media_exts=("${MEDIA_EXTS[@]}")
  fi
  if declare -p SUBTITLE_EXTS &>/dev/null && (( ${#SUBTITLE_EXTS[@]} > 0 )); then
    _subtitle_exts=("${SUBTITLE_EXTS[@]}")
  fi
  return 0
}

########################################
# Applies config values for settings that also have command-line flags, but
# only when the user did not pass the flag. Called after parse_options with the
# pre-parse defaults known, so explicit flags always take precedence.
#
# Implemented by checking each flag against its built-in default: if unchanged,
# a config value (when present) is adopted. This keeps the precedence
# command-line > config > built-in default.
# Globals:
#   Reads WHISPER_MODEL, SPLIT_PENALTY, MAX_WORDS_PER_LINE, THREADS, MIN_SHIFT,
#   AD_BREAKS, BACKUP_SUFFIX, LANG_DEFAULT; writes the matching _-prefixed
#   globals.
########################################
apply_config_flag_defaults() {
  [[ "${_model}" == "base.en" && -n "${WHISPER_MODEL:-}" ]] && _model="${WHISPER_MODEL}"
  [[ "${_lang}" == "en" && -n "${LANG_DEFAULT:-}" ]] && _lang="${LANG_DEFAULT}"
  [[ "${_split_penalty}" == "7" && -n "${SPLIT_PENALTY:-}" ]] && _split_penalty="${SPLIT_PENALTY}"
  [[ "${_max_words}" == "8" && -n "${MAX_WORDS_PER_LINE:-}" ]] && _max_words="${MAX_WORDS_PER_LINE}"
  [[ "${_min_shift}" == "0.5" && -n "${MIN_SHIFT:-}" ]] && _min_shift="${MIN_SHIFT}"
  [[ "${_backup_suffix}" == ".bak" && -n "${BACKUP_SUFFIX:-}" ]] && _backup_suffix="${BACKUP_SUFFIX}"
  [[ -z "${_threads}" && -n "${THREADS:-}" ]] && _threads="${THREADS}"
  if [[ "${_ad_breaks_set}" == false && -n "${AD_BREAKS:-}" ]]; then
    _ad_breaks="${AD_BREAKS}"
    _ad_breaks_set=true
  fi
  # Framerate correction rescales the whole subtitle, and alass can pick a different scale for the
  # segmented run than for the single-offset one. The two candidates then cover different amounts of
  # time, and the score below rewards the more stretched one for reasons that have nothing to do with
  # matching the speech — so the comparison is not run unless it was asked for by name.
  [[ "${_fps_guess}" == true && "${_ad_breaks_set}" == false ]] && _ad_breaks="no"
  validate_settings
  return 0
}

########################################
# Initializes derived runtime values: thread count, cache directory, and the
# scratch working directory (with a cleanup trap).
# Globals:
#   _threads, _cache_dir, _workdir
########################################
setup_runtime() {
  if [[ -z "${_threads}" ]]; then
    if command -v nproc &>/dev/null; then
      _threads="$(nproc)"
    elif command -v sysctl &>/dev/null; then
      _threads="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    else
      _threads=4
    fi
  fi

  if [[ -z "${_cache_dir}" ]]; then
    _cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/subtitle-sync"
  fi

  # Rounded rather than truncated: a threshold of 0.29 is held as 290ms, where truncating the binary
  # approximation of 290.0 would hold it as 289.
  _min_shift_ms="$(awk -v s="${_min_shift}" 'BEGIN{printf "%.0f", s*1000}')"

  if [[ "${_no_color}" == true ]]; then
    disable_log_colors
  fi

  _workdir="$(mktemp -d "${TMPDIR:-/tmp}/subtitle-sync.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '${_workdir}'" EXIT
}

########################################
# Verifies required external tools are available, printing OS-specific install
# hints and exiting if any are missing.
# Globals:
#   _whisper_bin, _alass_bin
########################################
check_deps() {
  local missing=()
  command -v ffmpeg &>/dev/null || missing+=(ffmpeg)
  command -v ffprobe &>/dev/null || missing+=(ffprobe)
  command -v "${_alass_bin}" &>/dev/null || missing+=("${_alass_bin}")
  command -v "${_whisper_bin}" &>/dev/null || missing+=("${_whisper_bin}")

  (( ${#missing[@]} == 0 )) && return 0

  log_error "Missing required tool(s): ${missing[*]}"
  cat >&2 <<EOF

Install hints:
  ffmpeg/ffprobe:
    macOS:  brew install ffmpeg
    Debian: sudo apt install ffmpeg
  alass (segment-aware subtitle aligner):
    Download a release binary from https://github.com/kaegi/alass/releases
    and place it on your PATH (e.g. /usr/local/bin/alass).
  whisper-ctranslate2 (faster-whisper CLI):
    uv:     uv tool install whisper-ctranslate2
    pipx:   pipx install whisper-ctranslate2
    (needs Python >= 3.9; 'uv' bundles a suitable interpreter)
EOF
  exit 1
}

########################################
# Lowercases a string.
# Arguments:
#   The string to lowercase.
# Outputs:
#   The lowercased string on stdout.
########################################
_lower() { printf '%s' "${1,,}"; }

########################################
# Prints the current time in epoch seconds.
# Outputs:
#   Integer seconds on stdout.
########################################
_now() { date +%s; }

########################################
# Formats a duration in seconds as a compact human-readable string
# (e.g. "42s", "5m 20s", "1h 03m 12s").
# Arguments:
#   seconds: A non-negative integer.
# Outputs:
#   The formatted duration on stdout.
########################################
_fmt_dur() {
  local s="$1" h m
  (( h = s / 3600, m = (s % 3600) / 60, s = s % 60 ))
  if (( h > 0 )); then
    printf '%dh %02dm %02ds' "${h}" "${m}" "${s}"
  elif (( m > 0 )); then
    printf '%dm %02ds' "${m}" "${s}"
  else
    printf '%ds' "${s}"
  fi
}

########################################
# Tests whether a detected language matches the target language. An undetermined
# ('und') language is treated as the target, since single-language releases are
# frequently untagged.
# Globals:
#   _lang
# Arguments:
#   detected: A normalized language token.
# Returns:
#   0 if it matches the target (or is undetermined), 1 otherwise.
########################################
lang_matches_target() {
  local detected="$1" target
  target="$(normalize_lang "${_lang}")"
  [[ "${detected}" == "${target}" || "${detected}" == "und" ]]
}

########################################
# Tests whether a path has an extension in the given list (case-insensitive).
# Arguments:
#   path:        The file path.
#   list_name:   Name of the array global holding extensions.
# Returns:
#   0 if the extension is in the list, 1 otherwise.
########################################
has_ext() {
  local path="$1" list_name="$2" fname ext el
  fname="$(basename "${path}")"
  [[ "${fname}" == *.* ]] || return 1
  ext="$(_lower "${fname##*.}")"
  local -n list_ref="${list_name}"
  for el in "${list_ref[@]}"; do
    [[ "${ext}" == "${el}" ]] && return 0
  done
  return 1
}

########################################
# Computes a stable cache key for a video + transcription parameters, so a
# changed video (size/mtime) or changed model/lang/granularity yields a fresh
# reference.
# Globals:
#   _model, _lang, _max_words
# Arguments:
#   video: The video file path.
# Outputs:
#   A hex digest on stdout.
########################################
cache_key() {
  local video="$1" abs sig
  abs="$(cd "$(dirname "${video}")" && pwd -P)/$(basename "${video}")"
  # File signature: size and mtime, GNU stat then BSD stat.
  sig="$(stat -c '%s:%Y' "${video}" 2>/dev/null || stat -f '%z:%m' "${video}" 2>/dev/null || echo '0:0')"
  local digest
  if command -v sha1sum &>/dev/null; then
    digest="$(printf '%s|%s|%s|%s|%s' "${abs}" "${sig}" "${_model}" "${_lang}" "${_max_words}" | sha1sum)"
  else
    digest="$(printf '%s|%s|%s|%s|%s' "${abs}" "${sig}" "${_model}" "${_lang}" "${_max_words}" | shasum -a 1)"
  fi
  printf '%s' "${digest%% *}"
}

########################################
# Extracts a 16 kHz mono WAV (what Whisper expects) from a video's audio.
# Arguments:
#   video:   The video file path.
#   out_wav: Destination WAV path.
# Returns:
#   0 on success, non-zero on ffmpeg failure.
########################################
extract_audio() {
  local video="$1" out_wav="$2"
  local -a args=(-nostdin -hide_banner -loglevel error -y -i "${video}")
  args+=(-vn -ar 16000 -ac 1 -c:a pcm_s16le "${out_wav}")
  ffmpeg "${args[@]}" >"${_workdir}/audio_extract.log" 2>&1
}

########################################
# Produces a speech-accurate reference SRT for a video, using the cache when
# enabled. Extracts audio to the scratch dir, transcribes with the Whisper CLI,
# and stores the (small) reference SRT in the cache.
# Globals:
#   _use_cache, _cache_dir, _workdir, _whisper_bin, _model, _compute_type,
#   _threads, _lang, _max_words, _whisper_extra_args
# Arguments:
#   video:   The video file path.
#   out_ref: Destination reference SRT path.
# Returns:
#   0 on success, non-zero if transcription failed or produced no cues.
########################################
build_reference() {
  local video="$1" out_ref="$2" key cached
  key="$(cache_key "${video}")"
  cached="${_cache_dir}/${key}.srt"
  _ref_cached=false; _t_extract=0; _t_transcribe=0

  if [[ "${_use_cache}" == true && -s "${cached}" ]]; then
    log_debug "Using cached reference: ${cached}"
    cp "${cached}" "${out_ref}"
    _ref_cached=true
    return 0
  fi

  local wav="${_workdir}/audio.wav" t0
  log_info "Transcribing audio (${_model}) — this is the slow step..."
  t0=$(_now)
  if ! extract_audio "${video}" "${wav}"; then
    log_error "Failed to extract audio from: ${video}"
    log_debug "$(tail -n 5 "${_workdir}/audio_extract.log" 2>/dev/null)"
    return 1
  fi
  _t_extract=$(( $(_now) - t0 ))

  local tdir="${_workdir}/whisper"
  rm -rf "${tdir}"; mkdir -p "${tdir}"
  t0=$(_now)
  local -a wargs=(--model "${_model}" --device "${_device}")
  wargs+=(--compute_type "${_compute_type}" --threads "${_threads}")
  wargs+=(--language "${_lang}" --word_timestamps True)
  wargs+=(--max_words_per_line "${_max_words}")
  wargs+=(--output_format srt --output_dir "${tdir}")
  wargs+=("${_whisper_extra_args[@]+"${_whisper_extra_args[@]}"}")
  wargs+=("${wav}")
  if ! "${_whisper_bin}" "${wargs[@]}" >"${_workdir}/whisper.log" 2>&1; then
    log_error "Transcription failed for: ${video}"
    log_debug "$(tail -n 5 "${_workdir}/whisper.log")"
    rm -f "${wav}"
    return 1
  fi
  _t_transcribe=$(( $(_now) - t0 ))
  rm -f "${wav}"

  local produced; produced="$(find "${tdir}" -name '*.srt' | head -1)"
  if [[ -z "${produced}" || ! -s "${produced}" ]]; then
    log_error "Transcription produced no subtitles for: ${video}"
    return 1
  fi
  log_info "Transcribed in $(_fmt_dur "${_t_transcribe}")."

  cp "${produced}" "${out_ref}"
  if [[ "${_use_cache}" == true ]]; then
    mkdir -p "${_cache_dir}"
    cp "${produced}" "${cached}"
  fi
}

########################################
# Runs alass to align a drifted subtitle to a reference, in one of two modes.
# Globals:
#   _alass_bin, _fps_guess, _split_penalty, _workdir, _t_align_total
# Arguments:
#   mode: 'split' to allow a different offset per segment, 'nosplit' for one
#         global offset.
#   ref:  The reference subtitle (from Whisper).
#   sub:  The drifted subtitle to correct.
#   out:  Destination for the corrected subtitle.
# Returns:
#   0 on success, non-zero on alass failure.
########################################
run_alass() {
  local mode="$1" ref="$2" sub="$3" out="$4" t0
  local log="${_workdir}/alass-${mode}.log"
  local -a args=()
  if [[ "${mode}" == "nosplit" ]]; then
    args+=(--no-split)
  else
    args+=(--split-penalty "${_split_penalty}")
  fi
  [[ "${_fps_guess}" == true ]] || args+=(-g)
  t0=$(_now)
  args+=("${ref}" "${sub}" "${out}")
  # A log per mode, because both modes run for one subtitle and a shared path would leave a failure
  # quoting whichever run finished last.
  if ! "${_alass_bin}" "${args[@]}" >"${log}" 2>&1; then
    log_error "alass failed: $(tail -n 3 "${log}" | tr '\n' ' ')"
    return 1
  fi
  _t_align_total=$(( _t_align_total + $(_now) - t0 ))
}

########################################
# Scores one candidate alignment against the speech reference and profiles the
# shift it applied.
# Arguments:
#   ref:  The reference subtitle (from Whisper).
#   orig: The pre-sync subtitle the candidate was produced from.
#   cand: The candidate alignment.
# Outputs:
#   'score cues runs max_abs_shift min_shift max_shift' on stdout; see
#   alignment-stats.awk for what each means.
########################################
alignment_stats() {
  local ref="$1" orig="$2" cand="$3" prog
  prog=$(load_program alignment-stats.awk)  # @embed alignment-stats.awk
  awk -v ref="${ref}" -v orig="${orig}" "${prog}" "${ref}" "${orig}" "${cand}"
}

########################################
# Aligns one subtitle and picks between a single global offset and a segmented
# alignment, per --ad-breaks. In 'auto' both are produced and scored against the
# speech reference, and the segmented one is kept only when it matches better by
# more than _split_margin_permille — a subtitle whose only fault is a constant
# offset scores the same either way, and letting it be split anyway is what
# leaves an opening stretch further out than it started.
# Globals:
#   _ad_breaks, _workdir, _split_margin_permille; writes _align_*
# Arguments:
#   ref: The reference subtitle (from Whisper).
#   sub: The pristine subtitle to align.
#   ext: Extension for the candidate files; alass picks its parser from it.
# Returns:
#   0 with _align_file naming the chosen candidate, non-zero if alignment failed.
########################################
align_subtitle() {
  local ref="$1" sub="$2" ext="$3"
  local nosplit="${_workdir}/nosplit.${ext}" split="${_workdir}/split.${ext}"
  local n_stats="" s_stats=""

  if [[ "${_ad_breaks}" != "yes" ]]; then
    run_alass nosplit "${ref}" "${sub}" "${nosplit}" || return 1
    n_stats="$(alignment_stats "${ref}" "${sub}" "${nosplit}")"
  fi
  if [[ "${_ad_breaks}" != "no" ]]; then
    if run_alass split "${ref}" "${sub}" "${split}"; then
      s_stats="$(alignment_stats "${ref}" "${sub}" "${split}")"
    elif [[ "${_ad_breaks}" == "yes" ]]; then
      return 1
    else
      log_warn "Segmented alignment failed; keeping the single-offset alignment."
    fi
  fi
  adopt_alignment "${nosplit}" "${n_stats}" "${split}" "${s_stats}"
}

########################################
# Chooses between the two candidate alignments and publishes the winner's
# profile. A candidate whose stats are empty was never produced.
# Globals:
#   _split_margin_permille; writes _align_file, _align_score, _align_cues,
#   _align_runs, _align_max_abs, _align_lo, _align_hi
# Arguments:
#   nosplit: Path of the single-offset candidate.
#   n_stats: Its stats line, or empty.
#   split:   Path of the segmented candidate.
#   s_stats: Its stats line, or empty.
########################################
adopt_alignment() {
  local nosplit="$1" n_stats="$2" split="$3" s_stats="$4"
  local chosen stats n_score=0 s_score=0
  [[ -n "${n_stats}" ]] && n_score="${n_stats%% *}"
  [[ -n "${s_stats}" ]] && s_score="${s_stats%% *}"

  if [[ -z "${n_stats}" ]]; then
    chosen="${split}"; stats="${s_stats}"
  elif [[ -z "${s_stats}" ]]; then
    chosen="${nosplit}"; stats="${n_stats}"
  elif (( n_score <= 0 )); then
    # Nothing matched at all, so the comparison says nothing; the unsplit alignment is the one that
    # cannot have invented a break.
    log_debug "Alignment matched no speech; keeping the single-offset alignment."
    chosen="${nosplit}"; stats="${n_stats}"
  elif (( s_score * 1000 > n_score * _split_margin_permille )); then
    log_debug "Segmented alignment matches the speech better (${s_score} vs ${n_score}); ad breaks detected."
    chosen="${split}"; stats="${s_stats}"
  else
    log_debug "Segmented alignment is no better (${s_score} vs ${n_score}); no ad breaks detected."
    chosen="${nosplit}"; stats="${n_stats}"
  fi

  _align_file="${chosen}"
  read -r _align_score _align_cues _align_runs _align_max_abs _align_lo _align_hi <<<"${stats}"
}

########################################
# Formats a signed millisecond shift for a log line.
# Arguments:
#   ms: Signed milliseconds.
# Outputs:
#   The shift in seconds with its sign, e.g. '+4.1s'.
########################################
fmt_shift() {
  awk -v ms="$1" 'BEGIN{printf "%+.1fs", ms/1000}'
}

########################################
# Describes the shift the chosen alignment applied, for the success line, so a
# wrongly split file is visible rather than silent.
# Globals:
#   _align_cues, _align_runs, _align_lo, _align_hi
# Outputs:
#   A short phrase on stdout.
########################################
alignment_summary() {
  if (( _align_cues < 0 )); then
    printf 'shift unknown'
  elif (( _align_runs <= 1 )); then
    printf 'single offset %s' "$(fmt_shift "${_align_lo}")"
  elif (( _align_runs > 8 && _align_runs * 4 > _align_cues )); then
    # Enough distinct shifts to be a rescale rather than a handful of breaks; judged against the cue
    # count, since a fixed number of runs means different things in a 10-cue file and a 900-cue one.
    printf 'variable shift, %s to %s' "$(fmt_shift "${_align_lo}")" "$(fmt_shift "${_align_hi}")"
  else
    printf '%d segments, %s to %s' "${_align_runs}" "$(fmt_shift "${_align_lo}")" "$(fmt_shift "${_align_hi}")"
  fi
}

########################################
# Reports whether the chosen alignment moved every cue by less than --min-shift,
# which means the subtitle already matches the speech as closely as this pipeline
# can tell. Whisper's cue starts carry a lead of a few tenths of a second, so a
# shift that small is indistinguishable from that lead and rewriting the file
# would trade one small error for another.
# Globals:
#   _align_cues, _align_max_abs, _min_shift_ms
# Returns:
#   0 when the file should be left alone, 1 when the alignment is worth writing.
########################################
alignment_is_negligible() {
  (( _align_cues >= 0 )) || return 1
  (( _min_shift_ms > 0 )) || return 1
  (( _align_max_abs < _min_shift_ms ))
}

########################################
# Syncs one external sidecar subtitle in place, backing up the original. Honors
# --force (re-sync), --dry-run, and the idempotency skip (a present backup means
# it was already synced).
# Globals:
#   _force, _dry_run, _backup_suffix, _workdir, _align_*, _n_*
# Arguments:
#   video: The video file path.
#   sub:   The sidecar subtitle path.
#   ref:   A prepared reference SRT (shared across a video's subtitles).
########################################
sync_sidecar() {
  local video="$1" sub="$2" ref="$3"
  local backup="${sub}${_backup_suffix}"

  if [[ -e "${backup}" && "${_force}" != true ]]; then
    log_info "Skip (already synced): ${sub}"
    _n_skipped=$(( _n_skipped + 1 )); return 0
  fi
  if [[ "${_dry_run}" == true ]]; then
    log_info "[dry-run] Would sync if needed: ${sub} (backup -> ${backup})"
    _n_skipped=$(( _n_skipped + 1 )); return 0
  fi

  # Always sync from the pristine original. A prior backup IS the original, so a
  # forced re-run aligns the original again (not an already-synced file) and the
  # original backup is never overwritten.
  local source="${sub}"
  [[ -e "${backup}" ]] && source="${backup}"

  # alass detects format by file extension, so a ".bak" backup must be presented
  # under the subtitle's real extension.
  local src_for_alass="${_workdir}/source.${sub##*.}"
  cp "${source}" "${src_for_alass}"

  if ! align_subtitle "${ref}" "${src_for_alass}" "${sub##*.}"; then
    _n_failed=$(( _n_failed + 1 )); return 0
  fi

  # Decided before the backup is taken, because the backup is also the marker that says this subtitle
  # has been dealt with: writing one and then declining to rewrite the file would leave it skipped by
  # every later run, having never been corrected.
  if alignment_is_negligible; then
    log_info "Already in sync (within ${_min_shift}s): ${sub}"
    _n_insync=$(( _n_insync + 1 )); return 0
  fi

  [[ -e "${backup}" ]] || cp -p "${sub}" "${backup}"
  # Moved rather than copied over: a library file is frequently a hard link to a torrent still being
  # seeded, and writing through the inode would corrupt what the tracker is checksumming.
  mv "${_align_file}" "${sub}"
  log_info "Synced ($(alignment_summary)): ${sub}"
  _n_synced=$(( _n_synced + 1 ))
}

########################################
# Syncs embedded text subtitle tracks of a video that match the target language.
# Each track is extracted to SRT, synced, and either written as a sidecar
# (default) or muxed into a container copy (--remux). Only the first matching
# track is processed.
# Globals:
#   _lang, _remux, _force, _dry_run, _workdir, _align_*, _n_*
# Arguments:
#   video: The video file path.
#   ref:   A prepared reference SRT.
########################################
sync_embedded() {
  local video="$1" ref="$2"
  local dir base index codec rawlang lang
  dir="$(dirname "${video}")"
  base="$(basename "${video}")"; base="${base%.*}"

  # Find the first text subtitle stream matching the target language.
  local chosen_index=""
  local -a probe=(-v error -select_streams s)
  probe+=(-show_entries "stream=index,codec_name:stream_tags=language")
  probe+=(-of csv=p=0 -- "${video}")
  while IFS=',' read -r index codec rawlang; do
    [[ -n "${index}" ]] || continue
    case "$(_lower "${codec}")" in
      subrip|srt|ass|ssa|mov_text|webvtt|text|subtitle) ;;
      *) continue ;;
    esac
    lang="$(normalize_lang "${rawlang}")"
    if lang_matches_target "${lang}"; then chosen_index="${index}"; break; fi
  done < <(ffprobe "${probe[@]}" 2>/dev/null)

  if [[ -z "${chosen_index}" ]]; then
    log_debug "No embedded ${_lang} text track in: ${video}"
    return 0
  fi

  local target_lang; target_lang="$(normalize_lang "${_lang}")"
  local sidecar="${dir}/${base}.${target_lang}.srt"

  if [[ "${_remux}" != true ]]; then
    if [[ -e "${sidecar}" && "${_force}" != true ]]; then
      log_info "Skip embedded (sidecar exists): ${sidecar}"
      _n_skipped=$(( _n_skipped + 1 )); return 0
    fi
  fi
  if [[ "${_dry_run}" == true ]]; then
    if [[ "${_remux}" == true ]]; then
      log_info "[dry-run] Would sync embedded track ${chosen_index} of ${video} and remux."
    else
      log_info "[dry-run] Would sync embedded track ${chosen_index} -> ${sidecar}"
    fi
    _n_skipped=$(( _n_skipped + 1 )); return 0
  fi

  local extracted="${_workdir}/embedded.srt"
  if ! ffmpeg -nostdin -hide_banner -loglevel error -y -i "${video}" -map "0:${chosen_index}" -f srt "${extracted}" 2>"${_workdir}/extract.log"; then
    log_error "Failed to extract embedded track ${chosen_index} from: ${video}"
    _n_failed=$(( _n_failed + 1 )); return 0
  fi

  # No --min-shift check here, unlike a sidecar: the output does not exist yet, and its existence is
  # what marks this track as dealt with. Declining to write a small correction would leave the
  # operator with no subtitle at all and every later run repeating the extraction.
  if ! align_subtitle "${ref}" "${extracted}" srt; then
    _n_failed=$(( _n_failed + 1 )); return 0
  fi
  local final="${_align_file}"

  if [[ "${_remux}" == true ]]; then
    local out="${dir}/${base}.subsync.${video##*.}"
    if [[ -e "${out}" && "${_force}" != true ]]; then
      log_info "Skip embedded (remux target exists): ${out}"
      _n_skipped=$(( _n_skipped + 1 )); return 0
    fi
    # The synced track is appended after any original subtitle streams; tag and
    # default that specific stream (s:N where N = number of original sub streams).
    local n_subs
    n_subs="$(count_subtitle_streams "${video}")"
    local -a margs=(-nostdin -hide_banner -loglevel error -y -i "${video}" -i "${final}")
    margs+=(-map 0 -map 1:0 -c copy -c:s:"${n_subs}" srt)
    margs+=(-metadata:s:s:"${n_subs}" language="${target_lang}")
    margs+=(-disposition:s:s:"${n_subs}" default "${out}")
    if ! ffmpeg "${margs[@]}" 2>"${_workdir}/remux.log"; then
      log_error "Remux failed for: ${video}"
      _n_failed=$(( _n_failed + 1 )); return 0
    fi
    log_info "Synced (remux, $(alignment_summary)): ${out}"
  else
    mv "${final}" "${sidecar}"
    log_info "Synced (embedded -> sidecar, $(alignment_summary)): ${sidecar}"
  fi
  _n_synced=$(( _n_synced + 1 ))
}

########################################
# Counts a video's subtitle streams.
# Arguments:
#   video: The video file path.
# Outputs:
#   The number of subtitle streams on stdout, 0 when there are none.
########################################
count_subtitle_streams() {
  local video="$1"
  local -a probe=(-v error -select_streams s -show_entries stream=index)
  probe+=(-of csv=p=0 -- "${video}")
  # grep exits 1 on no match, which under errexit would abort the caller mid-assignment, so an empty
  # stream list is reported as 0 rather than as a failure.
  ffprobe "${probe[@]}" 2>/dev/null | grep -c . || true
}

########################################
# Lists the sidecar subtitles in a video's directory that belong to it and match
# the target language.
# A backed-up original is not a candidate, since the backup suffix leaves it without a subtitle
# extension.
# Globals:
#   _subtitle_exts
# Arguments:
#   video: The video file path.
# Outputs:
#   One matching sidecar path per line (NUL-free; paths may contain spaces but
#   not newlines).
########################################
matching_sidecars() {
  local video="$1" dir base entry fname stem mid lang
  dir="$(dirname "${video}")"
  base="$(basename "${video}")"; base="${base%.*}"

  for entry in "${dir}"/*; do
    [[ -f "${entry}" ]] || continue
    has_ext "${entry}" _subtitle_exts || continue
    fname="$(basename "${entry}")"
    stem="${fname%.*}"
    if [[ "${stem}" == "${base}" ]]; then
      lang="$(lang_from_tokens "")"
    elif [[ "${stem}" == "${base}."* ]]; then
      mid="${stem#"${base}".}"
      lang="$(lang_from_tokens "${mid}")"
    else
      continue
    fi
    lang_matches_target "${lang}" && printf '%s\n' "${entry}"
  done
}

########################################
# Counts the subtitles this run has reached a verdict on, whichever verdict.
# A subtitle found to be already in sync cost the same transcription as one that
# was rewritten, so it counts as work: leaving it out would drop its episode from
# the timing line and from the per-episode average.
# Globals:
#   _n_synced, _n_insync, _n_failed
# Outputs:
#   The count on stdout.
########################################
work_done() {
  printf '%d' $(( _n_synced + _n_insync + _n_failed ))
}

########################################
# Logs the per-episode timing line (total wall time + step breakdown), but only
# outside dry-run and only when the video actually did work.
# Globals:
#   _dry_run, _n_synced, _n_insync, _n_failed, _ref_cached, _t_extract, _t_transcribe,
#   _t_align_total, _n_videos_worked
# Arguments:
#   video:  The video file path.
#   start:  Epoch seconds captured when processing began.
#   before: The work counters captured before processing, from work_done.
########################################
log_episode_timing() {
  local video="$1" start="$2" before="$3"
  [[ "${_dry_run}" == true ]] && return 0
  (( $(work_done) > before )) || return 0

  local total ref_part
  total=$(( $(_now) - start ))
  if [[ "${_ref_cached}" == true ]]; then
    ref_part="reference cached"
  else
    ref_part="extract $(_fmt_dur "${_t_extract}"), transcribe $(_fmt_dur "${_t_transcribe}")"
  fi
  log_info "$(basename "${video}") took $(_fmt_dur "${total}") (${ref_part}, align $(_fmt_dur "${_t_align_total}"))"
  _n_videos_worked=$(( _n_videos_worked + 1 ))
  return 0
}

########################################
# Processes a single video: prepares one reference, then syncs its matching
# sidecars and (when --embedded) its matching embedded track. The reference is
# built lazily and only once per video, and never in dry-run mode.
# Globals:
#   _embedded, _dry_run, _workdir, _n_*, timing globals
# Arguments:
#   video: The video file path.
########################################
process_video() {
  local video="$1"
  local v_start before
  v_start=$(_now)
  _t_align_total=0; _t_extract=0; _t_transcribe=0; _ref_cached=false
  before=$(work_done)

  local -a sidecars=()
  local s
  while IFS= read -r s; do [[ -n "${s}" ]] && sidecars+=("${s}"); done < <(matching_sidecars "${video}")

  if (( ${#sidecars[@]} == 0 )) && [[ "${_embedded}" != true ]]; then
    log_debug "No ${_lang} sidecars for: ${video}"
    return 0
  fi

  log_info "Video: ${video}"

  # In dry-run we never transcribe; just report intended actions.
  local ref=""
  if [[ "${_dry_run}" != true ]]; then
    # Only build the reference if there is real work to do.
    local need=false
    for s in "${sidecars[@]+"${sidecars[@]}"}"; do
      [[ -e "${s}${_backup_suffix}" && "${_force}" != true ]] || need=true
    done
    [[ "${_embedded}" == true ]] && need=true
    if [[ "${need}" == true ]]; then
      ref="${_workdir}/reference.srt"
      if ! build_reference "${video}" "${ref}"; then
        _n_failed=$(( _n_failed + 1 )); return 0
      fi
    fi
  fi

  for s in "${sidecars[@]+"${sidecars[@]}"}"; do
    sync_sidecar "${video}" "${s}" "${ref}"
  done
  [[ "${_embedded}" == true ]] && sync_embedded "${video}" "${ref}"

  log_episode_timing "${video}" "${v_start}" "${before}"
  return 0
}

########################################
# Recursively finds and processes every media file under a directory.
# Globals:
#   _media_exts
# Arguments:
#   dir: The directory to walk.
########################################
process_directory() {
  local dir="$1" entry
  # Announced before the walk, which on a large tree takes long enough to look like a hang.
  log_info "Searching $(cd "${dir}" && pwd -P) for video to sync..."

  # Collected before any of it is processed, so the count can be reported first: transcribing a
  # library takes hours, and the number is what tells an operator to stop the run rather than
  # discover the scale from the clock.
  local -a videos=()
  while IFS= read -r -d '' entry; do
    has_ext "${entry}" _media_exts && videos+=("${entry}")
  done < <(find "${dir}" -type f -print0 | sort -z)

  log_info "Found ${#videos[@]} video file(s) to examine."
  for entry in "${videos[@]+"${videos[@]}"}"; do
    process_video "${entry}"
  done
  return 0
}

########################################
# Resolves and processes a lone subtitle file: finds its sibling video (by base
# name, or --video) and syncs just that subtitle.
# Globals:
#   _video, _media_exts, _workdir, _dry_run, _n_*
# Arguments:
#   sub: The subtitle file path.
########################################
process_lone_subtitle() {
  local sub="$1" video="${_video}"
  local v_start before
  v_start=$(_now)
  _t_align_total=0; _t_extract=0; _t_transcribe=0; _ref_cached=false
  before=$(work_done)

  if [[ -z "${video}" ]]; then
    local dir base stem entry
    dir="$(dirname "${sub}")"
    stem="$(basename "${sub}")"; stem="${stem%.*}"
    # Strip language/flag tokens to recover the media base name.
    base="${stem%%.*}"
    for entry in "${dir}/${stem}".* "${dir}/${base}".*; do
      [[ -f "${entry}" ]] || continue
      has_ext "${entry}" _media_exts && { video="${entry}"; break; }
    done
  fi

  if [[ -z "${video}" || ! -f "${video}" ]]; then
    log_error "Could not find a video for '${sub}'. Pass --video FILE."
    exit 1
  fi
  log_info "Video: ${video}"

  if [[ "${_dry_run}" == true ]]; then
    log_info "[dry-run] Would sync if needed: ${sub} (against ${video})"
    _n_skipped=$(( _n_skipped + 1 )); return 0
  fi

  local ref="${_workdir}/reference.srt"
  if [[ -e "${sub}${_backup_suffix}" && "${_force}" != true ]]; then
    log_info "Skip (already synced): ${sub}"
    _n_skipped=$(( _n_skipped + 1 )); return 0
  fi
  build_reference "${video}" "${ref}" || { _n_failed=$(( _n_failed + 1 )); return 0; }
  sync_sidecar "${video}" "${sub}" "${ref}"
  log_episode_timing "${video}" "${v_start}" "${before}"
  return 0
}

########################################
# Prints the end-of-run summary.
# Globals:
#   _n_synced, _n_insync, _n_skipped, _n_failed, _dry_run
########################################
print_summary() {
  if [[ "${_dry_run}" == true ]]; then
    log_info "Dry run complete: ${_n_skipped} subtitle(s) would be processed."
  else
    local batch extra=""
    batch=$(( $(_now) - _batch_start ))
    if (( _n_videos_worked > 0 )); then
      extra=" · avg $(_fmt_dur $(( batch / _n_videos_worked )))/episode over ${_n_videos_worked}"
    fi
    log_info "Done: ${_n_synced} synced, ${_n_insync} already in sync, ${_n_skipped} skipped, ${_n_failed} failed in $(_fmt_dur "${batch}").${extra}"
  fi
  (( _n_failed > 0 )) && return 1 || return 0
}

########################################
# Main entry point.
# Arguments:
#   Command-line arguments.
########################################
main() {
  parse_options "$@"

  # Every setting has a default, so running without a config is fine; stdout is dropped to keep the
  # "Loading configuration from" line out of the report.
  load_optional_config >/dev/null || exit 1
  apply_config
  apply_config_flag_defaults
  setup_runtime
  check_deps

  _batch_start=$(_now)

  if [[ -d "${_target}" ]]; then
    process_directory "${_target}"
  elif [[ -f "${_target}" ]]; then
    if has_ext "${_target}" _media_exts; then
      process_video "${_target}"
    elif has_ext "${_target}" _subtitle_exts; then
      process_lone_subtitle "${_target}"
    else
      log_error "Unsupported file type: ${_target}"
      exit 1
    fi
  else
    log_error "'${_target}' is not a file or directory."
    exit 1
  fi

  print_summary
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

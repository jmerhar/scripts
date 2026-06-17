#!/usr/bin/env bash
#
# Resynchronizes drifting subtitles to a video's actual speech.
#
# Many subtitles drift out of sync in ways a single global offset cannot fix —
# most notably "segmented" drift, where broadcast rips have ad breaks cut out so
# the subtitles fall progressively further behind in steps. This script corrects
# that by transcribing the video's audio with Whisper to build a speech-accurate
# reference, then aligning the drifted subtitle to that reference with alass
# (which can apply a different offset to each segment). A final "anchor" step
# cancels Whisper's small word-onset bias.
#
# The same pipeline also handles the simpler cases (a constant global offset, or
# a linear speed/framerate error) — see --help.
#
# Usage:
#   ./subtitle-sync.sh [OPTIONS] [PATH]
#
# PATH may be a directory (processed recursively), a single video file, or a
# single subtitle file. Defaults to the current directory.

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../lib/common.sh"
# @include ../lib/common.sh

# --- Global State (option flags; defaults may be overridden by config) ---
_embedded=false        # also sync embedded subtitle tracks
_remux=false           # embedded output: mux into a container copy (else sidecar)
_lang="en"             # target subtitle language
_model="base.en"       # Whisper model
_split_penalty=5       # alass split penalty
_max_words=8           # reference cue granularity (words per line)
_threads=""            # Whisper/alass threads (default: detected CPU count)
_anchor=true           # apply onset-bias anchor
_anchor_max="1.0"      # max opening shift (s) treated as bias before standing down
_fps_guess=false       # re-enable alass FPS guessing (true speed/framerate drift)
_backup_suffix=".bak"  # suffix for backed-up originals
_force=false           # reprocess already-synced files
_use_cache=true        # use/refresh the reference cache
_dry_run=false         # report planned actions only
_no_color=false        # disable colored output
_video=""              # explicit video for a lone-subtitle invocation
_target="."            # positional PATH

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

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [PATH]

Resynchronize drifting subtitles to a video's speech using a Whisper transcript
as reference and alass for segment-aware alignment.

PATH may be:
  - a directory  (processed recursively; every video is matched to its subtitles)
  - a video file (its matching subtitles are synced)
  - a subtitle   (synced against its sibling video; see --video)
Defaults to the current directory.

By default only EXTERNAL sidecar subtitles in the target language are synced,
edited in place with the original backed up.

Options:
      --embedded         Also sync embedded subtitle tracks (off by default).
      --remux            With --embedded, mux the corrected track into a copy of
                         the container instead of writing a sidecar .srt.
  -g, --lang LANG        Target subtitle language (default: ${_lang}). Use with
                         --model for non-English (e.g. --lang de --model base).
  -m, --model NAME       Whisper model (default: ${_model}).
  -p, --split-penalty N  alass split penalty; lower splits more aggressively
                         (default: ${_split_penalty}).
      --max-words N      Reference cue granularity, words per line (default: ${_max_words}).
  -t, --threads N        CPU threads for Whisper/alass (default: detected).
      --no-anchor        Disable the onset-bias anchor.
      --anchor-max S     Max opening shift in seconds treated as Whisper bias;
                         a larger opening shift is kept as a real offset
                         (default: ${_anchor_max}).
      --fps-guess        Re-enable alass framerate guessing (for true speed /
                         framerate drift; disabled by default).
      --backup-suffix S  Suffix for the backed-up original (default: ${_backup_suffix}).
  -f, --force            Reprocess even if already synced.
      --video FILE       The video to sync against (when PATH is a subtitle).
      --no-cache         Do not use or refresh the Whisper reference cache.
  -n, --dry-run          Report what would be done; change nothing.
  -C, --no-color         Disable colored output.
  -h, --help             Show this help message.

Drift types:
  - Segmented / ad-break drift  -> handled by default (the main use case).
  - Constant global offset      -> handled by default (the anchor stands down
                                   when the opening shift is large).
  - Wrong speed / framerate      -> add --fps-guess (usually with --no-anchor).

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
      -g|--lang) _require_arg "$@"; _lang="$2"; shift 2 ;;
      -m|--model) _require_arg "$@"; _model="$2"; shift 2 ;;
      -p|--split-penalty) _require_arg "$@"; _split_penalty="$2"; shift 2 ;;
      --max-words) _require_arg "$@"; _max_words="$2"; shift 2 ;;
      -t|--threads) _require_arg "$@"; _threads="$2"; shift 2 ;;
      --no-anchor) _anchor=false; shift ;;
      --anchor-max) _require_arg "$@"; _anchor_max="$2"; shift 2 ;;
      --fps-guess) _fps_guess=true; shift ;;
      --backup-suffix) _require_arg "$@"; _backup_suffix="$2"; shift 2 ;;
      -f|--force) _force=true; shift ;;
      --video) _require_arg "$@"; _video="$2"; shift 2 ;;
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
  [[ ${#positional[@]} -eq 1 ]] && _target="${positional[0]}"

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
  if [[ ! "${_anchor_max}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    log_error "--anchor-max must be a non-negative number, got '${_anchor_max}'."
    exit 1
  fi
}

########################################
# Validates that an option that takes a value was given one.
# Arguments:
#   The current option and the remaining args ("$@" from the caller).
########################################
_require_arg() {
  if [[ $# -lt 2 ]]; then
    log_error "Option '$1' requires an argument."
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
#   Reads WHISPER_MODEL, SPLIT_PENALTY, MAX_WORDS_PER_LINE, THREADS, ANCHOR_MAX,
#   BACKUP_SUFFIX, LANG_DEFAULT; writes the matching _-prefixed globals.
########################################
apply_config_flag_defaults() {
  [[ "${_model}" == "base.en" && -n "${WHISPER_MODEL:-}" ]] && _model="${WHISPER_MODEL}"
  [[ "${_lang}" == "en" && -n "${LANG_DEFAULT:-}" ]] && _lang="${LANG_DEFAULT}"
  [[ "${_split_penalty}" == "5" && -n "${SPLIT_PENALTY:-}" ]] && _split_penalty="${SPLIT_PENALTY}"
  [[ "${_max_words}" == "8" && -n "${MAX_WORDS_PER_LINE:-}" ]] && _max_words="${MAX_WORDS_PER_LINE}"
  [[ "${_anchor_max}" == "1.0" && -n "${ANCHOR_MAX:-}" ]] && _anchor_max="${ANCHOR_MAX}"
  [[ "${_backup_suffix}" == ".bak" && -n "${BACKUP_SUFFIX:-}" ]] && _backup_suffix="${BACKUP_SUFFIX}"
  [[ -z "${_threads}" && -n "${THREADS:-}" ]] && _threads="${THREADS}"
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

  if [[ "${_no_color}" == true ]]; then
    _color_info=""; _color_debug=""; _color_error=""; _color_reset=""; _text_bold=""
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
# Normalizes a language code or English name to an ISO 639-1 code for the common
# languages, so equivalent forms compare equal (en == eng == english). Unknown
# input is returned lowercased; empty input becomes "und".
# Arguments:
#   raw: A language tag, code, or name (any case).
# Outputs:
#   The normalized token on stdout.
########################################
normalize_lang() {
  local raw; raw="$(_lower "${1//[[:space:]]/}")"
  case "${raw}" in
    ""|und|undetermined) printf 'und' ;;
    en|eng|english) printf 'en' ;;
    es|spa|spanish|castilian) printf 'es' ;;
    fr|fra|fre|french) printf 'fr' ;;
    de|deu|ger|german) printf 'de' ;;
    it|ita|italian) printf 'it' ;;
    pt|por|portuguese) printf 'pt' ;;
    nl|nld|dut|dutch|flemish) printf 'nl' ;;
    ru|rus|russian) printf 'ru' ;;
    ja|jpn|japanese) printf 'ja' ;;
    zh|zho|chi|chinese) printf 'zh' ;;
    ko|kor|korean) printf 'ko' ;;
    ar|ara|arabic) printf 'ar' ;;
    pl|pol|polish) printf 'pl' ;;
    sv|swe|swedish) printf 'sv' ;;
    da|dan|danish) printf 'da' ;;
    fi|fin|finnish) printf 'fi' ;;
    no|nor|norwegian) printf 'no' ;;
    cs|ces|cze|czech) printf 'cs' ;;
    el|ell|gre|greek) printf 'el' ;;
    he|heb|hebrew) printf 'he' ;;
    hu|hun|hungarian) printf 'hu' ;;
    tr|tur|turkish) printf 'tr' ;;
    uk|ukr|ukrainian) printf 'uk' ;;
    ro|ron|rum|romanian|moldavian|moldovan) printf 'ro' ;;
    *) printf '%s' "${raw}" ;;
  esac
}

########################################
# Determines a sidecar subtitle's language from the dot-separated tokens between
# the media base name and the extension (e.g. the "en" in "Movie.en.forced.srt").
# The first token that is not a known role flag is taken as the language; an
# empty token string yields "und".
# Globals:
#   _sidecar_flags
# Arguments:
#   middle: The dot-separated token string (may be empty).
# Outputs:
#   The normalized language token on stdout.
########################################
lang_from_tokens() {
  local middle="$1" token tl f is_flag lang=""
  local -a tokens
  [[ -n "${middle}" ]] || { normalize_lang ""; return; }

  IFS='.' read -ra tokens <<<"${middle}"
  for token in "${tokens[@]}"; do
    tl="$(_lower "${token}")"
    is_flag=false
    for f in "${_sidecar_flags[@]}"; do
      [[ "${tl}" == "${f}" ]] && { is_flag=true; break; }
    done
    [[ "${is_flag}" == true ]] && continue
    lang="${token}"; break
  done
  normalize_lang "${lang}"
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
  ffmpeg -v error -y -i "${video}" -vn -ar 16000 -ac 1 -c:a pcm_s16le "${out_wav}"
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
    return 1
  fi
  _t_extract=$(( $(_now) - t0 ))

  local tdir="${_workdir}/whisper"
  rm -rf "${tdir}"; mkdir -p "${tdir}"
  t0=$(_now)
  if ! "${_whisper_bin}" \
      --model "${_model}" \
      --device "${_device}" \
      --compute_type "${_compute_type}" \
      --threads "${_threads}" \
      --language "${_lang}" \
      --word_timestamps True \
      --max_words_per_line "${_max_words}" \
      --output_format srt \
      --output_dir "${tdir}" \
      "${_whisper_extra_args[@]+"${_whisper_extra_args[@]}"}" \
      "${wav}" >"${_workdir}/whisper.log" 2>&1; then
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
# Runs alass to align a drifted subtitle to a reference.
# Globals:
#   _alass_bin, _fps_guess, _split_penalty
# Arguments:
#   ref: The reference subtitle (from Whisper).
#   sub: The drifted subtitle to correct.
#   out: Destination for the corrected subtitle.
# Returns:
#   0 on success, non-zero on alass failure.
########################################
run_alass() {
  local ref="$1" sub="$2" out="$3" t0
  local -a args=(--split-penalty "${_split_penalty}")
  [[ "${_fps_guess}" == true ]] || args+=(-g)
  t0=$(_now)
  if ! "${_alass_bin}" "${args[@]}" "${ref}" "${sub}" "${out}" \
      >"${_workdir}/alass.log" 2>&1; then
    log_error "alass failed: $(tail -n 3 "${_workdir}/alass.log" | tr '\n' ' ')"
    return 1
  fi
  _t_align_total=$(( _t_align_total + $(_now) - t0 ))
}

########################################
# Reads the start time (in milliseconds) of the first cue in an SRT file.
# Arguments:
#   srt: The SRT file path.
# Outputs:
#   Integer milliseconds on stdout, or empty if no cue was found.
########################################
first_cue_ms() {
  awk '/ --> /{split($1,a,"[:,]"); print ((a[1]*60+a[2])*60+a[3])*1000+a[4]; exit}' "$1"
}

########################################
# Shifts every timestamp in an SRT file by a (signed) millisecond delta,
# clamping negatives to zero. SRT-only (relies on the "HH:MM:SS,mmm" cue format).
# Arguments:
#   in_srt:   Source SRT.
#   out_srt:  Destination SRT.
#   delta_ms: Signed milliseconds to add.
########################################
shift_srt() {
  local in_srt="$1" out_srt="$2" delta_ms="$3"
  awk -v off="${delta_ms}" '
    function toms(h,m,s,ms){ return ((h*60+m)*60+s)*1000+ms }
    function fmt(t,   h,m,s,ms){
      if (t<0) t=0
      ms=t%1000; t=int(t/1000); s=t%60; t=int(t/60); m=t%60; h=int(t/60)
      return sprintf("%02d:%02d:%02d,%03d",h,m,s,ms)
    }
    / --> /{
      split($1,a,"[:,]"); split($3,b,"[:,]")
      printf "%s --> %s\n", fmt(toms(a[1],a[2],a[3],a[4])+off), fmt(toms(b[1],b[2],b[3],b[4])+off)
      next
    }
    { print }
  ' "${in_srt}" >"${out_srt}"
}

########################################
# Applies the onset-bias anchor: makes the first cue return to its original time
# by shifting the whole corrected file, but only when that opening shift is small
# enough to be Whisper word-onset bias (<= --anchor-max). A larger opening shift
# is treated as a genuine global offset and left intact. SRT-only; non-SRT files
# are passed through unchanged.
# Globals:
#   _anchor_max
# Arguments:
#   corrected: alass output.
#   original:  The pre-sync subtitle (timing reference for the opening).
#   out:       Destination for the anchored result.
########################################
anchor_correct() {
  local corrected="$1" original="$2" out="$3"

  if [[ "${corrected##*.}" != "srt" ]]; then
    log_debug "Anchor skipped (non-SRT format)."
    cp "${corrected}" "${out}"; return 0
  fi

  local o c delta abs max_ms
  o="$(first_cue_ms "${original}")"
  c="$(first_cue_ms "${corrected}")"
  if [[ -z "${o}" || -z "${c}" ]]; then
    cp "${corrected}" "${out}"; return 0
  fi

  delta=$(( o - c ))
  abs="${delta#-}"
  max_ms="$(awk -v s="${_anchor_max}" 'BEGIN{printf "%d", s*1000}')"

  if (( abs <= max_ms )); then
    log_debug "Anchor: shifting by ${delta}ms (opening treated as bias)."
    shift_srt "${corrected}" "${out}" "${delta}"
  else
    log_debug "Anchor stood down: opening shift ${delta}ms > ${max_ms}ms (treated as real offset)."
    cp "${corrected}" "${out}"
  fi
}

########################################
# Syncs one external sidecar subtitle in place, backing up the original. Honors
# --force (re-sync), --dry-run, and the idempotency skip (a present backup means
# it was already synced).
# Globals:
#   _force, _dry_run, _backup_suffix, _anchor, _workdir, _n_*
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
    log_info "[dry-run] Would sync: ${sub} (backup -> ${backup})"
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

  local corrected="${_workdir}/corrected.${sub##*.}"
  local final="${_workdir}/final.${sub##*.}"
  if ! run_alass "${ref}" "${src_for_alass}" "${corrected}"; then
    _n_failed=$(( _n_failed + 1 )); return 0
  fi
  if [[ "${_anchor}" == true ]]; then
    anchor_correct "${corrected}" "${src_for_alass}" "${final}"
  else
    cp "${corrected}" "${final}"
  fi

  [[ -e "${backup}" ]] || cp -p "${sub}" "${backup}"
  mv "${final}" "${sub}"
  log_info "Synced: ${sub}"
  _n_synced=$(( _n_synced + 1 ))
}

########################################
# Syncs embedded text subtitle tracks of a video that match the target language.
# Each track is extracted to SRT, synced, and either written as a sidecar
# (default) or muxed into a container copy (--remux). Only the first matching
# track is processed.
# Globals:
#   _lang, _remux, _force, _dry_run, _anchor, _workdir, _n_*
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
  while IFS=',' read -r index codec rawlang; do
    [[ -n "${index}" ]] || continue
    case "$(_lower "${codec}")" in
      subrip|srt|ass|ssa|mov_text|webvtt|text|subtitle) ;;
      *) continue ;;
    esac
    lang="$(normalize_lang "${rawlang}")"
    if lang_matches_target "${lang}"; then chosen_index="${index}"; break; fi
  done < <(ffprobe -v error -select_streams s \
    -show_entries stream=index,codec_name:stream_tags=language \
    -of csv=p=0 -- "${video}" 2>/dev/null)

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
  if ! ffmpeg -v error -y -i "${video}" -map "0:${chosen_index}" -f srt "${extracted}" 2>"${_workdir}/extract.log"; then
    log_error "Failed to extract embedded track ${chosen_index} from: ${video}"
    _n_failed=$(( _n_failed + 1 )); return 0
  fi

  local corrected="${_workdir}/emb_corrected.srt" final="${_workdir}/emb_final.srt"
  if ! run_alass "${ref}" "${extracted}" "${corrected}"; then
    _n_failed=$(( _n_failed + 1 )); return 0
  fi
  if [[ "${_anchor}" == true ]]; then
    anchor_correct "${corrected}" "${extracted}" "${final}"
  else
    cp "${corrected}" "${final}"
  fi

  if [[ "${_remux}" == true ]]; then
    local out="${dir}/${base}.subsync.${video##*.}"
    if [[ -e "${out}" && "${_force}" != true ]]; then
      log_info "Skip embedded (remux target exists): ${out}"
      _n_skipped=$(( _n_skipped + 1 )); return 0
    fi
    # The synced track is appended after any original subtitle streams; tag and
    # default that specific stream (s:N where N = number of original sub streams).
    local n_subs
    n_subs="$(ffprobe -v error -select_streams s -show_entries stream=index \
      -of csv=p=0 -- "${video}" 2>/dev/null | grep -c .)"
    if ! ffmpeg -v error -y -i "${video}" -i "${final}" \
        -map 0 -map 1:0 -c copy -c:s:"${n_subs}" srt \
        -metadata:s:s:"${n_subs}" language="${target_lang}" \
        -disposition:s:s:"${n_subs}" default \
        "${out}" 2>"${_workdir}/remux.log"; then
      log_error "Remux failed for: ${video}"
      _n_failed=$(( _n_failed + 1 )); return 0
    fi
    log_info "Synced (remux): ${out}"
  else
    mv "${final}" "${sidecar}"
    log_info "Synced (embedded -> sidecar): ${sidecar}"
  fi
  _n_synced=$(( _n_synced + 1 ))
}

########################################
# Lists the sidecar subtitles in a video's directory that belong to it and match
# the target language.
# Globals:
#   _subtitle_exts, _backup_suffix
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
# Logs the per-episode timing line (total wall time + step breakdown), but only
# outside dry-run and only when the video actually did work (synced or failed).
# Globals:
#   _dry_run, _n_synced, _n_failed, _ref_cached, _t_extract, _t_transcribe,
#   _t_align_total, _n_videos_worked
# Arguments:
#   video:  The video file path.
#   start:  Epoch seconds captured when processing began.
#   before: _n_synced + _n_failed captured before processing.
########################################
log_episode_timing() {
  local video="$1" start="$2" before="$3"
  [[ "${_dry_run}" == true ]] && return 0
  (( _n_synced + _n_failed > before )) || return 0

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
  before=$(( _n_synced + _n_failed ))

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
  while IFS= read -r -d '' entry; do
    has_ext "${entry}" _media_exts && process_video "${entry}"
  done < <(find "${dir}" -type f -print0 | sort -z)
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
  before=$(( _n_synced + _n_failed ))

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
    log_info "[dry-run] Would sync: ${sub} (against ${video})"
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
#   _n_synced, _n_skipped, _n_failed, _dry_run
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
    log_info "Done: ${_n_synced} synced, ${_n_skipped} skipped, ${_n_failed} failed in $(_fmt_dur "${batch}").${extra}"
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

  load_config &>/dev/null || true
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

main "$@"

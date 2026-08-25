#!/usr/bin/env bash
#
# Reports, and on request rewrites, the Dolby Vision L5 active area of Matroska files.
#
# The L5 metadata block states where the picture sits inside the frame. A 2.39:1 film delivered in a
# 16:9 container legitimately declares the letterbox bars it contains — but some displays act on that
# by zooming or by adding bars of their own, and the picture then arrives cropped or twice-boxed.
# Zeroing the active area leaves the encoded frame untouched and tells the display to show all of it.
#
# Whether a declared active area is wrong is a judgement about a particular file on particular
# hardware, so this reports by default and rewrites only what it is told to: --fix asks per file, and
# only --yes makes it act on a whole tree unattended.
#
# The rewrite goes through the RPU rather than the picture: extract the video track, extract its RPU,
# zero the active area, inject it back, and remux. Nothing is re-encoded, so it costs no quality — but
# it does rewrite a multi-gigabyte file, which is why the original is replaced only once the new file
# exists and the repair has been verified.
#
# Usage:
#   ./dovi-active-area.sh [OPTIONS] [PATH]

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
_fix=false
_assume_yes=false
_dry_run=false
_keep_original=false
_no_color=false
_sample_opt=""
_frame_opt=""
_target="."

# Resolved settings, filled in by apply_config from the options and the config file.
_sample_seconds=10
_probe_frame=100
_work_dir=""
_dovi_tool="dovi_tool"

# Scratch directory for the small RPU samples the report reads, and the working directory of the
# rewrite currently in progress. Both are removed by the exit trap, so an interrupted run does not
# leave a part-extracted video track behind.
_scratch=""
_current_work=""

# Outcome counters, reported by print_summary and reflected in the exit status.
_seen=0
_dolby=0
_declared=0
_fixed=0
_failed=0

# Holds the most recent key entered by the user (set by prompt_key).
_answer=""

# Answers "fix everything from here on" once the user has said so.
_fix_all=false

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

Report the Dolby Vision L5 active area of Matroska files, and optionally zero it.

PATH may be a single .mkv file or a directory, which is searched recursively.
If it is omitted, the current directory is used.

Options:
  -f, --fix             Zero the active area of files that declare one, asking first.
  -y, --yes             With --fix, do not ask; act on every file that declares one.
  -k, --keep-original   With --fix, keep the original alongside as <name>.orig.
  -n, --dry-run         Report, and name what --fix would rewrite, without writing.
  -s, --sample SECONDS  Seconds of video to sample when reading the metadata (default ${_sample_seconds}).
      --frame N         Frame within that sample to read (default ${_probe_frame}).
  -C, --no-color        Disable colored output.
  -d, --debug           Enable verbose debug logging, including each tool invocation.
  -h, --help            Show this help message.

Files without Dolby Vision metadata are counted and passed over. A rewrite
replaces the file only once the new one exists and reports a zeroed active area,
so an interrupted run leaves the original in place.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _fix, _assume_yes, _keep_original, _dry_run, _no_color, _sample_opt, _frame_opt, _target
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--fix)
        _fix=true
        shift
        ;;
      -y|--yes)
        _assume_yes=true
        shift
        ;;
      -k|--keep-original)
        _keep_original=true
        shift
        ;;
      -n|--dry-run)
        _dry_run=true
        shift
        ;;
      -s|--sample)
        require_option_value "$@"
        _sample_opt="$2"
        shift 2
        ;;
      --frame)
        require_option_value "$@"
        _frame_opt="$2"
        shift 2
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

  if [[ "${_assume_yes}" == true && "${_fix}" != true ]]; then
    die_usage "--yes only means something with --fix."
  fi
  if [[ "${_keep_original}" == true && "${_fix}" != true ]]; then
    die_usage "--keep-original only means something with --fix."
  fi
}

########################################
# Resolves the settings that come from either an option or the config file, the option winning.
# Globals:
#   SAMPLE_SECONDS, PROBE_FRAME, WORK_DIR, DOVI_TOOL_BIN, and the resolved globals they feed.
# Arguments:
#   None
# Returns:
#   0 when the resulting settings are usable, 1 otherwise.
########################################
apply_config() {
  _sample_seconds="${_sample_opt:-${SAMPLE_SECONDS:-${_sample_seconds}}}"
  _probe_frame="${_frame_opt:-${PROBE_FRAME:-${_probe_frame}}}"
  _work_dir="${WORK_DIR:-}"
  _dovi_tool="${DOVI_TOOL_BIN:-${_dovi_tool}}"

  if [[ ! "${_sample_seconds}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "The sample length must be a positive whole number of seconds, got '${_sample_seconds}'."
    return 1
  fi
  if [[ ! "${_probe_frame}" =~ ^[0-9]+$ ]]; then
    log_error "The frame number must be a whole number, got '${_probe_frame}'."
    return 1
  fi
  if [[ -n "${_work_dir}" && ! -d "${_work_dir}" ]]; then
    log_error "WORK_DIR '${_work_dir}' does not exist or is not a directory."
    return 1
  fi
}

########################################
# Verifies the external tools are present, naming what is missing and how to get it.
#
# mkvtoolnix is required only for a rewrite, so a report still runs on a machine that has none of it;
# dovi_tool has no Debian package at all, which is why its hint points at a release binary.
# Globals:
#   _fix, _dovi_tool
# Arguments:
#   None
# Returns:
#   0 when everything needed is present, 1 otherwise.
########################################
check_deps() {
  local missing=()
  command -v mediainfo &>/dev/null || missing+=(mediainfo)
  command -v jq &>/dev/null || missing+=(jq)
  command -v ffmpeg &>/dev/null || missing+=(ffmpeg)
  command -v "${_dovi_tool}" &>/dev/null || missing+=("${_dovi_tool}")
  if [[ "${_fix}" == true ]]; then
    command -v mkvextract &>/dev/null || missing+=(mkvextract)
    command -v mkvmerge &>/dev/null || missing+=(mkvmerge)
  fi

  (( ${#missing[@]} == 0 )) && return 0

  log_error "Missing required tool(s): ${missing[*]}"
  cat >&2 <<EOF

Install hints:
  mediainfo, jq, ffmpeg, mkvtoolnix:
    macOS:  brew install mediainfo jq ffmpeg mkvtoolnix
    Debian: sudo apt install mediainfo jq ffmpeg mkvtoolnix
  dovi_tool:
    macOS:  brew install dovi_tool
    Debian: no package exists; download a release binary from
            https://github.com/quietvoid/dovi_tool/releases and put it on your PATH,
            or point DOVI_TOOL_BIN at it in the configuration file.
EOF
  return 1
}

########################################
# Creates the scratch directory the report samples into, and arranges for it to be removed.
# Globals:
#   _scratch, _current_work
########################################
setup_scratch() {
  _scratch="$(mktemp -d "${TMPDIR:-/tmp}/dovi-active-area.XXXXXX")"
  # Both directories are named at trap time rather than expanded now, so the trap also removes the
  # per-file working directory of a rewrite that a signal interrupts.
  # shellcheck disable=SC2016
  trap 'rm -rf "${_scratch}" ${_current_work:+"${_current_work}"}' EXIT
}

########################################
# Prints the Dolby Vision profile of a file, or nothing when it carries no Dolby Vision metadata.
# Globals:
#   None
# Arguments:
#   file: The Matroska file to inspect.
# Outputs:
#   The profile string, e.g. "dvhe.08".
########################################
dv_profile() {
  local prog
  prog=$(load_program dolby-vision.jq)  # @embed dolby-vision.jq
  mediainfo --Output=JSON "$1" 2>/dev/null | jq -r "${prog}" 2>/dev/null
}

########################################
# Prints the L5 active area an RPU file declares, as "left right top bottom".
#
# One frame is read rather than the whole RPU, and the first frame stands in when the requested one is
# past the end of a short sample. Both the report and the check that follows a rewrite come through
# here, so they cannot disagree about what the metadata says.
# Globals:
#   _dovi_tool
# Arguments:
#   rpu: The RPU file to read.
#   frame: The frame number to read it at.
# Outputs:
#   Four tab-separated offsets, or nothing when the frame carries no L5 block.
########################################
read_active_area() {
  local rpu="$1" frame="$2"
  local prog
  prog=$(load_program active-area.jq)  # @embed active-area.jq
  local info
  info="$("${_dovi_tool}" info -f "${frame}" -i "${rpu}" 2>/dev/null || "${_dovi_tool}" info -f 0 -i "${rpu}" 2>/dev/null || true)"
  # dovi_tool prints a progress line before the JSON document, which jq would refuse to parse.
  printf '%s' "${info}" | sed -n '/^{/,$p' | jq -r "${prog}" 2>/dev/null
}

########################################
# Prints a file's declared L5 active area as "left right top bottom", or nothing when it declares none.
#
# The metadata is read from a short sample rather than the whole file, because extracting the RPU of a
# feature film to answer a yes-or-no question would cost minutes per title.
# Globals:
#   _dovi_tool, _sample_seconds, _probe_frame, _scratch
# Arguments:
#   file: The Matroska file to inspect.
# Outputs:
#   Four tab-separated offsets.
########################################
active_area() {
  local file="$1"
  local rpu="${_scratch}/probe.bin"
  rm -f "${rpu}"

  log_debug "Sampling ${_sample_seconds}s of '${file}' for its RPU."
  ffmpeg -ss 0 -to "00:00:${_sample_seconds}" -i "${file}" -c:v copy -f hevc - 2>/dev/null | "${_dovi_tool}" extract-rpu -i - -o "${rpu}" &>/dev/null || true
  [[ -s "${rpu}" ]] || return 0

  read_active_area "${rpu}" "${_probe_frame}"
}

########################################
# Reports whether an active area describes anything other than the whole frame.
# Globals:
#   None
# Arguments:
#   area: The four offsets, whitespace-separated, possibly empty.
# Returns:
#   0 when any offset is non-zero, 1 otherwise.
########################################
declares_area() {
  local offset
  for offset in $1; do
    [[ "${offset}" != "0" ]] && return 0
  done
  return 1
}

########################################
# Prints the video track properties a remux must restate, as "id duration language name".
# Globals:
#   None
# Arguments:
#   file: The Matroska file to inspect.
# Outputs:
#   Tab-separated properties, or nothing when the file has no video track.
########################################
video_track() {
  local prog
  prog=$(load_program video-track.jq)  # @embed video-track.jq
  mkvmerge -J "$1" 2>/dev/null | jq -r "${prog}" 2>/dev/null
}

########################################
# Writes the editor document that zeroes the active area.
#
# mode 0 leaves the tone-mapping metadata alone; the active-area presets are what this changes, and
# "crop": false is what stops dovi_tool reinstating them from the frame geometry.
# Globals:
#   None
# Arguments:
#   path: Where to write the document.
########################################
write_editor_config() {
  cat > "$1" <<'EOF'
{
    "mode": 0,
    "active_area": {
        "crop": false,
        "presets": [
            { "id": 0, "left": 0, "right": 0, "top": 0, "bottom": 0 }
        ],
        "edits": { "all": 0 }
    }
}
EOF
}

########################################
# Rewrites one file's RPU so that its active area covers the whole frame.
#
# Every step writes into a working directory of its own and the original is replaced only at the end,
# after the rewritten RPU has been read back and found to declare no active area. So a failure at any
# point — a full disk, a killed run, a file dovi_tool cannot parse — costs the work but not the file.
# Globals:
#   _dovi_tool, _work_dir, _keep_original, _current_work, _fixed, _failed
# Arguments:
#   file: The Matroska file to rewrite.
# Returns:
#   0 when the file was replaced, 1 otherwise.
########################################
fix_file() {
  local file="$1"
  local dir
  dir="$(dirname "${file}")"

  local links
  links="$(stat_links "${file}" 2>/dev/null || echo 1)"
  if [[ "${links}" -gt 1 ]]; then
    log_warn "'${file}' has ${links} names (hard links). The rewrite goes to a new inode and is moved into place, so the other names — a seeding torrent's copy, most likely — keep the file exactly as it is. The disk gains a second copy in exchange."
  fi

  local work
  if ! work="$(mktemp -d "${_work_dir:-${dir}}/.dovi-active-area.XXXXXX" 2>/dev/null)"; then
    log_error "Could not create a working directory in '${_work_dir:-${dir}}'."
    return 1
  fi
  _current_work="${work}"

  local track duration language name
  IFS=$'\t' read -r track duration language name < <(video_track "${file}") || true
  if [[ -z "${track:-}" ]]; then
    log_error "'${file}' has no video track that mkvmerge recognises."
    rm -rf "${work}"
    _current_work=""
    return 1
  fi
  log_debug "Video track ${track}, default duration '${duration}', language '${language}'."

  local video="${work}/video.hevc"
  local rpu="${work}/rpu.bin"
  local fixed_rpu="${work}/rpu-zeroed.bin"
  local fixed_video="${work}/video-zeroed.hevc"
  local editor="${work}/active-area.json"
  local output="${work}/remuxed.mkv"

  local step=""
  local ok=true
  step="extracting the video track"
  mkvextract tracks "${file}" "${track}:${video}" &>/dev/null || ok=false
  if [[ "${ok}" == true ]]; then
    step="extracting the RPU"
    "${_dovi_tool}" extract-rpu -i "${video}" -o "${rpu}" &>/dev/null || ok=false
  fi
  if [[ "${ok}" == true ]]; then
    step="zeroing the active area"
    write_editor_config "${editor}"
    "${_dovi_tool}" editor -i "${rpu}" -j "${editor}" --rpu-out "${fixed_rpu}" &>/dev/null || ok=false
  fi
  if [[ "${ok}" == true ]]; then
    step="verifying the rewritten RPU"
    local check
    check="$(read_active_area "${fixed_rpu}" 0)"
    declares_area "${check}" && ok=false
  fi
  if [[ "${ok}" == true ]]; then
    step="injecting the RPU"
    "${_dovi_tool}" inject-rpu -i "${video}" --rpu-in "${fixed_rpu}" -o "${fixed_video}" &>/dev/null || ok=false
  fi
  if [[ "${ok}" == true ]]; then
    step="remuxing"
    local -a merge=(-o "${output}")
    [[ -n "${duration}" ]] && merge+=(--default-duration "0:${duration}ns")
    [[ -n "${language}" ]] && merge+=(--language "0:${language}")
    [[ -n "${name}" ]] && merge+=(--track-name "0:${name}")
    merge+=("${fixed_video}" -D "${file}")
    mkvmerge "${merge[@]}" &>/dev/null || ok=false
  fi
  if [[ "${ok}" == true && ! -s "${output}" ]]; then
    step="remuxing"
    ok=false
  fi

  if [[ "${ok}" != true ]]; then
    log_error "Failed while ${step} for '${file}'. The file is untouched."
    rm -rf "${work}"
    _current_work=""
    return 1
  fi

  if [[ "${_keep_original}" == true ]]; then
    mv "${file}" "${file}.orig"
  fi
  mv "${output}" "${file}"
  rm -rf "${work}"
  _current_work=""
  return 0
}

########################################
# Asks whether to rewrite one file, remembering an answer of "all".
# Globals:
#   _assume_yes, _fix_all, _answer, and color globals.
# Arguments:
#   file: The file being offered.
# Returns:
#   0 to rewrite it, 1 to leave it, 2 to stop the run.
########################################
confirm_fix() {
  [[ "${_assume_yes}" == true || "${_fix_all}" == true ]] && return 0

  printf '%s' "${_C_BOLD}${_C_CYAN}Zero the active area of $(basename "$1")? ${_C_RESET}"
  printf '%s' "${_C_DIM}[ (y)es / (N)o / (a)ll / (q)uit ] ${_C_RESET}"
  if ! prompt_key; then
    # End of input rather than an answer: stop, instead of treating every remaining file as declined.
    printf '\n'
    return 2
  fi
  printf '\n'

  case "${_answer}" in
    y|Y) return 0 ;;
    a|A) _fix_all=true; return 0 ;;
    q|Q) return 2 ;;
    *) return 1 ;;
  esac
}

########################################
# Reports on one file, and rewrites it when asked to.
# Globals:
#   Counters, option flags, and color globals.
# Arguments:
#   file: The Matroska file to process.
# Returns:
#   0 normally, 2 when the user asked to stop.
########################################
process_file() {
  local file="$1"
  _seen=$(( _seen + 1 ))

  local profile
  profile="$(dv_profile "${file}")"
  if [[ -z "${profile}" ]]; then
    log_debug "No Dolby Vision metadata in '${file}'."
    return 0
  fi
  _dolby=$(( _dolby + 1 ))

  local area
  area="$(active_area "${file}")"
  local name
  name="$(basename "${file}")"

  if ! declares_area "${area}"; then
    printf '%s\n' "${_C_DIM}${name}: ${profile}, no active area declared${_C_RESET}"
    return 0
  fi

  _declared=$(( _declared + 1 ))
  local offsets
  offsets="$(printf '%s' "${area}" | tr '\t' ' ')"
  printf '%s\n' "${_C_YELLOW}${name}: ${profile}, active area ${offsets} (left right top bottom)${_C_RESET}"

  [[ "${_fix}" == true ]] || return 0

  if [[ "${_dry_run}" == true ]]; then
    printf '%s\n' "${_C_CYAN}  would zero the active area${_C_RESET}"
    _fixed=$(( _fixed + 1 ))
    return 0
  fi

  local answer=0
  confirm_fix "${file}" || answer=$?
  case "${answer}" in
    2) return 2 ;;
    1) return 0 ;;
  esac

  printf '%s\n' "${_C_CYAN}  rewriting ${name}${_C_RESET}"
  if fix_file "${file}"; then
    _fixed=$(( _fixed + 1 ))
    local kept=""
    [[ "${_keep_original}" == true ]] && kept=" (original kept as ${name}.orig)"
    printf '%s\n' "${_C_GREEN}  done${kept}${_C_RESET}"
  else
    _failed=$(( _failed + 1 ))
  fi
  return 0
}

########################################
# Walks the target and processes every Matroska file, in path order.
#
# The whole list is collected before anything is processed, because the confirmation prompt reads a
# keypress from standard input: a loop fed directly by a process substitution has that stream as its
# standard input, so the first "key" a prompt read would be a character of the next path, and the run
# would answer its own questions.
#
# Symlinks are skipped, both to avoid walking a tree twice and because rewriting a file reached
# through one would replace the link with a regular file.
# Globals:
#   _target
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
  local other=$(( _seen - _dolby ))
  printf '\n%s\n' "${_C_BOLD}${_C_BRIGHT_GREEN}${_dolby} Dolby Vision file(s) of ${_seen} examined; ${_declared} declare an active area.${_C_RESET}"
  (( other > 0 )) && printf '%s\n' "${_C_DIM}${other} file(s) carried no Dolby Vision metadata.${_C_RESET}"

  if [[ "${_fix}" == true ]]; then
    local verb="Rewrote"
    [[ "${_dry_run}" == true ]] && verb="Would rewrite"
    local line="${verb} ${_fixed} file(s)"
    (( _failed > 0 )) && line+=", ${_failed} failed"
    printf '%s\n' "${_C_BOLD}${_C_GREEN}${line}.${_C_RESET}"
  elif (( _declared > 0 )); then
    printf '%s\n' "${_C_DIM}Pass --fix to zero the active area of those files.${_C_RESET}"
  fi
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 when nothing failed, 1 on a failed rewrite or an unusable setup.
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
    log_error "'${_target}' is not a Matroska file; only .mkv can carry an editable RPU here."
    exit 1
  fi

  setup_scratch
  scan_target
  print_summary

  (( _failed == 0 ))
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

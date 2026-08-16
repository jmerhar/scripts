#!/usr/bin/env bash
#
# Processes a shell script and replaces `# @include <path>` directives with
# the contents of the referenced file. Also strips `# shellcheck source=`
# directives that are no longer needed after inlining.
#
# Includes are resolved transitively: an included file's own directives are processed as well, each
# relative to that file's directory. A library therefore declares what it needs and a script lists only
# what it uses directly, rather than every script having to know the whole dependency graph.
#
# Each file is inlined at most once. That is not tidiness: every library guards itself with
# `if [[ -n "${_X_LOADED:-}" ]]; then return; fi`, and a second copy of that guard puts a `return` at the
# top level of the published script, where it is an error — the script would exit 2 before doing anything.
#
# A cycle is refused rather than quietly broken, so a mistake in the graph is reported instead of
# producing a script missing whichever file the cycle cut off.
#
# Usage:
#   ./compile-includes.sh <input-file> [output-file]
#   ./compile-includes.sh <input-file> -i
#
# Arguments:
#   input-file   The script to process.
#   output-file  (Optional) Write output to this file.
#   -i           Modify the input file in place.
#
# If neither output-file nor -i is given, writes to stdout.

set -o errexit
set -o nounset
set -o pipefail

# Canonical paths already inlined, and those currently being processed. The first gives dedup, the second
# tells a legitimate diamond (two libraries needing a third) from a cycle.
declare -A INLINED=()
declare -A IN_PROGRESS=()

#######################################
# Prints a timestamped error message to stderr.
# Arguments:
#   Message to print.
#######################################
log_error() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [ERROR]: $*" >&2
}

#######################################
# Prints usage instructions to stdout.
# Arguments:
#   None
#######################################
show_usage() {
  local script_basename
  script_basename=$(basename "$0")
  cat <<EOF
Usage: ${script_basename} <input-file> [output-file]
       ${script_basename} <input-file> -i

Replaces # @include <path> directives with the contents of the referenced file.

Options:
  -i    Modify the input file in place.
  -h    Show this help message.
EOF
}

#######################################
# Prints a file's canonical path, with symlinks and `..` resolved.
#
# Dedup compares paths, so `../lib/common.sh` and `../../topic/../lib/common.sh` have to come out the same
# or the same library is inlined twice — which publishes a broken script.
# Arguments:
#   path: File to canonicalise.
# Outputs:
#   The canonical path.
#######################################
canonical_path() {
  local dir base
  dir=$(cd "$(dirname "$1")" && pwd -P)
  base=$(basename "$1")
  printf '%s/%s' "${dir}" "${base}"
}

#######################################
# Prints the assignment that replaces an `# @embed` line, with the program inlined as a literal.
#
# The development form reads the program from a file:
#
#   _JQ_CANDIDATES=$(load_program candidates.jq)  # @embed candidates.jq
#
# and the published form is the same variable holding the same text, so a single-file script needs
# nothing beside it. The text is embedded single-quoted, which is what keeps a program containing `$1`,
# `$dprefix` or a backtick from being touched by the shell — the same reason the programs were quoted
# that way when they lived inside the script.
#
# Trailing newlines are stripped because `$(...)` strips them, so the compiled variable holds exactly
# what the development form held.
#
# Two guards, both fatal, because either mistake would publish a script that runs a program nobody
# tested: the name in the directive must match the name passed to load_program, and the program must
# contain no single quote, which the embedding could not survive.
# Arguments:
#   assignment_prefix: Everything left of the `=`, indentation included.
#   call_name: Program name passed to load_program.
#   directive_name: Program name given in the @embed directive.
#   base_dir: Directory to resolve the program against.
#   input_file: File being compiled, for error messages.
# Outputs:
#   The assignment, with the program text inlined.
#######################################
embed_program() {
  local assignment_prefix="$1"
  local call_name="$2"
  local directive_name="$3"
  local base_dir="$4"
  local input_file="$5"

  if [[ "${call_name}" != "${directive_name}" ]]; then
    log_error "@embed names '${directive_name}' but load_program is called with '${call_name}' (in ${input_file})."
    exit 1
  fi

  local resolved_path="${base_dir}/${directive_name}"
  if [[ ! -f "${resolved_path}" ]]; then
    log_error "Program file not found: ${resolved_path} (referenced from ${input_file})"
    exit 1
  fi

  local program
  program=$(cat "${resolved_path}")

  if [[ "${program}" == *"'"* ]]; then
    log_error "${resolved_path} contains a single quote, which cannot be embedded in the published script."
    exit 1
  fi

  printf "%s='%s'\n" "${assignment_prefix}" "${program}"
}

#######################################
# Writes out any held-back loader lines, in the order they appeared.
# Globals:
#   pending_shellcheck, pending_source — read and cleared.
#######################################
flush_pending() {
  [[ -n "${pending_shellcheck}" ]] && printf '%s\n' "${pending_shellcheck}"
  [[ -n "${pending_source}" ]] && printf '%s\n' "${pending_source}"
  pending_shellcheck=""
  pending_source=""
  return 0
}

#######################################
# Processes a single file, expanding @include directives.
# When a `# @include <path>` line is found, it is replaced with the file
# contents. Any `source`/`.` command or `# shellcheck source=` directive
# immediately preceding the @include is also stripped.
# Arguments:
#   input_file: The file to process.
#   base_dir: The directory to resolve relative include paths against.
# Outputs:
#   Writes the processed content to stdout.
#######################################
process_file() {
  local input_file="$1"
  local base_dir="$2"
  # The development-time loader for an @include is two lines — a `# shellcheck source=` hint and a
  # `source` command — and both are meaningless once the file is inlined. They are held back rather than
  # dropped on sight, because the same two lines appear inside the library around a `source "$1"` that
  # stays: there, no @include follows, so both are written out again.
  local pending_shellcheck=""
  local pending_source=""
  # Local because this function recurses: a nested call must not consume the caller's current line.
  local line

  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Match an assignment carrying an # @embed directive. Matched before the buffered-line flush below
    # because it is self-contained: unlike @include, there is no preceding loader line to drop.
    if [[ "${line}" =~ ^([[:space:]]*[^#=[:space:]][^=]*)=\$\(load_program[[:space:]]+([^\)]+)\)[[:space:]]*#[[:space:]]*@embed[[:space:]]+(.+)$ ]]; then
      local prefix="${BASH_REMATCH[1]}"
      local call_name="${BASH_REMATCH[2]}"
      local directive_name="${BASH_REMATCH[3]}"
      # Trim the whitespace the regex cannot, since both names are compared literally.
      call_name="${call_name%"${call_name##*[![:space:]]}"}"
      directive_name="${directive_name%"${directive_name##*[![:space:]]}"}"

      flush_pending

      embed_program "${prefix}" "${call_name}" "${directive_name}" "${base_dir}" "${input_file}"
      continue
    fi

    # Match # @include <path>
    if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*@include[[:space:]]+(.+)$ ]]; then
      local include_path="${BASH_REMATCH[1]}"
      # Strip surrounding quotes if present
      include_path="${include_path%\"}"
      include_path="${include_path#\"}"
      include_path="${include_path%\'}"
      include_path="${include_path#\'}"

      local resolved_path="${base_dir}/${include_path}"
      if [[ ! -f "${resolved_path}" ]]; then
        log_error "Include file not found: ${resolved_path} (referenced from ${input_file})"
        exit 1
      fi

      # Drop the held-back loader lines: they were the development-time form of this include.
      pending_shellcheck=""
      pending_source=""

      local canonical
      canonical=$(canonical_path "${resolved_path}")

      if [[ -n "${IN_PROGRESS[${canonical}]:-}" ]]; then
        log_error "Include cycle: ${include_path} is already being inlined (referenced from ${input_file})."
        exit 1
      fi

      # A file reached twice is a diamond, not a fault: two libraries may both need a third. Inlining it
      # once is what keeps its include guard from returning at the top level of the published script.
      if [[ -n "${INLINED[${canonical}]:-}" ]]; then
        continue
      fi

      IN_PROGRESS[${canonical}]=1
      process_file "${resolved_path}" "$(dirname "${resolved_path}")"
      unset "IN_PROGRESS[${canonical}]"
      INLINED[${canonical}]=1
      continue
    fi

    # A `# shellcheck source=` hint may be the first half of a loader pair, so it is held back. Any pair
    # already held is written out first, since two hints in a row cannot both belong to one include.
    if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+source= ]]; then
      flush_pending
      pending_shellcheck="${line}"
      continue
    fi

    # A `source`/`.` command is the second half. The hint above it stays held: whether either is dropped
    # depends on an @include following, which the next iteration decides.
    if [[ "${line}" =~ ^[[:space:]]*(source|\.)[[:space:]]+ ]]; then
      [[ -n "${pending_source}" ]] && printf '%s\n' "${pending_source}"
      pending_source="${line}"
      continue
    fi

    flush_pending
    printf '%s\n' "${line}"
  done < "${input_file}"

  flush_pending
}

#######################################
# Parses arguments and compiles @include directives in the input file.
# Arguments:
#   input_file  - The script to process.
#   output_file - (Optional) Output path, or -i for in-place.
#######################################
main() {
  if (( $# < 1 )); then
    log_error "Missing required input file argument."
    show_usage
    exit 1
  fi

  if [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
  fi

  local input_file="$1"
  local output_file=""
  local in_place="false"

  if (( $# >= 2 )); then
    if [[ "$2" == "-i" ]]; then
      in_place="true"
    else
      output_file="$2"
    fi
  fi

  if [[ ! -f "${input_file}" ]]; then
    log_error "Input file not found: ${input_file}"
    exit 1
  fi

  local base_dir
  base_dir=$(dirname "${input_file}")
  # Resolve to absolute path for reliable relative includes
  base_dir=$( (cd "${base_dir}" && pwd -P) )

  if [[ "${in_place}" == "true" ]]; then
    local tmp_file
    tmp_file=$(mktemp)
    process_file "${input_file}" "${base_dir}" > "${tmp_file}"
    # Overwrite the file's contents in place (rather than `mv`-ing the temp file
    # over it) so the original mode and ownership are preserved. `mktemp` creates
    # 0600 files, and a `mv` would leave the compiled script non-readable, which
    # later breaks execution once it is packaged and installed.
    cat "${tmp_file}" > "${input_file}"
    rm -f "${tmp_file}"
  elif [[ -n "${output_file}" ]]; then
    mkdir -p "$(dirname "${output_file}")"
    process_file "${input_file}" "${base_dir}" > "${output_file}"
  else
    process_file "${input_file}" "${base_dir}"
  fi
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

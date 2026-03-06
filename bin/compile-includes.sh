#!/usr/bin/env bash
# --- SCRIPT INFO START ---
# Name: compile-includes
# Description: Inlines @include directives for build-time script compilation.
# Author: Jure Merhar <dev@merhar.si>
# Homepage: https://github.com/jmerhar/scripts
# License: MIT
# --- SCRIPT INFO END ---
#
# Processes a shell script and replaces `# @include <path>` directives with
# the contents of the referenced file. Also strips `# shellcheck source=`
# directives that are no longer needed after inlining.
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

#######################################
# Prints a timestamped error message to stderr.
# Arguments:
#   Message to print.
#######################################
log_error() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: Error: $*" >&2
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
  local pending_line=""
  local has_pending="false"

  while IFS= read -r line || [[ -n "${line}" ]]; do
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

      # Drop the pending source/. line — it was the dev-time loader for this include
      has_pending="false"
      pending_line=""

      cat "${resolved_path}"
      continue
    fi

    # Flush any pending line that wasn't followed by @include
    if [[ "${has_pending}" == "true" ]]; then
      printf '%s\n' "${pending_line}"
      has_pending="false"
      pending_line=""
    fi

    # Strip shellcheck source= directives (not needed after inlining)
    if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+source= ]]; then
      continue
    fi

    # Buffer source/. commands — they may be dev-time loaders for a following @include
    if [[ "${line}" =~ ^[[:space:]]*(source|\.)[[:space:]]+ ]]; then
      pending_line="${line}"
      has_pending="true"
      continue
    fi

    printf '%s\n' "${line}"
  done < "${input_file}"

  # Flush any trailing pending line
  if [[ "${has_pending}" == "true" ]]; then
    printf '%s\n' "${pending_line}"
  fi
}

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
    mv "${tmp_file}" "${input_file}"
  elif [[ -n "${output_file}" ]]; then
    mkdir -p "$(dirname "${output_file}")"
    process_file "${input_file}" "${base_dir}" > "${output_file}"
  else
    process_file "${input_file}" "${base_dir}"
  fi
}

main "$@"

#!/usr/bin/env bash
#
# A robust script for backing up photo collections from multiple sources
# to a remote server using rsync.
#
# This script requires all settings to be provided either via a system-wide
# configuration file or through command-line options.

set -o errexit
set -o nounset
set -o pipefail

# --- Global Constants ---
TEMP_DIR=$(mktemp -d)
readonly TEMP_DIR

# --- Shared Library ---
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../lib/common.sh"
# @include ../lib/common.sh

# --- Configuration (initialized as empty) ---
SOURCES=()
HOST=""
DEST_PATH=""
LOG_FILE=""
DRY_RUN_FLAG=""

# --- Runtime variables ---
DESTINATION="" # Will be set in main after config is validated.

trap 'rm -rf "${TEMP_DIR}"' EXIT

#######################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]
Syncs photos from multiple sources to a remote backup server.

Required settings must be provided either in a config file
(e.g., /etc/${SCRIPT_NAME}.conf) or via the options below.

Options:
  -s PATH       Source path (can be used multiple times)
  -H HOST       Backup server hostname (required)
  -p PATH       Destination path (required)
  -l FILE       Log file path (optional)
  -n            Dry-run mode (no changes are made)
  -d            Debug mode (enables verbose logging)
  -h            Show this help message
EOF
}

#######################################
# Parses command-line options, overriding any config file values.
# Globals:
#   SOURCES, HOST, DEST_PATH, LOG_FILE, DRY_RUN_FLAG
# Arguments:
#   Command-line arguments passed to the script.
#######################################
parse_options() {
  while getopts ":s:H:p:l:ndh" opt; do
    case "${opt}" in
      s) SOURCES+=("${OPTARG}") ;;
      H) HOST="${OPTARG}" ;;
      p) DEST_PATH="${OPTARG}" ;;
      l) LOG_FILE="${OPTARG}" ;;
      n) DRY_RUN_FLAG="--dry-run" ;;
      d) enable_debug_mode ;;
      h)
        show_usage
        exit 0
        ;;
      :)
        log_error "Option -${OPTARG} requires an argument."
        show_usage
        exit 1
        ;;
      *)
        log_error "Invalid option: -${OPTARG}"
        show_usage
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))

  if (( $# > 0 )); then
    log_error "Unexpected arguments: $*"
    show_usage
    exit 1
  fi
}

#######################################
# Logs a command to debug, then executes it, capturing output to the log file.
# Globals:
#   LOG_FILE
# Arguments:
#   Command and its arguments.
#######################################
run_command() {
  log_debug "Running command: $*"
  if [[ -n "${LOG_FILE}" ]]; then
    # Log both streams to the file while preserving stderr/stdout separation
    "$@" > >(tee -a "${LOG_FILE}") 2> >(tee -a "${LOG_FILE}" >&2)
  else
    "$@"
  fi
}

#######################################
# Verifies that a source directory exists and is not empty.
# Arguments:
#   Directory path to verify.
#######################################
verify_source_directory() {
  local dir="$1"

  if [[ ! -d "${dir}" ]]; then
    log_error "Source directory '${dir}' not found or not mounted."
    exit 1
  fi

  if ! find "${dir}" -mindepth 1 -print -quit | grep -q .; then
    log_error "Source directory '${dir}' appears to be empty. Aborting for safety."
    exit 1
  fi
}

#######################################
# Removes files matching a pattern from a directory.
# Arguments:
#   dir: The directory to clean.
#   pattern: The file pattern to remove (e.g., '*.tmp').
#######################################
remove_files() {
  local dir="$1"
  local pattern="$2"

  log_info "Deleting '${pattern}' files from '${dir}'..."
  run_command find "${dir}" -name "${pattern}" -delete -print
}

#######################################
# Cleans a directory of common temporary and metadata files.
# The following are removed:
#   - .DS_Store: macOS Finder metadata, not needed in backups.
#   - *_original: Lightroom/Photoshop original files created when
#     editing (e.g., "IMG_1234_original"). Safe to remove since the
#     actual originals are the RAW files.
# Arguments:
#   dir: The directory to clean.
#######################################
clean_directory() {
  local dir="$1"

  log_info "Cleaning temporary files in '${dir}'..."
  remove_files "${dir}" '.DS_Store'
  remove_files "${dir}" '*_original'

  if command -v dot_clean &> /dev/null; then
    run_command dot_clean -v "${dir}"
  else
    log_info "Skipping 'dot_clean': command not found (expected on non-macOS)."
  fi
}

#######################################
# Generates rsync protection filter rules from multiple directories.
# Arguments:
#   filter_file: The path to write the generated filter rules to.
#   protect_dirs: An array of source directories whose contents should be protected.
#######################################
generate_protection_filter() {
  local filter_file="$1"
  shift
  local protect_dirs=("$@")

  # Truncate the filter file to ensure it's empty before starting
  true > "${filter_file}"

  for protect_src in "${protect_dirs[@]}"; do
    log_info "Generating protection rules for '${protect_src}'"
    # Use sh to create a subshell, ensuring path variables are handled correctly
    run_command bash -c '
      set -o errexit
      set -o pipefail
      # The find command lists all items, and the while loop creates relative paths
      find "$1" -mindepth 1 -print0 | while IFS= read -r -d "" path; do
        relative_path="${path#"$1"/}"
        # "P" is rsync syntax to protect the path from deletion
        printf "P /%s\n" "${relative_path}"
      done >> "$2"
    ' _ "${protect_src}" "${filter_file}"
  done
}

#######################################
# Validates that a filter file exists and is not empty.
# Arguments:
#   filter_file: Path to the filter file to validate.
#######################################
validate_filter_file() {
  local filter_file="$1"

  if [[ ! -f "${filter_file}" ]]; then
    log_error "FATAL: Protection filter file '${filter_file}' was not created."
    exit 1
  fi

  if [[ ! -s "${filter_file}" ]]; then
    log_error "FATAL: Protection filter file '${filter_file}' is empty. Aborting to prevent data loss."
    exit 1
  fi
}

#######################################
# Performs the rsync backup operation, optionally using a protection filter.
# Globals:
#   DESTINATION, DRY_RUN_FLAG
# Arguments:
#   source_dir: The directory to back up.
#   filter_file: (Optional) The path to the rsync filter file. If empty,
#                no filter is used.
#######################################
perform_backup() {
  local source_dir="$1"
  # Default to empty string if filter_file is not provided
  local filter_file="${2:-}"

  log_info "Backing up '${source_dir}' to '${DESTINATION}'..."

  local rsync_args=(
    -aHv
    --progress
    --exclude '.*'
    --delete
  )

  if [[ -n "${DRY_RUN_FLAG}" ]]; then
    rsync_args+=("${DRY_RUN_FLAG}")
  fi

  if [[ -n "${filter_file}" ]]; then
    log_info "Using protection filter: ${filter_file}"
    rsync_args+=(--filter="merge ${filter_file}")
  fi

  run_command rsync "${rsync_args[@]}" "${source_dir}/" "${DESTINATION}"
}

#######################################
# Loads config, parses CLI options, and runs the photo backup pipeline.
# Globals:
#   SOURCES, HOST, DEST_PATH, LOG_FILE, DESTINATION, DRY_RUN_FLAG
# Arguments:
#   Command-line arguments passed to the script.
#######################################
main() {
  load_config || true  # Config is optional; CLI args can provide everything
  parse_options "$@"
  validate_config "HOST" "DEST_PATH" "array:SOURCES" || { show_usage; exit 1; }

  # If LOG_FILE is not set, determine a default location based on the script's prefix
  if [[ -z "${LOG_FILE}" ]]; then
    local prefix
    prefix=$(get_script_prefix)
    if [[ -n "${prefix}" ]]; then
      LOG_FILE="${prefix}/var/log/${SCRIPT_NAME}.log"
      log_info "No log file specified. Defaulting to: ${LOG_FILE}"
    fi
  fi

  DESTINATION="${HOST}:${DEST_PATH}"

  log_info "Starting photo backup operation."
  local source_label="directories"
  if (( ${#SOURCES[@]} == 1 )); then
    source_label="directory"
  fi
  log_info "Found ${#SOURCES[@]} source ${source_label}:"
  for src in "${SOURCES[@]}"; do
    log_info " -> ${src}"
  done
  log_info "Destination: ${DESTINATION}"
  if [[ -n "${LOG_FILE}" ]]; then
    log_info "Logging to: ${LOG_FILE}"
  fi
  if [[ -n "${DRY_RUN_FLAG}" ]]; then
    log_info "Dry-run mode is enabled. No files will be changed."
  fi

  for src in "${SOURCES[@]}"; do
    verify_source_directory "${src}"
  done

  if [[ -z "${DRY_RUN_FLAG}" ]]; then
    for src in "${SOURCES[@]}"; do
      clean_directory "${src}"
    done
  fi

  # --- Main Backup Loop ---
  for i in "${!SOURCES[@]}"; do
    local current_source="${SOURCES[i]}"
    local protect_sources=()

    # Build an array of all other sources to protect
    for j in "${!SOURCES[@]}"; do
      if (( i != j )); then
        protect_sources+=("${SOURCES[j]}")
      fi
    done

    log_info "--- Starting backup for '${current_source}' ---"

    local filter_file=""

    # If there are other sources, generate a protection filter for them
    if (( ${#protect_sources[@]} > 0 )); then
      filter_file="${TEMP_DIR}/filter.rules"
      generate_protection_filter "${filter_file}" "${protect_sources[@]}"
      validate_filter_file "${filter_file}"
    else
      log_info "Only one source directory specified, or this is the only source; running sync without protection filter."
    fi

    # Perform the backup, passing the filter file path (which will be empty if not generated)
    perform_backup "${current_source}" "${filter_file}"
  done

  log_info "Backup operation completed successfully."
}

main "$@"

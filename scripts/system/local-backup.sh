#!/usr/bin/env bash
#
# A script to create an incremental backup and then automatically prune old ones
# based on a retention policy defined in its configuration file.

# Exit immediately if a command exits with a non-zero status.
set -o errexit
# Treat unset variables as an error when substituting.
set -o nounset
# Pipelines return the exit status of the last command to fail.
set -o pipefail

# --- Global Constants ---
readonly MDSTAT_CHECK_INTERVAL=300 # Seconds between /proc/mdstat checks

# --- Shared Library ---
_LOG_QUIET="true"
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../lib/common.sh"
# @include ../lib/common.sh

#######################################
# Prints the script's usage instructions to stderr.
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
#######################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]
Creates an incremental rsync backup and prunes old backups.

All settings are read from a configuration file
(e.g., /etc/${SCRIPT_NAME}.conf).

Options:
  -d    Debug mode (enables verbose logging to stderr)
  -h    Show this help message
EOF
}

#######################################
# Parses command-line options.
# Globals:
#   IS_DEBUG_MODE
# Arguments:
#   Command-line arguments passed to the script.
#######################################
parse_options() {
  while getopts ":dh" opt; do
    case "${opt}" in
      d) enable_debug_mode ;;
      h)
        show_usage
        exit 0
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
# Performs an incremental backup using rsync.
# Globals:
#   SOURCE_DIR, BACKUP_DIR, EXCLUDES
#######################################
run_backup() {
  log_info "Starting backup..."

  local datetime
  datetime="$(date '+%Y-%m-%d_%H:%M:%S')"
  local backup_path="${BACKUP_DIR}/${datetime}"
  local latest_link="${BACKUP_DIR}/latest"

  local rsync_excludes=()
  for pattern in "${EXCLUDES[@]}"; do
    rsync_excludes+=("--exclude=${pattern}")
  done

  log_info "Creating new backup at: ${backup_path}"
  mkdir -p "${backup_path}"

  log_info "Running rsync..."
  local rsync_exit_code=0
  local rsync_opts=(-ax --delete)

  # Show progress when running interactively
  if [[ -t 1 ]]; then
    rsync_opts+=(--info=progress2)
  fi

  log_debug "rsync command: rsync ${rsync_opts[*]} ${rsync_excludes[*]} ${SOURCE_DIR}/ --link-dest ${latest_link} ${backup_path}"

  rsync "${rsync_opts[@]}" \
    "${rsync_excludes[@]}" \
    "${SOURCE_DIR}/" \
    --link-dest "${latest_link}" \
    "${backup_path}" || rsync_exit_code=$?

  if [[ ${rsync_exit_code} -eq 0 ]]; then
    log_info "Rsync process completed successfully."
  elif [[ ${rsync_exit_code} -eq 24 ]]; then
    # This non-fatal error means some files vanished during transfer.
    # It's common for temp files and is safe to ignore.
    log_info "Rsync completed with a non-fatal warning (code 24): Some source files vanished during transfer."
  else
    log_error "Rsync failed with a critical error (code ${rsync_exit_code})."
    exit "${rsync_exit_code}"
  fi

  log_info "Updating the 'latest' symbolic link."
  ln -sfn "${backup_path}" "${latest_link}"

  log_info "Backup operation completed."
}

#######################################
# Automatically prunes old backups based on the retention policy.
# Globals:
#   BACKUP_DIR, KEEP_BACKUPS
#######################################
run_prune() {
  log_info "Starting automatic backup pruning for: ${BACKUP_DIR}"

  mapfile -t backups < <(find "${BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d -name '[0-9][0-9][0-9][0-9]-*' | sort)
  local total_backups=${#backups[@]}
  log_debug "Found ${total_backups} existing backup(s) in ${BACKUP_DIR}"

  if (( total_backups <= KEEP_BACKUPS )); then
    log_info "Total backups (${total_backups}) is not greater than the number to keep (${KEEP_BACKUPS}). No pruning needed."
    return 0
  fi

  local delete_count=$((total_backups - KEEP_BACKUPS))
  local backups_to_delete=("${backups[@]:0:${delete_count}}")

  log_info "Found ${total_backups} backups. Deleting ${delete_count} oldest backup(s)..."
  for backup_to_delete in "${backups_to_delete[@]}"; do
    local backup_name
    backup_name=$(basename "${backup_to_delete}")
    log_info "Deleting: ${backup_name}"
    if ! rm -rf "${backup_to_delete}"; then
        log_error "Failed to delete backup directory: ${backup_name}"
    fi
  done

  log_info "Pruning complete!"
}

#######################################
# Waits for any active RAID resync/check/rebuild operations to finish.
# Polls /proc/mdstat at a regular interval. If /proc/mdstat does not
# exist (e.g., no RAID arrays on this system), returns immediately.
# Globals:
#   MDSTAT_CHECK_INTERVAL
# Arguments:
#   None
#######################################
wait_for_raid() {
  if [[ ! -f /proc/mdstat ]]; then
    log_debug "/proc/mdstat not found, skipping RAID check."
    return
  fi

  while grep -qE '\[(resync|check|recover|reshape)' /proc/mdstat 2>/dev/null; do
    log_info "RAID operation in progress. Waiting ${MDSTAT_CHECK_INTERVAL}s before rechecking..."
    sleep "${MDSTAT_CHECK_INTERVAL}"
  done
}

#######################################
# Lowers the I/O scheduling priority of the current process to idle.
# This ensures the backup yields I/O to other processes.
# Globals:
#   None
# Arguments:
#   None
#######################################
set_low_io_priority() {
  if ! command -v ionice &> /dev/null; then
    log_info "ionice not found, skipping I/O priority adjustment."
    return
  fi
  ionice -c3 -p $$
  log_info "I/O priority set to idle (class 3)."
  log_debug "ionice applied to PID $$"
}

#######################################
# Main function to orchestrate the script's execution.
# Globals:
#   All (via function calls)
# Arguments:
#   All arguments passed to the script.
#######################################
main() {
  parse_options "$@"
  load_config || { log_error "Configuration file not found."; exit 1; }
  validate_config "SOURCE_DIR" "BACKUP_DIR" "int:KEEP_BACKUPS" "array:EXCLUDES" || exit 1

  log_debug "Configuration loaded: SOURCE_DIR=${SOURCE_DIR}, BACKUP_DIR=${BACKUP_DIR}, KEEP_BACKUPS=${KEEP_BACKUPS}"
  log_debug "Exclude patterns: ${EXCLUDES[*]}"

  # Prevent concurrent backup runs using a lockfile.
  local lock_file="${BACKUP_DIR}/.local-backup.lock"
  exec 9>"${lock_file}"
  if ! flock -n 9; then
    log_error "Another backup is already running (lockfile: ${lock_file}). Exiting."
    exit 1
  fi
  log_debug "Lock acquired: ${lock_file}"

  if [[ -n "${LOG_FILE:-}" ]]; then
    log_info "Logging to: ${LOG_FILE}"
  fi

  set_low_io_priority
  wait_for_raid

  run_backup
  run_prune
}

# Execute the main function with all script arguments.
main "$@"

#!/usr/bin/env bash
# --- SCRIPT INFO START ---
# Name: local-backup
# Description: A generic script to create and automatically prune rsync-based system backups.
# Author: Jure Merhar <dev@merhar.si>
# Homepage: https://github.com/jmerhar/scripts
# ConfigFile: local-backup.conf
# Dependencies: rsync
# License: MIT
# --- SCRIPT INFO END ---
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
SCRIPT_NAME=$(basename "$0" .sh)
readonly SCRIPT_NAME
readonly MDSTAT_CHECK_INTERVAL=300 # Seconds between /proc/mdstat checks

# --- Runtime Variables ---
CONFIG_FILE_LOADED="" # Populated by load_config()

#######################################
# Internal function to handle writing log messages to the log file.
# Globals:
#   LOG_FILE
# Arguments:
#   level: The log level (e.g., INFO, ERROR).
#   message: The message to log.
#######################################
log_message() {
  # Return early if LOG_FILE is not set
  if [[ -z "${LOG_FILE:-}" ]]; then
    return
  fi

  local level="$1"
  shift
  local message="$*"
  local msg
  msg="[$(date +'%Y-%m-%dT%H:%M:%S%z')] [${level}]: ${message}"

  # Ensure the directory exists before attempting to write to the file
  mkdir -p "$(dirname "${LOG_FILE}")"
  echo "${msg}" >> "${LOG_FILE}"
}

#######################################
# Prints a timestamped info message to the log file only.
# Globals:
#   None
# Arguments:
#   Message to print.
#######################################
log_info() {
  log_message "INFO" "$*"
}

#######################################
# Prints a timestamped error message to stderr and to the log file.
# Globals:
#   None
# Arguments:
#   Message to print.
#######################################
log_error() {
  log_message "ERROR" "$*"
  # Always print errors to stderr for cron jobs.
  printf "%s\n" "[ERROR]: $*" >&2
}

#######################################
# Determines the installation prefix of the script (e.g., /usr/local).
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Prints the install prefix to stdout.
#######################################
get_script_prefix() {
  local script_dir
  script_dir=$(dirname "$0")
  local script_path
  script_path=$( (cd "${script_dir}" && pwd -P))

  if [[ -z "${script_path}" ]]; then
    return
  fi

  local bin_dir
  bin_dir=$(basename "${script_path}")
  if [[ "${bin_dir}" =~ ^(bin|sbin)$ ]]; then
    dirname "${script_path}"
  fi
}

#######################################
# Finds and sources the configuration file from standard system locations.
# Globals:
#   SCRIPT_NAME, CONFIG_FILE_LOADED
# Arguments:
#   None
# Outputs:
#   Sources the config file, populating global config variables.
#   Exits with an error if the config file cannot be found.
#######################################
load_config() {
  local prefix
  prefix=$(get_script_prefix)
  local config_path_prefix=""
  local config_path_system="/etc/${SCRIPT_NAME}.conf"

  # Define the prefix-based path only if a prefix was found.
  if [[ -n "${prefix}" ]]; then
    config_path_prefix="${prefix}/etc/${SCRIPT_NAME}.conf"
  fi

  # Check for config relative to prefix first, then the system-wide path.
  if [[ -n "${config_path_prefix}" && -r "${config_path_prefix}" ]]; then
    CONFIG_FILE_LOADED="${config_path_prefix}"
  elif [[ -r "${config_path_system}" ]]; then
    CONFIG_FILE_LOADED="${config_path_system}"
  fi

  if [[ -z "${CONFIG_FILE_LOADED}" ]]; then
    log_error "Configuration file not found. The script looked in the following locations:"
    if [[ -n "${config_path_prefix}" ]]; then
      log_error "  - ${config_path_prefix}"
    fi
    log_error "  - ${config_path_system}"
    exit 1
  fi

  log_info "Loading configuration from: ${CONFIG_FILE_LOADED}"
  # Source the config file to load variables.
  set +o nounset
  # shellcheck source=/dev/null
  source "${CONFIG_FILE_LOADED}"
  set -o nounset
}

#######################################
# Validates that all required variables have been loaded from the config file.
# Globals:
#   SOURCE_DIR, BACKUP_DIR, EXCLUDES, KEEP_BACKUPS, CONFIG_FILE_LOADED
# Arguments:
#   None
# Outputs:
#   Exits with an error if any required variables are missing.
#######################################
validate_config() {
  local required_vars=("SOURCE_DIR" "BACKUP_DIR" "KEEP_BACKUPS")
  local unset_vars=()

  for var_name in "${required_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
      unset_vars+=("${var_name}")
    fi
  done

  # Special check for the EXCLUDES array, which cannot be empty.
  if ! declare -p EXCLUDES &>/dev/null || (( ${#EXCLUDES[@]} == 0 )); then
    unset_vars+=("EXCLUDES")
  fi

  if (( ${#unset_vars[@]} > 0 )); then
    log_error "The following required settings are missing in '${CONFIG_FILE_LOADED}':"
    for var in "${unset_vars[@]}"; do
      log_error "  - ${var}"
    done
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
  rsync -ax --delete \
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
}

#######################################
# Main function to orchestrate the script's execution.
# Globals:
#   All (via function calls)
# Arguments:
#   All arguments passed to the script.
#######################################
main() {
  load_config
  validate_config

  # Prevent concurrent backup runs using a lockfile.
  local lock_file="${BACKUP_DIR}/.local-backup.lock"
  exec 9>"${lock_file}"
  if ! flock -n 9; then
    log_error "Another backup is already running (lockfile: ${lock_file}). Exiting."
    exit 1
  fi

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

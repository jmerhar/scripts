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
readonly SCRIPT_NAME=$(basename "$0" .sh)

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
  if (( ${#EXCLUDES[@]} == 0 )); then
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
  rsync -ax --delete \
    "${rsync_excludes[@]}" \
    "${SOURCE_DIR}/" \
    --link-dest "${latest_link}" \
    "${backup_path}"

  log_info "Updating the 'latest' symbolic link."
  rm -f "${latest_link}"
  ln -s "${backup_path}" "${latest_link}"
  
  log_info "Backup completed successfully!"
}

#######################################
# Automatically prunes old backups based on the retention policy.
# Globals:
#   BACKUP_DIR, KEEP_BACKUPS
#######################################
run_prune() {
  log_info "Starting automatic backup pruning for: ${BACKUP_DIR}"
  
  mapfile -t backups < <(find "${BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d | sort)
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
# Main function to orchestrate the script's execution.
# Globals:
#   All (via function calls)
# Arguments:
#   All arguments passed to the script.
#######################################
main() {
  load_config
  validate_config

  if [[ -n "${LOG_FILE:-}" ]]; then
    log_info "Logging to: ${LOG_FILE}"
  fi

  run_backup
  run_prune
}

# Execute the main function with all script arguments.
main "$@"

#!/usr/bin/env bash
# --- SCRIPT INFO START ---
# Name: package-script
# Description: A generic package-file generator for Homebrew and Debian.
# Author: Jure Merhar <dev@merhar.si>
# Homepage: https://github.com/jmerhar/scripts
# Dependencies: awk
# Debian-Dependencies: dpkg-deb
# License: MIT
# --- SCRIPT INFO END ---
#
# A generic package-file generator designed to be run from a CI/CD workflow.
#
# It takes the path to a script as an argument, parses metadata from a
# corresponding comment block on top of the script, and generates the necessary
# package files (.rb for Homebrew and .deb for Debian).
#
# The script is configured entirely through environment variables and places its
# output into local directories specified by those variables, decoupling it
# from any specific repository structure.
#
# Usage:
#   ./package-script.sh <path-to-script>
#
# Environment variables:
#   - PKGSCR_HOMEBREW_FORMULA_DIR: Local output directory for Homebrew formula files.
#   - PKGSCR_DEB_PACKAGE_DIR: Local output directory for Debian package files.
#   - PKGSCR_CONFIG_DIR: The directory where source config files are located.
#   - PKGSCR_TARBALL_URL: URL to the new release tarball.
#   - PKGSCR_VERSION: The version string (e.g., "v1.0.1").
#   - PKGSCR_SHA256_CHECKSUM: The checksum of the tarball.

set -o errexit
set -o nounset
set -o xtrace

#######################################
# Prints a timestamped error message to stderr for runtime errors.
# Globals:
#   None
# Arguments:
#   Message to print.
# Outputs:
#   Writes timestamped message to stderr.
#######################################
log_error() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: Error: $*" >&2
}

#######################################
# Prints the script's usage instructions to stdout.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
#######################################
show_usage() {
  local script_basename
  script_basename=$(basename "$0")
  echo "Usage: ${script_basename} <path-to-script>"
  echo "Example: ${script_basename} utility/unlock-pdf.sh"
}

# --- Global variables for dependencies and metadata ---
declare -A metadata=()
source_script_path=""
script_name=""
config_file_path=""

# The start and end markers for the metadata block
readonly METADATA_START="# --- SCRIPT INFO START ---"
readonly METADATA_END="# --- SCRIPT INFO END ---"
readonly REQUIRED_FIELDS=("Name" "Description" "Author" "Homepage")

#######################################
# Validates that all required environment variables are set.
# Globals:
#   None
# Arguments:
#   An array of variable names to check.
# Outputs:
#   Exits with an error if any required variable is not set.
#######################################
validate_env_vars() {
  local required_vars=("$@")
  local unset_vars=()

  for var_name in "${required_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
      unset_vars+=("${var_name}")
    fi
  done

  if (( ${#unset_vars[@]} > 0 )); then
    log_error "The following required environment variables are missing: ${unset_vars[*]}"
    exit 1
  fi
}

#######################################
# Parses the script path to set global script and name variables.
# Arguments:
#   Path to the script to be published.
# Outputs:
#   Sets source_script_path and script_name global variables.
#######################################
parse_script_info() {
  source_script_path="$1"
  script_name=$(basename "${source_script_path%.*}")
}

#######################################
# Checks for an optional config file associated with the script.
# Globals:
#   script_name
#   PKGSCR_CONFIG_DIR
#   metadata
# Arguments:
#   None
# Outputs:
#   Sets the config_file_path global variable if a file is found.
#######################################
find_config_file() {
  local config_name="${metadata[ConfigFile]:-}"

  # If a config file is specified in the metadata
  if [[ -n "${config_name}" ]]; then
    # Validate that PKGSCR_CONFIG_DIR is set and is a directory
    if [[ -z "${PKGSCR_CONFIG_DIR:-}" || ! -d "${PKGSCR_CONFIG_DIR}" ]]; then
      log_error "A config file ('${config_name}') is specified in the metadata, but the PKGSCR_CONFIG_DIR environment variable is not set or is not a directory."
      exit 1
    fi
    
    local potential_config_path="${PKGSCR_CONFIG_DIR}/${config_name}"
    # Validate that the config file exists on disk
    if [[ -f "${potential_config_path}" ]]; then
      echo "Found optional config file: ${potential_config_path}"
      config_file_path="${potential_config_path}"
    else
      log_error "The specified config file '${config_name}' was not found at '${potential_config_path}'."
      exit 1
    fi
  else
    # No config file is specified, so we don't need to do anything.
    config_file_path=""
  fi
}

#######################################
# Parses the script's comment block for its metadata.
# Globals:
#   source_script_path, metadata
# Arguments:
#   None
# Outputs:
#   Populates the global metadata associative array.
#   Exits with an error if metadata is not found or is incomplete.
#######################################
parse_script_metadata() {
  echo "Parsing metadata from script..."

  local in_metadata_block="false"
  
  # Check if the file exists and is readable.
  if [[ ! -f "${source_script_path}" ]]; then
    log_error "Script file not found at '${source_script_path}'"
    exit 1
  fi
  
  # A state machine to parse the script file.
  while IFS= read -r line; do
    
    if [[ "${line}" == "${METADATA_START}" ]]; then
      in_metadata_block="true"
      continue
    fi

    if [[ "${line}" == "${METADATA_END}" ]]; then
      in_metadata_block="false"
      break
    fi

    if [[ "${in_metadata_block}" == "true" ]]; then
      # Use a regex to capture the key-value pair, including the leading '# '
      if [[ "${line}" =~ ^#\ ([[:alnum:]-]+):[[:space:]]*(.*)$ ]]; then
        local key="${BASH_REMATCH[1]}"
        local value="${BASH_REMATCH[2]}"
        metadata[${key}]="${value}"
      fi
    fi
  done < "${source_script_path}"

  if [[ "${in_metadata_block}" == "true" ]]; then
    log_error "Metadata block not properly closed with '${METADATA_END}' in ${source_script_path}"
    exit 1
  fi
  
  # Check for mandatory fields
  local missing_fields=()
  for field in "${REQUIRED_FIELDS[@]}"; do
    if [[ -z "${metadata[${field}]:-}" ]]; then
      missing_fields+=("${field}")
    fi
  done

  if (( ${#missing_fields[@]} > 0 )); then
    log_error "The following required fields are missing from the script metadata: ${missing_fields[*]}"
    exit 1
  fi
}

#######################################
# Generates the Homebrew formula file.
# Globals:
#   PKGSCR_HOMEBREW_FORMULA_DIR, metadata, PKGSCR_TARBALL_URL, PKGSCR_SHA256_CHECKSUM,
#   source_script_path, config_file_path
# Arguments:
#   None
#######################################
generate_homebrew_formula() {
  local script_name="${metadata[Name]}"
  local homepage="${metadata[Homepage]}"
  local description="${metadata[Description]}"

  mkdir -p "${PKGSCR_HOMEBREW_FORMULA_DIR}"
  local formula_file="${PKGSCR_HOMEBREW_FORMULA_DIR}/${script_name}.rb"
  local class_name
  class_name=$(echo "${script_name}" | awk -F'-' '{
    for (i=1; i<=NF; i++) {
      printf "%s", toupper(substr($i,1,1)) substr($i,2)
    }
    print ""
  }')

  echo "Creating or updating Homebrew formula: ${formula_file}"

  cat > "${formula_file}" <<EOF
# This file was generated by the package-script.sh script.
class ${class_name} < Formula
  desc "${description}"
  homepage "${homepage}"
  url "${PKGSCR_TARBALL_URL}"
  sha256 "${PKGSCR_SHA256_CHECKSUM}"
$(
  # Dynamically add other metadata fields that are not hardcoded
  for key in "${!metadata[@]}"; do
    # Skip mandatory fields already handled
    if [[ "${key}" == "Name" || "${key}" == "Description" || "${key}" == "Author" || "${key}" == "Homepage" ]]; then
      continue
    fi
    # Skip special fields
    if [[ "${key}" == "Dependencies" || "${key}" == "Homebrew-Dependencies" || "${key}" == "Debian-Dependencies" || "${key}" == "ConfigFile" ]]; then
      continue
    fi
    echo "  $(echo "${key}" | tr '[:upper:]' '[:lower:]') \"${metadata[${key}]}\""
  done
  # Combine dependencies
  for dep_name in ${metadata[Dependencies]:-}; do
    echo "  depends_on \"${dep_name}\""
  done
  for dep_name in ${metadata[Homebrew-Dependencies]:-}; do
    echo "  depends_on \"${dep_name}\""
  done
)
  def install
    bin.install "${source_script_path}" => "${script_name}"
    $(if [[ -n "${config_file_path}" ]]; then
      echo "etc.install \"${config_file_path}\" => \"${metadata[ConfigFile]}\""
    fi)
  end
end
EOF
}

#######################################
# Generates the Debian (.deb) package.
# Globals:
#   PKGSCR_DEB_PACKAGE_DIR, metadata, PKGSCR_VERSION, source_script_path, config_file_path
# Arguments:
#   None
# Returns:
#   0 if successful, 1 on failure.
#######################################
generate_deb_package() {
  echo "Generating Debian (.deb) package..."

  if ! command -v dpkg-deb &> /dev/null; then
    log_error "'dpkg-deb' not found. Skipping .deb package generation."
    return 1
  fi

  local script_name="${metadata[Name]}"
  local deb_version="${PKGSCR_VERSION#v}"
  local deb_dependencies=""

  # Combine dependencies
  for dep_name in ${metadata[Dependencies]:-}; do
    if [[ -n "${deb_dependencies}" ]]; then deb_dependencies+=", "; fi
    deb_dependencies+="${dep_name}"
  done
  for dep_name in ${metadata[Debian-Dependencies]:-}; do
    if [[ -n "${deb_dependencies}" ]]; then deb_dependencies+=", "; fi
    deb_dependencies+="${dep_name}"
  done

  local package_dir="${PKGSCR_DEB_PACKAGE_DIR}/${script_name}-${PKGSCR_VERSION}"
  local control_dir="${package_dir}/DEBIAN"
  local bin_dir="${package_dir}/usr/local/bin"
  local etc_dir="${package_dir}/usr/local/etc"
  local deb_file="${PKGSCR_DEB_PACKAGE_DIR}/${script_name}_${deb_version}_all.deb"

  mkdir -p "${PKGSCR_DEB_PACKAGE_DIR}"
  rm -rf "${package_dir}"
  mkdir -p "${control_dir}" "${bin_dir}"

  # Build the control file
  echo "Package: ${script_name}" > "${control_dir}/control"
  echo "Version: ${deb_version}" >> "${control_dir}/control"
  echo "Architecture: all" >> "${control_dir}/control"
  
  if [[ -n "${deb_dependencies}" ]]; then
    echo "Depends: ${deb_dependencies}" >> "${control_dir}/control"
  fi
  echo "Maintainer: ${metadata[Author]}" >> "${control_dir}/control"
  
  # Add all other optional fields BEFORE the Description
  for key in "${!metadata[@]}"; do
    # Skip mandatory and special fields
    if [[ "${REQUIRED_FIELDS[*]}" =~ ${key} || "${key}" =~ ^(Dependencies|Homebrew-Dependencies|Debian-Dependencies|ConfigFile|Description)$ ]]; then
      continue
    fi
    echo "${key}: ${metadata[${key}]}" >> "${control_dir}/control"
  done
  
  # Add the Description and the correctly-indented long description
  echo "Description: ${metadata[Description]}" >> "${control_dir}/control"
  echo " This package installs the '${script_name}' script." >> "${control_dir}/control"

  cp "${source_script_path}" "${bin_dir}/${script_name}"
  chmod +x "${bin_dir}/${script_name}"

  if [[ -n "${config_file_path}" ]]; then
    mkdir -p "${etc_dir}"
    cp "${config_file_path}" "${etc_dir}/${metadata[ConfigFile]}"
  fi

  echo "Building .deb package..."
  dpkg-deb --build "${package_dir}" "${deb_file}"
  rm -rf "${package_dir}"

  if [[ -f "${deb_file}" ]]; then
    echo "Debian package created successfully: ${deb_file}"
  else
    log_error "Failed to create Debian package."
    return 1
  fi
}

main() {
  validate_env_vars "PKGSCR_HOMEBREW_FORMULA_DIR" "PKGSCR_DEB_PACKAGE_DIR" "PKGSCR_CONFIG_DIR" "PKGSCR_TARBALL_URL" "PKGSCR_VERSION" "PKGSCR_SHA256_CHECKSUM"

  if (( $# != 1 )); then
    log_error "Missing required script path argument."
    show_usage
    exit 1
  fi

  parse_script_info "$1"
  parse_script_metadata
  find_config_file
  generate_homebrew_formula
  generate_deb_package
}

main "$@"

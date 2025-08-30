#!/bin/bash
#
# A generic package-file generator designed to be run from a CI/CD workflow.
#
# It takes the path to a script as an argument, parses metadata from a
# corresponding README.md file (expected in the same directory), and generates
# the necessary package files (.rb for Homebrew and .deb for Debian).
#
# The script is configured entirely through environment variables and places its
# output into local directories specified by those variables, decoupling it
# from any specific repository structure.
#
# Usage:
#   ./package-script.sh <path-to-script>
#
# Environment variables:
#   - HOMEPAGE_URL: The URL for the project's homepage.
#   - HOMEBREW_FORMULA_DIR: Local output directory for Homebrew formula files.
#   - DEB_PACKAGE_DIR: Local output directory for Debian package files.
#   - CONFIG_DIR: The directory where source config files are located.
#   - MAINTAINER_INFO: Maintainer's name and email for Debian packages.
#   - TARBALL_URL: URL to the new release tarball.
#   - VERSION: The version string (e.g., "v1.0.1").
#   - SHA256_CHECKSUM: The checksum of the tarball.

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

#######################################
# Parses the script path to set global script and name variables.
# Arguments:
#   Path to the script to be published.
# Outputs:
#   Sets source_script_path, readme_path, and script_name global variables.
#######################################
parse_script_info() {
  source_script_path="$1"
  script_name=$(basename "${source_script_path%.*}")
  # Assumes README is in the same directory as the script.
  readme_path="$(dirname "${source_script_path}")/README.md"
}

#######################################
# Checks for an optional config file associated with the script.
# Globals:
#   script_name
#   CONFIG_DIR
# Arguments:
#   None
# Outputs:
#   Sets the config_file_path global variable if a file is found.
#######################################
find_config_file() {
  # If CONFIG_DIR is not set or not a directory, skip the check.
  if [[ -z "${CONFIG_DIR:-}" || ! -d "${CONFIG_DIR}" ]]; then
    config_file_path=""
    return
  fi

  local potential_config_path="${CONFIG_DIR}/${script_name}.conf"
  if [[ -f "${potential_config_path}" ]]; then
    echo "Found optional config file: ${potential_config_path}"
    config_file_path="${potential_config_path}"
  else
    config_file_path=""
  fi
}

# --- Global variables for dependencies ---
homebrew_dependencies=""
deb_dependencies=""

#######################################
# Parses the script's README for its description and dependencies.
# Globals:
#   readme_path, script_name
# Arguments:
#   None
# Outputs:
#   Sets description, homebrew_dependencies, and deb_dependencies global variables.
#######################################
parse_readme() {
  echo "Parsing README.md for description and dependencies..."

  if [[ ! -f "${readme_path}" ]]; then
    log_error "README.md not found at '${readme_path}'"
    exit 1
  fi

  description=$(awk -v script_heading="^#+ \`*${script_name}.*\`*" '
    BEGIN {found=0}
    $0 ~ script_heading {found=1; next}
    found && !/^[[:space:]]*$/ {
      desc=$0;
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", desc);
      print desc;
      exit
    }
  ' "${readme_path}")

  if [[ -z "${description}" ]]; then
    log_error "Could not find description for '${script_name}' in README.md."
    exit 1
  fi

  # Reset dependency variables
  homebrew_dependencies=""
  deb_dependencies=""

  # This awk script parses the "Dependencies" section of a README.
  # It outputs dependencies in a "TYPE:dependency" format, which is then
  # processed by the shell script.
  local parsed_deps
  parsed_deps=$(awk '
    # Start processing when the "Dependencies" header is found.
    /^#+ Dependencies/ { in_deps = 1; next }
    # Stop processing at the next header.
    in_deps && /^#+/ { in_deps = 0 }
    # Process lines within the "Dependencies" section that start with "*".
    in_deps && /^\*/ {
      line = $0
      # Remove the leading "* " from the line.
      sub(/^\*[[:space:]]*/, "", line)
      
      # Check for macOS-specific dependencies, e.g., "* macOS: package-name"
      if (match(line, /^(macOS):[[:space:]]*(.+)/, arr)) {
        print "BREW:" arr[2]
      }
      # Check for Debian-specific dependencies, e.g., "* Debian/Ubuntu: package-name"
      else if (match(line, /^(Debian\/Ubuntu):[[:space:]]*(.+)/, arr)) {
        print "DEB:" arr[2]
      } 
      # All other dependencies are considered universal.
      else {
        print "BREW:" line
        print "DEB:" line
      }
    }
  ' "${readme_path}")

  # Process the awk output into the final dependency strings.
  while IFS= read -r line; do
    local type="${line%%:*}"
    local dep="${line#*:}"
    
    if [[ "${type}" == "BREW" ]]; then
      # Format for Homebrew: `  depends_on "package"`
      homebrew_dependencies+="  depends_on \"${dep}\"\n"
    elif [[ "${type}" == "DEB" ]]; then
      # Format for Debian: `package1,package2`
      if [[ -n "${deb_dependencies}" ]]; then
        deb_dependencies+=","
      fi
      deb_dependencies+="${dep}"
    fi
  done <<< "${parsed_deps}"
}

#######################################
# Generates the Homebrew formula file.
# Globals:
#   HOMEBREW_FORMULA_DIR, script_name, HOMEPAGE_URL,
#   TARBALL_URL, SHA256_CHECKSUM, homebrew_dependencies, source_script_path,
#   config_file_path
# Arguments:
#   None
#######################################
generate_homebrew_formula() {
  mkdir -p "${HOMEBREW_FORMULA_DIR}"
  local formula_file="${HOMEBREW_FORMULA_DIR}/${script_name}.rb"
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
  homepage "${HOMEPAGE_URL}"
  url "${TARBALL_URL}"
  sha256 "${SHA256_CHECKSUM}"

${homebrew_dependencies}
  def install
    bin.install "${source_script_path}" => "${script_name}"
    $(if [[ -n "${config_file_path}" ]]; then
      echo "etc.install \"${config_file_path}\" => \"${script_name}.conf\""
    fi)
  end
end
EOF
}

#######################################
# Generates the Debian (.deb) package.
# Globals:
#   DEB_PACKAGE_DIR, script_name, VERSION, source_script_path, deb_dependencies,
#   MAINTAINER_INFO, description, config_file_path
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

  local deb_version="${VERSION#v}"
  local package_dir="${DEB_PACKAGE_DIR}/${script_name}-${VERSION}"
  local control_dir="${package_dir}/DEBIAN"
  local bin_dir="${package_dir}/usr/local/bin"
  local etc_dir="${package_dir}/usr/local/etc"
  local deb_file="${DEB_PACKAGE_DIR}/${script_name}_${deb_version}_all.deb"

  mkdir -p "${DEB_PACKAGE_DIR}"
  rm -rf "${package_dir}"
  mkdir -p "${control_dir}" "${bin_dir}"

  cat > "${control_dir}/control" <<EOF
Package: ${script_name}
Version: ${deb_version}
Section: utils
Priority: optional
Architecture: all
Depends: ${deb_dependencies}
Maintainer: ${MAINTAINER_INFO}
Description: ${description}
 This package installs the '${script_name}' script.
EOF

  cp "${source_script_path}" "${bin_dir}/${script_name}"
  chmod +x "${bin_dir}/${script_name}"

  if [[ -n "${config_file_path}" ]]; then
    mkdir -p "${etc_dir}"
    cp "${config_file_path}" "${etc_dir}/${script_name}.conf"
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
  if (( $# != 1 )); then
    log_error "Missing required script path argument."
    show_usage
    exit 1
  fi

  parse_script_info "$1"
  find_config_file
  parse_readme
  generate_homebrew_formula
  generate_deb_package
}

main "$@"


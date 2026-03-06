#!/usr/bin/env bash
#
# Generates Homebrew formulas (.rb), Debian packages (.deb), and release
# tarballs (.tar.gz) for a script registered in scripts.yaml.
#
# Usage:
#   package-script.sh <name> <version>
#
# Positional arguments:
#   name    - Script name as it appears in scripts.yaml (e.g., "local-backup")
#   version - Version string (e.g., "v1.3.0")
#
# Output is written to dist/ relative to the repository root:
#   dist/tarballs/  - .tar.gz release tarballs
#   dist/homebrew/  - .rb Homebrew formula files
#   dist/debian/    - .deb Debian packages

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="${SCRIPT_DIR}/.."
MANIFEST="${REPO_ROOT}/scripts.yaml"
TARBALL_DIR="${REPO_ROOT}/dist/tarballs"
HOMEBREW_DIR="${REPO_ROOT}/dist/homebrew"
DEB_DIR="${REPO_ROOT}/dist/debian"

#######################################
# Prints a timestamped info message to stderr.
# Arguments:
#   Message to print.
#######################################
log_info() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [INFO]: $*" >&2
}

#######################################
# Prints a timestamped error message to stderr.
# Arguments:
#   Message to print.
#######################################
log_error() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [ERROR]: $*" >&2
}

#######################################
# Prints usage instructions to stderr.
# Arguments:
#   None
#######################################
show_usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <name> <version>

Arguments:
  name    - Script name as it appears in scripts.yaml (e.g., "local-backup")
  version - Version string (e.g., "v1.3.0")

Output is written to dist/ relative to the repository root.
EOF
}

#######################################
# Reads a field from the manifest using yq.
# Arguments:
#   yq expression to evaluate.
# Outputs:
#   The field value to stdout.
#######################################
read_manifest() {
  yq eval "$1" "${MANIFEST}"
}

#######################################
# Checks for a config file adjacent to the script.
# Arguments:
#   script_dir - Directory containing the script.
#   name       - Script name (without extension).
# Outputs:
#   Prints the config file path to stdout if found, empty otherwise.
#######################################
find_config_file() {
  local script_dir="$1"
  local name="$2"
  local config_path="${script_dir}/${name}.conf"

  if [[ -f "${config_path}" ]]; then
    echo "${config_path}"
  fi
}

#######################################
# Creates a flat tarball containing the script and optional config file.
# Arguments:
#   name        - Script name.
#   version     - Version string (e.g., "v1.3.0").
#   script_path - Path to the script file.
#   config_path - Path to the config file (empty if none).
# Outputs:
#   Prints the tarball path to stdout.
#######################################
create_tarball() {
  local name="$1"
  local version="$2"
  local script_path="$3"
  local config_path="$4"

  local tarball_name="scripts-${name}-${version}"
  local staging_dir
  staging_dir="$(mktemp -d)"
  local staging_path="${staging_dir}/${tarball_name}"

  mkdir -p "${staging_path}"
  cp "${script_path}" "${staging_path}/"

  if [[ -n "${config_path}" ]]; then
    cp "${config_path}" "${staging_path}/"
  fi

  mkdir -p "${TARBALL_DIR}"
  local tarball_file="${TARBALL_DIR}/${tarball_name}.tar.gz"

  tar -czf "${tarball_file}" -C "${staging_dir}" "${tarball_name}"
  rm -rf "${staging_dir}"

  echo "${tarball_file}"
}

#######################################
# Constructs the GitHub release download URL for a tarball.
# Arguments:
#   homepage - Repository homepage URL.
#   name     - Script name.
#   version  - Version string.
# Outputs:
#   Prints the URL to stdout.
#######################################
build_tarball_url() {
  local homepage="$1"
  local name="$2"
  local version="$3"

  echo "${homepage}/releases/download/${name}-${version}/scripts-${name}-${version}.tar.gz"
}

#######################################
# Generates a Homebrew formula file.
# Arguments:
#   name         - Script name.
#   version      - Version string (e.g., "v1.3.0").
#   description  - Script description.
#   homepage     - Homepage URL.
#   tarball_url  - Download URL for the tarball.
#   sha256       - SHA256 checksum of the tarball.
#   script_path  - Path to the script file.
#   config_path  - Path to the config file (empty if none).
#   deps_common  - Space-separated common dependencies.
#   deps_homebrew - Space-separated Homebrew-only dependencies.
#######################################
generate_homebrew_formula() {
  local name="$1"
  local version="$2"
  local description="$3"
  local homepage="$4"
  local tarball_url="$5"
  local sha256="$6"
  local script_path="$7"
  local config_path="$8"
  local deps_common="$9"
  local deps_homebrew="${10}"
  local license="${11}"

  # Strip v prefix for the version field
  local clean_version="${version#v}"

  # Escape double quotes in description
  local escaped_desc="${description//\"/\\\"}"

  # Convert script-name to ClassName
  local class_name
  class_name=$(echo "${name}" | awk -F'[-_]' '{
    for (i=1; i<=NF; i++) {
      printf "%s", toupper(substr($i,1,1)) substr($i,2)
    }
    print ""
  }')

  mkdir -p "${HOMEBREW_DIR}"
  local formula_file="${HOMEBREW_DIR}/${name}.rb"

  local script_filename
  script_filename=$(basename "${script_path}")
  local install_lines="    bin.install \"${script_filename}\" => \"${name}\""
  if [[ -n "${config_path}" ]]; then
    local config_filename
    config_filename=$(basename "${config_path}")
    install_lines+=$'\n'"    etc.install \"${config_filename}\" => \"${config_filename}\""
  fi

  # Build depends_on lines
  local depends_lines=""
  for dep in ${deps_common}; do
    depends_lines+="  depends_on \"${dep}\""$'\n'
  done
  for dep in ${deps_homebrew}; do
    depends_lines+="  depends_on \"${dep}\""$'\n'
  done

  log_info "Creating Homebrew formula: ${formula_file}"

  cat > "${formula_file}" <<EOF
# This file was generated by the package-script.sh script.
class ${class_name} < Formula
  desc "${escaped_desc}"
  homepage "${homepage}"
  url "${tarball_url}"
  sha256 "${sha256}"
  version "${clean_version}"
  license "${license}"
${depends_lines}  def install
${install_lines}
  end

  test do
    assert_predicate bin/"${name}", :executable?
  end
end
EOF
}

#######################################
# Generates a Debian (.deb) package.
# Arguments:
#   name         - Script name.
#   version      - Version string (e.g., "v1.3.0").
#   description  - Script description.
#   author       - Maintainer string.
#   homepage     - Homepage URL.
#   license      - License string.
#   script_path  - Path to the script file.
#   config_path  - Path to the config file (empty if none).
#   deps_common  - Space-separated common dependencies.
#   deps_debian  - Space-separated Debian-only dependencies.
#######################################
generate_deb_package() {
  local name="$1"
  local version="$2"
  local description="$3"
  local author="$4"
  local homepage="$5"
  local license="$6"
  local script_path="$7"
  local config_path="$8"
  local deps_common="$9"
  local deps_debian="${10}"

  if ! command -v dpkg-deb &> /dev/null; then
    log_info "'dpkg-deb' not found. Skipping .deb package generation."
    return 0
  fi

  log_info "Generating Debian package for ${name}..."

  local deb_version="${version#v}"

  # Build dependency string
  local deb_dependencies=""
  for dep in ${deps_common}; do
    if [[ -n "${deb_dependencies}" ]]; then deb_dependencies+=", "; fi
    deb_dependencies+="${dep}"
  done
  for dep in ${deps_debian}; do
    if [[ -n "${deb_dependencies}" ]]; then deb_dependencies+=", "; fi
    deb_dependencies+="${dep}"
  done

  local package_dir="${DEB_DIR}/${name}-${version}"
  local control_dir="${package_dir}/DEBIAN"
  local bin_dir="${package_dir}/usr/local/bin"
  local etc_dir="${package_dir}/usr/local/etc"
  local deb_file="${DEB_DIR}/${name}_${deb_version}_all.deb"

  mkdir -p "${DEB_DIR}"
  rm -rf "${package_dir}"
  mkdir -p "${control_dir}" "${bin_dir}"

  # Build control file
  {
    echo "Package: ${name}"
    echo "Version: ${deb_version}"
    echo "Architecture: all"
    if [[ -n "${deb_dependencies}" ]]; then
      echo "Depends: ${deb_dependencies}"
    fi
    echo "Maintainer: ${author}"
    echo "Homepage: ${homepage}"
    echo "License: ${license}"
    echo "Description: ${description}"
    echo " This package installs the '${name}' script."
  } > "${control_dir}/control"

  # Add conffiles entry if config file is present
  if [[ -n "${config_path}" ]]; then
    local config_filename
    config_filename=$(basename "${config_path}")
    echo "/usr/local/etc/${config_filename}" > "${control_dir}/conffiles"
  fi

  cp "${script_path}" "${bin_dir}/${name}"
  chmod +x "${bin_dir}/${name}"

  if [[ -n "${config_path}" ]]; then
    local config_filename
    config_filename=$(basename "${config_path}")
    mkdir -p "${etc_dir}"
    cp "${config_path}" "${etc_dir}/${config_filename}"
  fi

  log_info "Building .deb package..."
  dpkg-deb --build "${package_dir}" "${deb_file}"
  rm -rf "${package_dir}"

  if [[ -f "${deb_file}" ]]; then
    log_info "Debian package created: ${deb_file}"
  else
    log_error "Failed to create Debian package."
    return 1
  fi
}

main() {
  if (( $# != 2 )); then
    log_error "Expected exactly 2 arguments: <name> <version>"
    show_usage
    exit 1
  fi

  local name="$1"
  local version="$2"

  if [[ ! -f "${MANIFEST}" ]]; then
    log_error "Manifest not found: ${MANIFEST}"
    exit 1
  fi

  if ! command -v yq &> /dev/null; then
    log_error "'yq' is required but not found in PATH."
    exit 1
  fi

  # Read manifest fields
  local script_path
  script_path=$(read_manifest ".scripts.\"${name}\".path")
  if [[ "${script_path}" == "null" || -z "${script_path}" ]]; then
    log_error "Script '${name}' not found in manifest."
    exit 1
  fi

  # Resolve script path relative to repo root
  local full_script_path="${REPO_ROOT}/${script_path}"
  if [[ ! -f "${full_script_path}" ]]; then
    log_error "Script file not found: ${full_script_path}"
    exit 1
  fi

  local description
  description=$(read_manifest ".scripts.\"${name}\".description")

  local homepage
  homepage=$(read_manifest ".defaults.homepage")

  local author
  author=$(read_manifest ".defaults.author")

  local license
  license=$(read_manifest ".defaults.license")

  # Read dependencies as space-separated strings
  local deps_common
  deps_common=$(read_manifest "(.scripts.\"${name}\".dependencies.common // []) | join(\" \")")

  local deps_homebrew
  deps_homebrew=$(read_manifest "(.scripts.\"${name}\".dependencies.homebrew // []) | join(\" \")")

  local deps_debian
  deps_debian=$(read_manifest "(.scripts.\"${name}\".dependencies.debian // []) | join(\" \")")

  # Find config file by convention
  local script_dir
  script_dir=$(dirname "${full_script_path}")
  local config_path
  config_path=$(find_config_file "${script_dir}" "${name}")

  if [[ -n "${config_path}" ]]; then
    log_info "Found config file: ${config_path}"
  fi

  log_info "Packaging ${name} ${version}..."

  # Create tarball
  local tarball_path
  tarball_path=$(create_tarball "${name}" "${version}" "${full_script_path}" "${config_path}")
  log_info "Tarball created: ${tarball_path}"

  # Compute SHA256
  local sha256
  if command -v sha256sum &> /dev/null; then
    sha256=$(sha256sum "${tarball_path}" | awk '{print $1}')
  else
    sha256=$(shasum -a 256 "${tarball_path}" | awk '{print $1}')
  fi
  log_info "SHA256: ${sha256}"

  # Build tarball URL
  local tarball_url
  tarball_url=$(build_tarball_url "${homepage}" "${name}" "${version}")

  # Generate Homebrew formula
  generate_homebrew_formula \
    "${name}" "${version}" "${description}" "${homepage}" \
    "${tarball_url}" "${sha256}" "${full_script_path}" "${config_path}" \
    "${deps_common}" "${deps_homebrew}" "${license}"

  # Generate Debian package
  generate_deb_package \
    "${name}" "${version}" "${description}" "${author}" "${homepage}" \
    "${license}" "${full_script_path}" "${config_path}" \
    "${deps_common}" "${deps_debian}"

  log_info "Done packaging ${name} ${version}."
}

main "$@"

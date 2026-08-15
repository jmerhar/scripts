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
COMPILED_DIR="${REPO_ROOT}/dist/compiled"
COMPILER="${SCRIPT_DIR}/compile-includes.sh"

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
# Writes a script with a bash-version guard inserted directly after its shebang.
#
# A function rather than a brace group with a redirect, because bash never reports the closing brace of a
# redirected group as executed, so the whole block reads as uncovered however often it runs.
# Arguments:
#   script_path - Path to the source script.
#   min_bash    - The declared minimum version, for the message.
#   major       - Its major component.
#   minor       - Its minor component.
# Outputs:
#   The guarded script on stdout.
#######################################
emit_guarded_script() {
  local script_path="$1" min_bash="$2" major="$3" minor="$4"
  head -n 1 "${script_path}"
  cat <<GUARD

# Requires bash ${min_bash}: this script uses features that earlier releases lack. Deliberately
# written in bash 3.x syntax, so that it still runs — and explains itself — on a version it rejects.
if (( BASH_VERSINFO[0] < ${major} || (BASH_VERSINFO[0] == ${major} && BASH_VERSINFO[1] < ${minor}) )); then
  echo "Error: \$(basename "\$0") requires bash ${min_bash} or newer (running \${BASH_VERSION})." >&2
  exit 1
fi

GUARD
  tail -n +2 "${script_path}"
}

#######################################
# Compiles one script into dist/compiled/ and prints the path of the result.
#
# Always recompiles rather than reusing what is there: the transform is a cheap text pass, and the
# alternatives are a freshness rule that would have to know the script depends on the library and on every
# program it embeds, or an artefact quietly built from a stale copy.
# Globals:
#   COMPILED_DIR, COMPILER
# Arguments:
#   source_script: Path of the development form of the script.
# Outputs:
#   Prints the path of the compiled script.
# Returns:
#   1 when compilation fails.
#######################################
compile_for_packaging() {
  local source_script="$1"
  local out
  out="${COMPILED_DIR}/$(basename "${source_script}")"

  mkdir -p "${COMPILED_DIR}"
  if ! "${COMPILER}" "${source_script}" "${out}"; then
    log_error "Failed to compile ${source_script}."
    return 1
  fi
  printf '%s' "${out}"
}

#######################################
# Writes the published form of a script — the compiled source, preceded by a bash-version guard when the
# manifest declares one — and prints its path.
#
# The guard is generated here rather than kept in the source so that the required version is stated
# once, in scripts.yaml, alongside the dependency metadata derived from it; the two cannot then
# disagree. It sits immediately after the shebang, ahead of anything that a older bash would choke
# on, and is written in bash 3.x syntax so that it is reachable on the very versions it rejects.
#
# The result is used for every channel, so the tarball, the .deb and the Homebrew bottle all carry
# byte-identical content.
# Arguments:
#   script_path - Path to the development form of the script.
#   min_bash    - Required version as major.minor, or empty for no requirement.
# Outputs:
#   Prints the path of the prepared script, which keeps the original basename.
# Returns:
#   1 if the script does not begin with a shebang.
#######################################
prepare_script() {
  local script_path="$1"
  local min_bash="$2"

  local prepared_dir
  prepared_dir="$(mktemp -d)"
  local script_filename
  script_filename="$(basename "${script_path}")"
  # Keeping the original basename matters: it becomes the name inside the tarball and the one the
  # formula's bin.install refers to.
  local prepared="${prepared_dir}/${script_filename}"

  if [[ -z "${min_bash}" ]]; then
    cat "${script_path}" > "${prepared}"
    echo "${prepared}"
    return
  fi

  if [[ "$(head -n 1 "${script_path}")" != '#!'* ]]; then
    log_error "Cannot add a bash-version guard: ${script_path} does not start with a shebang."
    return 1
  fi

  local major="${min_bash%%.*}"
  local minor="${min_bash#*.}"
  if [[ "${minor}" == "${min_bash}" ]]; then
    minor=0
  fi

  emit_guarded_script "${script_path}" "${min_bash}" "${major}" "${minor}" > "${prepared}"

  echo "${prepared}"
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
  chmod 0755 "${staging_path}/$(basename "${script_path}")"

  if [[ -n "${config_path}" ]]; then
    cp "${config_path}" "${staging_path}/"
    chmod 0644 "${staging_path}/$(basename "${config_path}")"
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
# Outputs:
#   Writes formula file to HOMEBREW_DIR.
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
  local min_bash="${12}"

  # Strip v prefix for the version field
  local clean_version="${version#v}"

  # Escape double quotes in description
  local escaped_desc="${description//\"/\\\"}"

  # Convert script-name to ClassName
  local class_name
  class_name=$(echo "${name}" | awk -F'[-_]' -f "${SCRIPT_DIR}/class-name.awk")

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

  # Point the shebang at the dependency rather than leaving `env bash` to search PATH. macOS ships
  # bash 3.2 as /bin/bash, and a launchd or cron invocation has no Homebrew directory on its PATH, so
  # `env bash` there finds the version this script cannot run on.
  if [[ -n "${min_bash}" ]]; then
    install_lines+=$'\n'"    inreplace bin/\"${name}\", %r{^#!/usr/bin/env bash\$}, \"#!#{Formula[\"bash\"].opt_bin}/bash\""
  fi

  # Build depends_on lines. Homebrew has no version constraints and no versioned bash formula, so the
  # requirement is expressed as a plain dependency; the guard compiled into the script is what
  # actually asserts the version.
  local depends_lines=""
  if [[ -n "${min_bash}" ]]; then
    depends_lines+="  depends_on \"bash\""$'\n'
  fi
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
# Writes a Debian control file to stdout.
#
# A function rather than a brace group with a redirect, for the same reason as emit_guarded_script: bash
# never reports the closing brace of a redirected group, so the whole block reads as uncovered.
# Arguments:
#   name         - Package name.
#   deb_version  - Version without a leading "v".
#   dependencies - Comma-separated Depends value, or empty to omit the field.
#   author       - Maintainer.
#   homepage     - Homepage URL.
#   license      - Licence name.
#   description  - One-line description.
# Outputs:
#   The control file contents on stdout.
#######################################
emit_deb_control() {
  local name="$1" deb_version="$2" dependencies="$3" author="$4" homepage="$5" license="$6" description="$7"
  echo "Package: ${name}"
  echo "Version: ${deb_version}"
  echo "Architecture: all"
  # Omitted rather than left empty: an empty Depends is a Lintian error, and a package with no
  # dependencies simply has no such field.
  if [[ -n "${dependencies}" ]]; then
    echo "Depends: ${dependencies}"
  fi
  echo "Maintainer: ${author}"
  echo "Homepage: ${homepage}"
  echo "License: ${license}"
  echo "Description: ${description}"
  echo " This package installs the '${name}' script."
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
# Returns:
#   0 on success, 1 on failure.
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
  local min_bash="${11}"

  if ! command -v dpkg-deb &> /dev/null; then
    log_info "'dpkg-deb' not found. Skipping .deb package generation."
    return 0
  fi

  log_info "Generating Debian package for ${name}..."

  local deb_version="${version#v}"

  # Build dependency string. bash is Essential, so Debian Policy wants it named only when a specific
  # version is needed — which is exactly this case, and a versioned dependency is the form apt can
  # enforce. A bare `Depends: bash` would instead be a Lintian warning.
  local deb_dependencies=""
  if [[ -n "${min_bash}" ]]; then
    deb_dependencies="bash (>= ${min_bash})"
  fi
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

  local -a control_args=("${name}" "${deb_version}" "${deb_dependencies}" "${author}")
  control_args+=("${homepage}" "${license}" "${description}")
  emit_deb_control "${control_args[@]}" > "${control_dir}/control"

  # Add conffiles entry if config file is present
  if [[ -n "${config_path}" ]]; then
    local config_filename
    config_filename=$(basename "${config_path}")
    echo "/usr/local/etc/${config_filename}" > "${control_dir}/conffiles"
  fi

  cp "${script_path}" "${bin_dir}/${name}"
  # Set an explicit mode: the source may be 0600 (e.g. a freshly compiled
  # @include file), and `chmod +x` on that would yield 0711 — leaving the
  # script non-readable, so its interpreter cannot execute it after install.
  chmod 0755 "${bin_dir}/${name}"

  if [[ -n "${config_path}" ]]; then
    local config_filename
    config_filename=$(basename "${config_path}")
    mkdir -p "${etc_dir}"
    cp "${config_path}" "${etc_dir}/${config_filename}"
    chmod 0644 "${etc_dir}/${config_filename}"
  fi

  log_info "Building .deb package..."
  # --root-owner-group forces files to be owned by root:root in the package;
  # without it dpkg-deb bakes in the build user's uid/gid (e.g. the CI runner's),
  # which surfaces as a stray owner like "git" on the installed system.
  dpkg-deb --root-owner-group --build "${package_dir}" "${deb_file}"
  rm -rf "${package_dir}"

  if [[ -f "${deb_file}" ]]; then
    log_info "Debian package created: ${deb_file}"
  else
    log_error "Failed to create Debian package."
    return 1
  fi
}

#######################################
# Packages a script registered in scripts.yaml into a tarball, Homebrew
# formula, and Debian package.
# Arguments:
#   name    - Script name as it appears in scripts.yaml.
#   version - Version string (e.g., "v1.3.0").
#######################################
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
  local source_script_path="${REPO_ROOT}/${script_path}"
  if [[ ! -f "${source_script_path}" ]]; then
    log_error "Script file not found: ${source_script_path}"
    exit 1
  fi

  # What gets packaged is the compiled form — the single file carrying the library and any awk or jq
  # programs inline, since none of those is shipped beside it. Compiled here rather than assumed to exist:
  # an artefact built from the development form installs and then fails on its first missing include.
  local full_script_path
  full_script_path=$(compile_for_packaging "${source_script_path}")

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

  # Target platforms (default: both). Lets a platform-specific script — e.g. a
  # systemd/sudoers tool that only makes sense on Linux — opt out of one channel.
  local platforms
  platforms=$(read_manifest "(.scripts.\"${name}\".platforms // [\"homebrew\", \"debian\"]) | join(\" \")")

  # Minimum bash version, for scripts using features that older releases lack. Drives three things:
  # the guard compiled into the published script, the versioned Debian dependency, and the Homebrew
  # dependency plus shebang rewrite.
  local min_bash
  min_bash=$(read_manifest "(.scripts.\"${name}\".min_bash // \"\")")

  # Find config file by convention, beside the script in the source tree — dist/compiled holds scripts
  # only.
  local script_dir
  script_dir=$(dirname "${source_script_path}")
  local config_path
  config_path=$(find_config_file "${script_dir}" "${name}")

  if [[ -n "${config_path}" ]]; then
    log_info "Found config file: ${config_path}"
  fi

  log_info "Packaging ${name} ${version}..."

  # Every channel ships this one prepared copy, so their contents cannot diverge.
  local published_script
  published_script=$(prepare_script "${full_script_path}" "${min_bash}")
  local prepared_dir
  prepared_dir=$(dirname "${published_script}")
  # shellcheck disable=SC2064  # expand prepared_dir now; it must not depend on later state
  trap "rm -rf '${prepared_dir}'" EXIT
  if [[ -n "${min_bash}" ]]; then
    log_info "Requires bash ${min_bash}; compiling a version guard into the published script."
  fi

  # Create tarball
  local tarball_path
  tarball_path=$(create_tarball "${name}" "${version}" "${published_script}" "${config_path}")
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
  if [[ " ${platforms} " == *" homebrew "* ]]; then
    local -a formula_args=("${name}" "${version}" "${description}" "${homepage}")
    formula_args+=("${tarball_url}" "${sha256}" "${published_script}" "${config_path}")
    formula_args+=("${deps_common}" "${deps_homebrew}" "${license}" "${min_bash}")
    generate_homebrew_formula "${formula_args[@]}"
  else
    log_info "Skipping Homebrew formula (platforms: ${platforms})."
  fi

  # Generate Debian package
  if [[ " ${platforms} " == *" debian "* ]]; then
    local -a deb_args=("${name}" "${version}" "${description}" "${author}" "${homepage}")
    deb_args+=("${license}" "${published_script}" "${config_path}")
    deb_args+=("${deps_common}" "${deps_debian}" "${min_bash}")
    generate_deb_package "${deb_args[@]}"
  else
    log_info "Skipping Debian package (platforms: ${platforms})."
  fi

  log_info "Done packaging ${name} ${version}."
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

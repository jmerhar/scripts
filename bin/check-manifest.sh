#!/usr/bin/env bash
#
# Validates scripts.yaml against the working tree: every registered script must exist, be executable,
# start with a shebang and have a README beside it; the shared library must not be executable; and
# scripts under scripts/ that nobody registered are reported.
#
# These are the properties that only break at a distance. A non-executable script still packages
# correctly, because package-script.sh chmods 0755 into every artefact, so the only person affected is
# whoever runs it from a checkout. A missing shebang is not noticed until a release, where the packager
# refuses to compile the bash-version guard. A script with no README beside it is linked from the
# generated indexes to a directory that renders nothing. And an unregistered script is simply never
# published.
#
# Usage:
#   ./check-manifest.sh
#
# Exits non-zero if any registered script is missing, non-executable, undocumented or lacking a
# shebang. An unregistered script is a warning: a work in progress under scripts/ is legitimate, and so
# is the harness that run-coverage.sh puts there for the duration of a run.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="${SCRIPT_DIR}/.."
MANIFEST="${REPO_ROOT}/scripts.yaml"
LIB_DIR="${REPO_ROOT}/scripts/lib"

#######################################
# Prints a timestamped error message to stderr, and as a GitHub Actions annotation under CI.
# Arguments:
#   Message to print.
#######################################
log_error() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::$*"
  fi
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [ERROR]: $*" >&2
}

#######################################
# Prints a timestamped warning to stderr, and as a GitHub Actions annotation under CI.
# Arguments:
#   Message to print.
#######################################
log_warning() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::$*"
  fi
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [WARNING]: $*" >&2
}

#######################################
# Prints a timestamped info message to stderr.
# Arguments:
#   Message to print.
#######################################
log_info() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [INFO]: $*" >&2
}

#######################################
# Prints usage instructions to stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: $(basename "$0")

Checks scripts.yaml against the working tree: registered scripts exist, are executable, have a
shebang and a README; the shared library is not executable; unregistered scripts are reported.

Options:
  -h    Show this help message.
EOF
}

#######################################
# Prints a file's mode as octal digits, preferring what git records over what the filesystem reports.
#
# The mode in the index is the one that matters: it is what a fresh clone gets, and it is unaffected by
# the checkout's umask, by an archive extraction, or by a bind mount. The filesystem is consulted only
# for untracked files, and read with stat rather than tested with -x, because as root -x reports a mode
# 0644 file as executable — so a check built on it would pass in a container no matter what the mode is.
# Globals:
#   REPO_ROOT
# Arguments:
#   path: File to inspect.
# Outputs:
#   Prints the mode, e.g. 755 or 644.
#######################################
file_mode() {
  local path="$1"
  local git_mode=""

  if command -v git &>/dev/null; then
    git_mode=$(git -C "${REPO_ROOT}" ls-files -s -- "${path}" 2>/dev/null | awk 'NR==1 {print $1}')
  fi

  if [[ -n "${git_mode}" ]]; then
    # git records 100644 or 100755; the trailing three digits are the mode.
    printf '%s' "${git_mode: -3}"
    return
  fi

  stat -c '%a' "${path}" 2>/dev/null || stat -f '%Lp' "${path}"
}

#######################################
# Reports whether a mode has any execute bit set.
# Arguments:
#   mode: Octal mode digits, as file_mode prints them.
# Returns:
#   0 when the file is executable by someone, 1 otherwise.
#######################################
mode_is_executable() {
  local mode="$1"
  # Pad to three digits so the arithmetic below indexes the right positions.
  while (( ${#mode} < 3 )); do mode="0${mode}"; done
  (( (${mode: -3:1} & 1) || (${mode: -2:1} & 1) || (${mode: -1:1} & 1) ))
}

#######################################
# Checks one registered script.
# Globals:
#   MANIFEST, REPO_ROOT
# Arguments:
#   name: Script name as it appears in the manifest.
# Returns:
#   0 when the entry is sound, 1 otherwise.
#######################################
check_entry() {
  local name="$1"

  local path
  path=$(yq eval ".scripts.\"${name}\".path" "${MANIFEST}")
  if [[ "${path}" == "null" || -z "${path}" ]]; then
    log_error "Manifest entry '${name}' has no path."
    return 1
  fi

  local file="${REPO_ROOT}/${path}"
  if [[ ! -f "${file}" ]]; then
    log_error "Manifest entry '${name}' points to missing file: ${path}"
    return 1
  fi

  local failed=0

  # Published artefacts are chmodded to 0755 regardless, so this protects the checkout rather than the
  # release: without it, `./${path}` fails with permission denied.
  if ! mode_is_executable "$(file_mode "${file}")"; then
    log_error "${path} is not executable (chmod +x it; every published script must run from a checkout)."
    failed=1
  fi

  if [[ "$(head -n 1 "${file}")" != '#!'* ]]; then
    log_error "${path} does not start with a shebang, so the packager cannot add its version guard."
    failed=1
  fi

  # The generated indexes link each script to its directory, and GitHub renders a directory by showing
  # its README. A directory without one is a link that resolves and displays nothing, which is the one
  # broken-documentation case generating the tables from this manifest cannot rule out.
  if [[ ! -f "$(dirname "${file}")/README.md" ]]; then
    log_error "$(dirname "${path}")/README.md is missing, so the index links to a directory that renders no documentation."
    failed=1
  fi

  return "${failed}"
}

#######################################
# Checks that the shared library is not marked executable.
# It is sourced, never run, and an exec bit on it would invite exactly that.
# Globals:
#   LIB_DIR
# Returns:
#   0 when every library file is non-executable, 1 otherwise.
#######################################
check_library() {
  local failed=0
  local file
  for file in "${LIB_DIR}"/*.sh; do
    [[ -e "${file}" ]] || continue
    if mode_is_executable "$(file_mode "${file}")"; then
      log_error "scripts/lib/$(basename "${file}") is executable, but the library is sourced, not run."
      failed=1
    fi
  done
  return "${failed}"
}

#######################################
# Reports scripts under scripts/ that the manifest does not register.
# Globals:
#   MANIFEST, REPO_ROOT
# Outputs:
#   A warning per unregistered script.
#######################################
warn_unregistered() {
  local script name
  while IFS= read -r -d '' script; do
    name=$(basename "${script}")
    name="${name%.*}"
    if [[ "$(yq eval ".scripts.\"${name}\".path" "${MANIFEST}")" == "null" ]]; then
      log_warning "${script#"${REPO_ROOT}/"} is not registered in scripts.yaml"
    fi
  done < <(find "${REPO_ROOT}/scripts" -mindepth 2 -type f -name '*.sh' -not -path '*/lib/*' -print0)
}

#######################################
# Validates the whole manifest.
# Globals:
#   MANIFEST
#######################################
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
  fi

  if [[ ! -f "${MANIFEST}" ]]; then
    log_error "Manifest not found: ${MANIFEST}"
    exit 1
  fi

  if ! command -v yq &> /dev/null; then
    log_error "'yq' is required but not found in PATH."
    exit 1
  fi

  local failures=0
  local count=0
  local name
  while IFS= read -r name; do
    count=$(( count + 1 ))
    check_entry "${name}" || failures=$(( failures + 1 ))
  done < <(yq eval '.scripts | keys | .[]' "${MANIFEST}")

  check_library || failures=$(( failures + 1 ))
  warn_unregistered

  if (( failures > 0 )); then
    log_error "${failures} manifest problem(s) found."
    exit 1
  fi

  log_info "All ${count} registered script(s) exist, are executable, have a shebang and are documented."
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

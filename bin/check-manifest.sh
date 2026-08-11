#!/usr/bin/env bash
#
# Validates scripts.yaml against the working tree: every registered script must exist, be executable,
# and start with a shebang; the shared library must not be executable; and scripts under scripts/ that
# nobody registered are reported.
#
# These are the properties that only break at a distance. A non-executable script still packages
# correctly, because package-script.sh chmods 0755 into every artefact, so the only person affected is
# whoever runs it from a checkout. A missing shebang is not noticed until a release, where the packager
# refuses to compile the bash-version guard. And an unregistered script is simply never published.
#
# Usage:
#   ./check-manifest.sh
#
# Exits non-zero if any registered script is missing, non-executable or lacks a shebang. An
# unregistered script is a warning: a work in progress under scripts/ is legitimate, and so is the
# harness that run-coverage.sh puts there for the duration of a run.

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

Checks scripts.yaml against the working tree: registered scripts exist, are executable and have a
shebang; the shared library is not executable; unregistered scripts under scripts/ are reported.

Options:
  -h    Show this help message.
EOF
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
  if [[ ! -x "${file}" ]]; then
    log_error "${path} is not executable (chmod +x it; every published script must run from a checkout)."
    failed=1
  fi

  if [[ "$(head -n 1 "${file}")" != '#!'* ]]; then
    log_error "${path} does not start with a shebang, so the packager cannot add its version guard."
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
    if [[ -x "${file}" ]]; then
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

  log_info "All ${count} registered script(s) exist, are executable and have a shebang."
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
#
# Verifies that every script's `min_bash` in scripts.yaml is high enough for the bash features the
# script actually uses.
#
# The manifest value is what package-script.sh turns into the guard compiled into the published
# script, the versioned Debian dependency and the Homebrew one. Declared by hand, it would drift the
# first time someone reached for a newer construct, and the result would be a package that installs
# on a bash too old to run it. This derives the requirement from the source instead and fails when
# the two disagree.
#
# Detection is by construct, not by parsing: each pattern below is a feature bash gained in a known
# release. It is deliberately conservative — a missed construct means an under-declared minimum, so
# new patterns should be added here as they are adopted.
#
# Usage:
#   ./check-bash-version.sh [script...]
#
# With no arguments, checks every script registered in scripts.yaml. Exits non-zero if any script
# needs a higher version than it declares.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"


#######################################
# Prints usage instructions to stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: $(basename "$0") [script...]

Checks that each script's min_bash in scripts.yaml covers the bash features it uses.
With no arguments, checks every script in the manifest.

Options:
  -h    Show this help message.
EOF
}

#######################################
# Reports whether a file matches any of the given extended regular expressions.
# Arguments:
#   file - Path to search.
#   Remaining arguments are the patterns.
# Returns:
#   0 if any pattern matches, 1 if none do.
#######################################
matches_any() {
  local file="$1"
  shift
  local pattern
  for pattern in "$@"; do
    if grep -qE "${pattern}" "${file}"; then
      return 0
    fi
  done
  return 1
}

#######################################
# Reports the highest bash version a file's constructs require.
# Globals:
#   None
# Arguments:
#   file: Path to the shell script to inspect.
# Outputs:
#   Prints the required version as major.minor, or nothing when only baseline features are used.
#######################################
required_version() {
  local file="$1"
  local required=""

  # 4.3 — namerefs.
  if grep -qE '(^|[^[:alnum:]_])(local|declare|typeset)[[:space:]]+(-[a-zA-Z]*n[a-zA-Z]*)[[:space:]]' "${file}"; then
    required="4.3"
  fi

  if [[ -z "${required}" ]]; then
    # 4.0 — case-conversion expansions, associative arrays, mapfile/readarray.
    # Each pattern is one 4.0 feature: case-conversion expansion, an associative-array declaration, and
    # mapfile/readarray. Held in an array so the list can grow without the matcher changing shape.
    local -a patterns_40=()
    patterns_40+=('\$\{[a-zA-Z_][a-zA-Z0-9_]*(\[[^]]*\])?(,,|\^\^|,|\^)\}')
    patterns_40+=('(^|[^[:alnum:]_])(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A[a-zA-Z]*[[:space:]]')
    patterns_40+=('(^|[^[:alnum:]_])(mapfile|readarray)[[:space:]]')
    if matches_any "${file}" "${patterns_40[@]}"; then
      required="4.0"
    fi
  fi

  printf '%s' "${required}"
}

#######################################
# Compares two major.minor versions.
# Arguments:
#   left: A version string, possibly empty (treated as 0).
#   right: A version string, possibly empty (treated as 0).
# Returns:
#   0 if left is greater than right, 1 otherwise.
#######################################
version_gt() {
  local left="${1:-0}" right="${2:-0}"
  local left_major="${left%%.*}" right_major="${right%%.*}"
  local left_minor="${left#*.}" right_minor="${right#*.}"
  [[ "${left_minor}" == "${left}" ]] && left_minor=0
  [[ "${right_minor}" == "${right}" ]] && right_minor=0

  (( left_major > right_major )) && return 0
  (( left_major < right_major )) && return 1
  (( left_minor > right_minor ))
}

#######################################
# Checks one manifest entry, reporting any shortfall.
# Globals:
#   MANIFEST, REPO_ROOT
# Arguments:
#   name: Script name as it appears in the manifest.
# Outputs:
#   Writes a description of the problem to stderr when the declaration is too low.
# Returns:
#   0 when the declaration covers the script, 1 otherwise.
#######################################
check_script() {
  local name="$1"

  local path
  path=$(yq eval ".scripts.\"${name}\".path" "${MANIFEST}")
  if [[ "${path}" == "null" || -z "${path}" ]]; then
    log_error "Script '${name}' is not in the manifest."
    return 1
  fi

  local file="${REPO_ROOT}/${path}"
  if [[ ! -f "${file}" ]]; then
    log_error "Script file not found: ${file}"
    return 1
  fi

  local declared
  declared=$(yq eval "(.scripts.\"${name}\".min_bash // \"\")" "${MANIFEST}")

  local required
  required=$(required_version "${file}")

  if version_gt "${required}" "${declared}"; then
    if [[ -z "${declared}" ]]; then
      log_error "${name}: uses bash ${required} features but declares no min_bash."
    else
      log_error "${name}: uses bash ${required} features but declares min_bash ${declared}."
    fi
    return 1
  fi

  return 0
}

#######################################
# Checks every named script, or the whole manifest when none are named.
# Globals:
#   MANIFEST
# Arguments:
#   Script names to check; empty to check them all.
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

  local -a names=()
  if (( $# > 0 )); then
    names=("$@")
  else
    while IFS= read -r name; do
      names+=("${name}")
    done < <(yq eval '.scripts | keys | .[]' "${MANIFEST}")
  fi

  local failures=0
  local name
  for name in "${names[@]}"; do
    check_script "${name}" || failures=$(( failures + 1 ))
  done

  if (( failures > 0 )); then
    log_error "${failures} script(s) declare a bash version below what they use."
    exit 1
  fi

  log_info "All ${#names[@]} script(s) declare a bash version that covers their features."
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

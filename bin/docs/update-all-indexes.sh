#!/usr/bin/env bash
#
# Regenerates every README index section in this repository from scripts.yaml.
#
# There are two kinds of index: the root README lists all scripts and links each to its directory, and
# each scripts/<topic>/README.md lists only its own scripts, linking to them as siblings. Both are
# produced by bin/docs/update-readme-index.sh; this script is what knows which files exist and what options
# each one takes.
#
# The topic list is derived from the manifest rather than written here, so adding a script under a new
# topic cannot leave that topic without an index: the topic appears immediately, and a missing
# README.md for it fails the run.
#
# Usage:
#   update-all-indexes.sh [--check]
#
# Options:
#   --check   Do not write; exit non-zero if any index is out of date.
#
# Every index is processed even after one fails, because the useful output of a --check run is the
# full list of stale files rather than the first one.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
GENERATOR="${SCRIPT_DIR}/update-readme-index.sh"

# Shared by every index: the platform annotation and alphabetical order, which is what a
# reader scans. The downstream repos' indexes take the generator's defaults instead.
readonly COMMON_OPTS=(--platform-note --sort)

#######################################
# Lists the topics that have at least one registered script.
# Globals:
#   MANIFEST
# Outputs:
#   One topic name per line, sorted and unique.
#######################################
list_topics() {
  # The topic is the directory component under scripts/, read from the same `path:` the generator
  # builds its links from, so an index and its links cannot describe different places.
  yq eval '.scripts[].path' "${MANIFEST}" | sed -n 's|^scripts/\([^/]*\)/.*|\1|p' | sort -u
}

#######################################
# Prints usage instructions to stderr.
# Arguments:
#   None
#######################################
show_usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--check]

Options:
  --check   Do not write; exit non-zero if any index is out of date.
EOF
}

#######################################
# Regenerates or checks all index sections.
# Globals:
#   REPO_ROOT, SCRIPTS_DIR, GENERATOR, COMMON_OPTS
# Arguments:
#   check_flag: --check, or empty to write.
# Returns:
#   0 if every index is up to date (or was written), 1 otherwise.
#######################################
update_all() {
  local check_flag="$1"
  local -a extra=()
  [[ -n "${check_flag}" ]] && extra=("${check_flag}")

  local failed=0 topic readme

  if ! "${GENERATOR}" "${REPO_ROOT}/README.md" "${COMMON_OPTS[@]}" --link repo "${extra[@]}"; then
    failed=1
  fi

  while IFS= read -r topic; do
    readme="${SCRIPTS_DIR}/${topic}/README.md"
    if [[ ! -f "${readme}" ]]; then
      log_error "No index for topic '${topic}': ${readme} does not exist."
      failed=1
      continue
    fi
    if ! "${GENERATOR}" "${readme}" "${COMMON_OPTS[@]}" --topic "${topic}" --link sibling "${extra[@]}"; then
      failed=1
    fi
  done < <(list_topics)

  return "${failed}"
}

#######################################
# Parses arguments and regenerates every index section.
# Arguments:
#   See show_usage.
#######################################
main() {
  local check_flag=""
  while (( $# > 0 )); do
    case "$1" in
      --check) check_flag="--check"; shift ;;
      *) log_error "Unknown option '$1'."; show_usage; exit 1 ;;
    esac
  done

  if [[ ! -f "${MANIFEST}" ]]; then
    log_error "Manifest not found: ${MANIFEST}"
    exit 1
  fi

  if ! command -v yq &> /dev/null; then
    log_error "'yq' is required but not found in PATH."
    exit 1
  fi

  update_all "${check_flag}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
#
# Checks that every script includes the libraries whose functions it calls.
#
# The compiler resolves a library's own dependencies, so a script only lists what it uses directly and
# nobody has to know that config.sh needs core.sh. What the compiler cannot know is whether the script
# listed enough: call `log_error` while including only program.sh and the development form still works —
# program.sh pulls core.sh in — but remove that include later and the script breaks at the first log line,
# which for an error path may be the first time anyone runs it.
#
# So the closure is computed the same way the compiler computes it, and every library function the script
# calls must be provided somewhere inside it.
#
# The second rule is narrower and just as easy to get wrong: the `# shellcheck source=` hint, the `source`
# command and the `# @include` directive in a loader pair must all name the same file. They are three
# statements of one fact, and only the directive is acted on — so a mismatch publishes a script whose
# development form loaded something else, or nothing.
#
# Usage:
#   ./check-includes.sh [script...]
#
# Arguments:
#   script  Scripts to check; defaults to every publishable script.
#
# Exits non-zero if a script calls a library function no included library provides, or if a loader pair
# disagrees with itself.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
LIB_DIR="${SCRIPTS_DIR}/lib"

#######################################
# Prints usage instructions to stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: $(basename "$0") [script...]

Checks that each script includes the libraries providing the functions it calls, and that every loader
pair names one file consistently.

Options:
  -h    Show this help message.
EOF
}

#######################################
# Prints the functions a library defines, one per line.
# Arguments:
#   path: Library file.
#######################################
functions_in() {
  sed -n 's/^\([a-z_][a-z0-9_]*\)() *{.*/\1/p' "$1"
}

#######################################
# Prints the libraries a file includes, transitively, one basename per line.
#
# Resolved the way the compiler resolves them — each directive relative to the file that holds it — so this
# check and the compiled output cannot disagree about what a script ends up carrying.
# Globals:
#   None
# Arguments:
#   path: File to start from.
#   Remaining arguments: basenames already seen, to keep a cycle from looping here.
#######################################
includes_of() {
  local path="$1"
  shift
  local seen=" $* "
  local dir directive resolved base

  dir=$(cd "$(dirname "${path}")" && pwd -P)
  while IFS= read -r directive; do
    resolved="${dir}/${directive}"
    base=$(basename "${resolved}")
    [[ "${seen}" == *" ${base} "* ]] && continue
    seen+="${base} "
    printf '%s\n' "${base}"
    if [[ -f "${resolved}" ]]; then
      # shellcheck disable=SC2046
      includes_of "${resolved}" $(printf '%s' "${seen}")
    fi
  done < <(sed -n 's/^[[:space:]]*#[[:space:]]*@include[[:space:]][[:space:]]*//p' "${path}")
}

#######################################
# Checks that a script's loader pairs name one file each.
# Arguments:
#   path: Script to check.
# Returns:
#   0 when every pair agrees, 1 otherwise.
#######################################
check_loader_pairs() {
  local path="$1"
  local failed=0
  local hint="" source_path="" line directive

  while IFS= read -r line; do
    if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+source=(.+)$ ]]; then
      hint="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${line}" =~ ^[[:space:]]*source[[:space:]]+.*/([^/\"]+\.sh)\"?[[:space:]]*$ ]]; then
      source_path="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*@include[[:space:]]+(.+)$ ]]; then
      directive="${BASH_REMATCH[1]}"
      if [[ -n "${hint}" && "$(basename "${hint}")" != "$(basename "${directive}")" ]]; then
        log_error "${path#"${REPO_ROOT}/"}: shellcheck hint names '${hint}' but @include names '${directive}'."
        failed=1
      fi
      if [[ -n "${source_path}" && "${source_path}" != "$(basename "${directive}")" ]]; then
        log_error "${path#"${REPO_ROOT}/"}: source loads '${source_path}' but @include names '${directive}'."
        failed=1
      fi
      hint=""
      source_path=""
    fi
  done < "${path}"

  return "${failed}"
}

#######################################
# Checks that a script includes a library for every library function it calls.
# Globals:
#   LIB_DIR, REPO_ROOT
# Arguments:
#   path: Script to check.
# Returns:
#   0 when every call is provided for, 1 otherwise.
#######################################
check_calls() {
  local path="$1"
  local failed=0

  local -A provided=()
  local -A owner=()
  local lib fn
  for lib in "${LIB_DIR}"/*.sh; do
    while IFS= read -r fn; do
      owner["${fn}"]=$(basename "${lib}")
    done < <(functions_in "${lib}")
  done

  local base
  while IFS= read -r base; do
    [[ -f "${LIB_DIR}/${base}" ]] || continue
    while IFS= read -r fn; do
      provided["${fn}"]=1
    done < <(functions_in "${LIB_DIR}/${base}")
  done < <(includes_of "${path}")

  # Calls are looked for outside the script's own definitions: a script that defines its own log_error is
  # not relying on the library's.
  local defined
  defined=" $(sed -n 's/^\([a-z_][a-z0-9_]*\)() *{.*/\1/p' "${path}" | tr '\n' ' ') "

  for fn in "${!owner[@]}"; do
    [[ -n "${provided[${fn}]:-}" ]] && continue
    [[ "${defined}" == *" ${fn} "* ]] && continue
    # Called, rather than merely mentioned in a comment.
    if grep -qE "(^|[^#[:alnum:]_-])${fn}[[:space:]]*(\\\$|\"|'|[a-zA-Z0-9_/.-]|$|\\))" <(sed 's/#.*//' "${path}"); then
      log_error "${path#"${REPO_ROOT}/"} calls ${fn}, provided by ${owner[${fn}]}, which it does not include."
      failed=1
    fi
  done

  return "${failed}"
}

#######################################
# Checks every script given, or every publishable script.
# Globals:
#   SCRIPTS_DIR
# Arguments:
#   Scripts to check.
# Returns:
#   0 when all pass, 1 otherwise.
#######################################
check_all() {
  local -a scripts=("$@")
  if (( ${#scripts[@]} == 0 )); then
    while IFS= read -r -d '' path; do
      scripts+=("${path}")
    done < <(find "${SCRIPTS_DIR}" -mindepth 2 -type f -name '*.sh' -not -path '*/lib/*' -print0 | sort -z)
  fi

  local failed=0 path
  for path in "${scripts[@]}"; do
    if [[ ! -f "${path}" ]]; then
      log_error "Script not found: ${path}"
      failed=1
      continue
    fi
    check_loader_pairs "${path}" || failed=1
    check_calls "${path}" || failed=1
  done

  if (( failed )); then
    log_error "Include check failed."
    return 1
  fi

  log_info "All ${#scripts[@]} script(s) include the libraries they use."
}

#######################################
# Parses arguments and runs the checks.
# Arguments:
#   See show_usage.
#######################################
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
  fi

  if [[ ! -d "${LIB_DIR}" ]]; then
    log_error "Library directory not found: ${LIB_DIR}"
    exit 1
  fi

  check_all "$@"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

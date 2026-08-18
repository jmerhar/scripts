#!/usr/bin/env bash
#
# Syntax-checks every awk and jq program stored beside a script.
#
# These programs run inside scripts that decide what to delete, so a typo in one surfaces at the worst
# possible moment: mid-prune, on the server, after the confirmation prompt. Held as files rather than as
# quoted strings, they can be checked before they ever run — which is the main reason for extracting
# them.
#
# Two details are established by testing the checkers rather than by reading their manuals:
#
#   * `awk -f prog.awk /dev/null` does not merely parse — it runs BEGIN and END. That is safe for these
#     programs, which only compute and print, but it means output has to be discarded and it is the
#     reason a program with side effects must never be checked this way. A parse error exits 2.
#   * `jq` exits 3 for a syntax error *and* for an undefined variable, so a filter using `--arg` values
#     has to be given them or it fails for the wrong reason. Each such file declares them in a
#     `# lint-args:` header comment, which doubles as documentation of what the filter expects.
#
# Usage:
#   ./check-programs.sh [directory...]
#
# Arguments:
#   directory  Roots to search; defaults to scripts/ and bin/, which is every place a program lives.
#              The internal tools under bin/ run their programs with `awk -f` rather than embedding them,
#              since nothing publishes those tools as a single file — but a typo in one is just as fatal,
#              so they are checked the same way.
#
# Exits non-zero if any program fails its syntax check.

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
Usage: $(basename "$0") [directory...]

Syntax-checks every .awk and .jq program under the given directories (default: scripts/ and bin/).

Options:
  -h    Show this help message.
EOF
}

#######################################
# Reads the `# lint-args:` header from a program, if it has one.
#
# A jq filter that expects --arg values cannot be checked without them, since jq reports an undefined
# variable with the same exit status as a syntax error. Declaring them beside the filter keeps the
# expectation next to the thing that has it.
# Arguments:
#   path: Program file.
# Outputs:
#   The arguments, or nothing when the file declares none.
#######################################
lint_args() {
  sed -n 's/^#[[:space:]]*lint-args:[[:space:]]*//p' "$1" | head -n 1
}

#######################################
# Syntax-checks one awk program.
#
# Runs it against /dev/null, which executes BEGIN and END; output is discarded because the check is
# only interested in whether the program parses.
# Arguments:
#   path: Program file.
# Returns:
#   0 when the program parses, 1 otherwise.
#######################################
check_awk() {
  local path="$1"
  local output status=0
  output=$(awk -f "${path}" /dev/null 2>&1) || status=$?
  if (( status != 0 )); then
    log_error "${path#"${REPO_ROOT}/"} is not valid awk:"
    printf '%s\n' "${output}" >&2
    return 1
  fi
}

#######################################
# Syntax-checks one jq program.
#
# jq has no parse-only mode, so the filter is compiled and run against `null` input, and the exit status
# is what separates the two kinds of failure:
#
#   3 — compile error. A syntax error, or a variable the filter never received: both are faults to fix,
#       which is why a filter using --arg values declares them in a `# lint-args:` header.
#   5 — runtime error. Expected here and ignored: a filter written for an object cannot do anything with
#       null, so `to_entries` on it fails for a reason that says nothing about the filter's validity.
#   2 — usage error, meaning this checker invoked jq wrongly. Reported, since silently passing would
#       leave every filter unchecked.
# Arguments:
#   path: Program file.
# Returns:
#   0 when the program compiles, 1 otherwise.
#######################################
check_jq() {
  local path="$1"
  local args_line
  args_line=$(lint_args "${path}")

  local -a args=()
  if [[ -n "${args_line}" ]]; then
    # Deliberately word-split: the header is a list of arguments written the way a caller would pass
    # them, and none of these values contains a space.
    # shellcheck disable=SC2206
    args=(${args_line})
  fi

  local output status=0
  output=$(jq -n "${args[@]}" -f "${path}" 2>&1) || status=$?
  if (( status == 2 || status == 3 )); then
    log_error "${path#"${REPO_ROOT}/"} is not valid jq:"
    printf '%s\n' "${output}" >&2
    if [[ "${output}" == *"is not defined"* ]]; then
      log_error "Declare it in a '# lint-args:' header naming the --arg values this filter expects."
    fi
    return 1
  fi
}

#######################################
# Checks that a program which will be embedded contains no single quote.
#
# A published script is a single file, so a program under scripts/ cannot be run with `awk -f` — it is
# always inlined by bin/compile/compile-includes.sh as a single-quoted literal. A single quote in it
# would end that literal early and publish a script that is not valid bash. The compiler refuses it
# too, but only at packaging time, which is after a push; checking here means a local `make lint` says
# so first.
#
# Programs under bin/ are exempt: those tools are never published as one file and run their programs with
# `awk -f`, so an apostrophe in a comment is harmless there.
# Globals:
#   REPO_ROOT, SCRIPTS_DIR
# Arguments:
#   path: Program file.
# Returns:
#   0 when the program can be embedded, 1 otherwise.
#######################################
check_embeddable() {
  local path="$1"
  case "${path}" in
    "${SCRIPTS_DIR}/"*) ;;
    *) return 0 ;;
  esac

  if grep -q "'" "${path}"; then
    log_error "${path#"${REPO_ROOT}/"} contains a single quote, which cannot be embedded in a published script:"
    grep -n "'" "${path}" >&2
    return 1
  fi
}

#######################################
# Checks every program under the given roots.
# Globals:
#   REPO_ROOT
# Arguments:
#   Directories to search.
# Returns:
#   0 when every program parses, 1 otherwise.
#######################################
check_all() {
  local failed=0 count=0 path

  while IFS= read -r -d '' path; do
    count=$(( count + 1 ))
    case "${path}" in
      *.awk) check_awk "${path}" || failed=1 ;;
      *.jq)  check_jq "${path}" || failed=1 ;;
    esac
    check_embeddable "${path}" || failed=1
  done < <(find "$@" -type f \( -name '*.awk' -o -name '*.jq' \) -print0 | sort -z)

  if (( failed )); then
    log_error "Program syntax check failed."
    return 1
  fi

  log_info "All ${count} program(s) parse."
}

#######################################
# Parses arguments and checks every program.
# Arguments:
#   See show_usage.
#######################################
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
  fi

  local -a roots=("$@")
  if (( ${#roots[@]} == 0 )); then
    roots=("${SCRIPTS_DIR}" "${REPO_ROOT}/bin")
  fi

  # Resolved to physical paths, because the embeddability rule compares a found path against
  # SCRIPTS_DIR, which is itself physical. Left as given, a root reached through a symlink would yield
  # paths that never match the prefix, and the rule would quietly apply to nothing.
  local -a resolved=()
  local root
  for root in "${roots[@]}"; do
    if [[ ! -d "${root}" ]]; then
      log_error "Directory not found: ${root}"
      exit 1
    fi
    resolved+=("$(cd "${root}" && pwd -P)")
  done
  roots=("${resolved[@]}")

  if ! command -v awk &> /dev/null; then
    log_error "'awk' is required but not found in PATH."
    exit 1
  fi

  if ! command -v jq &> /dev/null; then
    log_error "'jq' is required but not found in PATH."
    exit 1
  fi

  check_all "${roots[@]}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

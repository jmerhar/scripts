#!/usr/bin/env bash
#
# Fails when a script writes a multi-line awk or jq program inside itself.
#
# Such a program is one bash command spanning several lines, and bash attributes a multi-line command to
# its final line — so kcov counts the first line as never executed and does not instrument the lines
# between at all. Those lines are not even bash: they run as awk or jq, and no bash test can reach them.
# A program in its own file is not measured, is syntax-checked by check-programs.sh before it can run, and
# is read with the syntax highlighting of the language it is written in.
#
# The fix is the convention the repository already follows: put the program in a file beside the script
# and load it on one line.
#
#   prog=$(load_program candidates.jq)  # @embed candidates.jq
#   jq "${args[@]}" "${prog}" <<<"${status}"
#
# The bin/ tools have no publishing constraint and run theirs with `awk -f prog.awk` instead, which is
# equally acceptable here — what is not is the program living inside a quoted string.
#
# A single-line program stays inline and is not reported. It costs one line that is measured like any
# other statement, and a file for `BEGIN { print b / c }` would be harder to read, not easier.
#
# Only awk and jq are checked. Other commands take multi-line quoted arguments for reasons that have no
# file to move to — dmarc-report's two `xmllint --xpath` expressions have no program-file option and both
# contain single quotes, so they cannot be extracted at all, and coverage.toml accounts for the lines they
# cost.
#
# Usage:
#   ./check-inline-programs.sh [directory...]
#
# Arguments:
#   directory  Roots to search; defaults to scripts/ and bin/, which is every place a script lives.
#
# Exits non-zero if any script holds a multi-line program.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"

readonly DETECTOR="${SCRIPT_DIR}/inline-programs.awk"

#######################################
# Prints usage instructions to stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: $(basename "$0") [directory...]

Fails when a script under the given directories (default: scripts/ and bin/) holds
a multi-line awk or jq program in a quoted string instead of in a file beside it.

Options:
  -h    Show this help message.
EOF
}

#######################################
# Reports every unterminated awk or jq program in one script.
# Globals:
#   REPO_ROOT, DETECTOR
# Arguments:
#   path: Shell file to read.
# Returns:
#   0 when the file holds none, 1 otherwise.
#######################################
check_file() {
  local path="$1" rel="${1#"${REPO_ROOT}/"}"
  local found=0 lineno
  while IFS= read -r lineno; do
    log_error "${rel}:${lineno} opens an awk or jq program that does not end on that line."
    found=1
  done < <(awk -f "${DETECTOR}" "${path}")
  return "${found}"
}

#######################################
# Checks every shell file under the given roots.
#
# Symlinks are followed, as the test fixtures mirror bin/ as links into the real tree.
# Arguments:
#   Directories to search.
# Returns:
#   0 when no script holds a multi-line program, 1 otherwise.
#######################################
check_all() {
  local failed=0 count=0 path
  while IFS= read -r -d '' path; do
    count=$(( count + 1 ))
    check_file "${path}" || failed=1
  done < <(find -L "$@" -type f -name '*.sh' -print0 | sort -z)

  if (( failed )); then
    log_error "Move the program into a file beside the script and load it with load_program, naming it in an '# @embed' directive — or, for a bin/ tool, run it with 'awk -f'."
    return 1
  fi

  log_info "All ${count} script(s) keep their awk and jq programs to one line or to a file."
}

#######################################
# Parses arguments and checks every script.
# Globals:
#   REPO_ROOT, SCRIPTS_DIR, DETECTOR
# Arguments:
#   See show_usage.
#######################################
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
  fi

  if [[ ! -r "${DETECTOR}" ]]; then
    log_error "Detector program not found: ${DETECTOR}"
    exit 1
  fi

  local -a roots=("$@")
  if (( ${#roots[@]} == 0 )); then
    roots=("${SCRIPTS_DIR}" "${REPO_ROOT}/bin")
  fi

  # Resolved to physical paths, because the reported path is relative to REPO_ROOT, which is itself
  # physical. Left as given, a root reached through a symlink would print every path in full.
  local -a resolved=()
  local root
  for root in "${roots[@]}"; do
    if [[ ! -d "${root}" ]]; then
      log_error "Directory not found: ${root}"
      exit 1
    fi
    resolved+=("$(cd "${root}" && pwd -P)")
  done

  check_all "${resolved[@]}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

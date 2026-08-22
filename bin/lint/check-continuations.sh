#!/usr/bin/env bash
#
# Fails when a measured shell file contains a `\` line continuation.
#
# kcov instruments every file under scripts/ and bin/, and bash attributes a multi-line command to its
# *final* line. So the first line of a continuation is reported as never executed and the lines between
# are not instrumented at all: a command spread over four lines contributes one covered line and three
# that look dead. The loss is silent — it appears as a coverage gate with less headroom than the code
# deserves, never as a diff that did anything wrong — which is why it is checked mechanically rather
# than remembered. Seventeen of them had accumulated before anyone counted.
#
# Line length is free here and a continuation is not, so the fix is always the same: put the command on
# one long line.
#
# What this does not catch: a command spread over several lines *without* a backslash, which a quoted
# multi-line awk or jq program is the usual way to write. Bash attributes those to their final line for
# exactly the same reason, and the interior lines are not even bash. The convention that keeps them out
# is a separate one — a program longer than a line or two lives in its own file, where check-programs.sh
# syntax-checks it and nothing measures it as bash.
#
# Usage:
#   ./check-continuations.sh [directory...]
#
# Arguments:
#   directory  Roots to search; defaults to scripts/ and bin/, which is what kcov measures. test/ is
#              deliberately outside that set: nothing measures the suite, so a continuation there costs
#              nothing and reads better than a long line.
#
# Exits non-zero if any file carries a continuation.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"

# A line whose last character is a backslash that is not itself escaped. The leading alternation is what
# excludes a line ending in two backslashes: there the final backslash is a literal, the command ends,
# and kcov sees nothing unusual.
readonly CONTINUATION_RE='(^|[^\])\\$'

# The one measured-path exception, because it is not measured: test/test_helper.bash passes
# --exclude-pattern=run-coverage.sh to kcov, so continuations there cost no coverage. Matched as a path
# relative to the repository root, so it exempts that one file rather than every file with the name.
readonly EXEMPT_PATH="bin/coverage/run-coverage.sh"

#######################################
# Prints usage instructions to stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: $(basename "$0") [directory...]

Fails when a shell file under the given directories (default: scripts/ and bin/) contains a backslash
line continuation, which kcov cannot attribute to the lines it spans.

Options:
  -h    Show this help message.
EOF
}

#######################################
# Reports every line continuation in one file.
# Globals:
#   REPO_ROOT, CONTINUATION_RE
# Arguments:
#   path: Shell file to read.
# Returns:
#   0 when the file has none, 1 otherwise.
#######################################
check_file() {
  local path="$1" rel="${1#"${REPO_ROOT}/"}"
  local found=0 hit
  # grep exits 1 for no match, which is the passing case here, so its status is discarded and the
  # presence of output is what decides.
  while IFS= read -r hit; do
    log_error "${rel}:${hit%%:*} ends with a line continuation."
    found=1
  done < <(grep -nE "${CONTINUATION_RE}" "${path}" || true)
  return "${found}"
}

#######################################
# Checks every shell file under the given roots.
#
# Symlinks are followed: the test fixtures mirror bin/ as links into the real tree, and a check that
# skipped them would pass by looking at nothing.
# Globals:
#   REPO_ROOT, EXEMPT_PATH
# Arguments:
#   Directories to search.
# Returns:
#   0 when no file carries a continuation, 1 otherwise.
#######################################
check_all() {
  local failed=0 count=0 path
  while IFS= read -r -d '' path; do
    if [[ "${path#"${REPO_ROOT}/"}" == "${EXEMPT_PATH}" ]]; then
      continue
    fi
    count=$(( count + 1 ))
    check_file "${path}" || failed=1
  done < <(find -L "$@" -type f -name '*.sh' -print0 | sort -z)

  if (( failed )); then
    log_error "A continuation hides the lines it spans from kcov. Put the command on one long line."
    return 1
  fi

  log_info "All ${count} shell file(s) are free of line continuations."
}

#######################################
# Parses arguments and checks every file.
# Globals:
#   REPO_ROOT, SCRIPTS_DIR
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

  # Resolved to physical paths, because both the exemption and the reported path compare a found path
  # against REPO_ROOT, which is itself physical. Left as given, a root reached through a symlink — which
  # is every root under a macOS temp directory, /var being a link to /private/var — yields paths that
  # never match the prefix, so the exemption would quietly apply to nothing and every path would print
  # in full.
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

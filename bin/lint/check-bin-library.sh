#!/usr/bin/env bash
#
# Checks that every bin/ tool sources the library files whose symbols it uses.
#
# The tools load bin/_lib/ with a plain `source` at run time, so a tool that calls log_error while
# sourcing only paths.sh does not fail at load: it fails at the call, and for an error path that may be
# the first time anyone reaches it — during a release, in a workflow, at the moment something is already
# going wrong. The compiler-driven closure that check-includes.sh computes for publishable scripts has no
# equivalent here, because nothing inlines bin/_lib and its two files depend on nothing, so the rule is
# simply: use a symbol, source the file that provides it.
#
# The reverse is checked too, matching the rule the publishable scripts follow: a tool lists only the
# libraries it actually uses, so a source line is never left behind after the last call that needed it.
#
# The third rule is the bin/ half of check-includes.sh's loader-pair rule: a `# shellcheck source=` hint
# above a `source` line must name the same file. Only the `source` line is acted on, so a mismatch leaves
# ShellCheck resolving a file the tool never loads.
#
# A library file provides its functions and its uppercase globals; names beginning with an underscore are
# private to it — the double-source guards are the reason that distinction exists.
#
# Usage:
#   ./check-bin-library.sh [tool...]
#
# Arguments:
#   tool  Tools to check; defaults to every script under bin/ outside _lib/.
#
# Exits non-zero if a tool uses a symbol from a library it does not source, sources one it does not use,
# or carries a shellcheck hint that disagrees with the source line beneath it.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
BIN_DIR="${REPO_ROOT}/bin"
BIN_LIB_DIR="${BIN_DIR}/_lib"

#######################################
# Prints usage instructions to stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: $(basename "$0") [tool...]

Checks that every bin/ tool sources the bin/_lib/ files whose symbols it uses, uses every
file it sources, and pairs each shellcheck hint with the source line beneath it.

Options:
  -h, --help  Show this help message.
EOF
}

#######################################
# Prints the symbols a library file provides, one per line.
#
# Functions and uppercase globals both count: paths.sh provides only variables and log.sh only functions,
# so a check that looked at one kind would silently pass the other. Leading-underscore names are private —
# each library's double-source guard sets one, and no tool has any business reading it.
# Arguments:
#   path: Library file.
# Outputs:
#   One symbol name per line.
#######################################
symbols_in() {
  sed -n -e 's/^\([a-z_][a-z0-9_]*\)() *{.*/\1/p' -e 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$1" | sort -u
}

#######################################
# Prints the basename of each bin/_lib file a tool sources.
# Arguments:
#   path: Tool to read.
# Outputs:
#   One library basename per line.
#######################################
sourced_libs() {
  sed -n 's|^[[:space:]]*source[[:space:]].*/_lib/\([a-z_]*\.sh\)".*|\1|p' "$1" | sort -u
}

#######################################
# Reports whether a tool uses a symbol.
#
# Comments are stripped first, so a doc block naming REPO_ROOT under `Globals:` is not a use. The symbol
# has to stand alone rather than sit inside a longer identifier.
# Arguments:
#   path: Tool to read.
#   symbol: Symbol name.
# Returns:
#   0 when the tool uses the symbol, 1 otherwise.
#######################################
uses_symbol() {
  local path="$1" symbol="$2"
  grep -qE "(^|[^A-Za-z0-9_])${symbol}([^A-Za-z0-9_]|$)" <(sed 's/#.*//' "${path}")
}

#######################################
# Checks that each shellcheck hint names the file the source line beneath it loads.
# Arguments:
#   path: Tool to check.
# Globals:
#   REPO_ROOT
# Returns:
#   0 when every pair agrees, 1 otherwise.
#######################################
check_hint_pairs() {
  local path="$1"
  local failed=0
  local hint="" line

  while IFS= read -r line; do
    if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+source=(.+)$ ]]; then
      hint="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${line}" =~ ^[[:space:]]*source[[:space:]]+.*/([^/\"]+\.sh)\"?[[:space:]]*$ ]]; then
      if [[ -n "${hint}" && "$(basename "${hint}")" != "${BASH_REMATCH[1]}" ]]; then
        log_error "${path#"${REPO_ROOT}/"}: shellcheck hint names '${hint}' but source loads '${BASH_REMATCH[1]}'."
        failed=1
      fi
      hint=""
      continue
    fi
    # A hint applies to the line under it, so anything else between the two ends the pair.
    hint=""
  done < "${path}"

  return "${failed}"
}

#######################################
# Checks that a tool sources exactly the library files it uses.
# Globals:
#   BIN_LIB_DIR, REPO_ROOT
# Arguments:
#   path: Tool to check.
# Returns:
#   0 when the tool sources what it uses and uses what it sources, 1 otherwise.
#######################################
check_symbols() {
  local path="$1"
  local failed=0
  local rel="${path#"${REPO_ROOT}/"}"

  local sourced
  sourced=" $(sourced_libs "${path}" | tr '\n' ' ')"

  # A tool that defines a symbol itself is not relying on the library's.
  local defined
  defined=" $(sed -n 's/^\([a-z_][a-z0-9_]*\)() *{.*/\1/p;s/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "${path}" | tr '\n' ' ')"

  local lib base symbol used
  for lib in "${BIN_LIB_DIR}"/*.sh; do
    [[ -e "${lib}" ]] || continue
    base=$(basename "${lib}")
    used=0
    while IFS= read -r symbol; do
      [[ -z "${symbol}" ]] && continue
      [[ "${defined}" == *" ${symbol} "* ]] && continue
      uses_symbol "${path}" "${symbol}" || continue
      used=1
      if [[ "${sourced}" != *" ${base} "* ]]; then
        log_error "${rel} uses ${symbol}, provided by _lib/${base}, which it does not source."
        failed=1
      fi
    done < <(symbols_in "${lib}")

    if (( ! used )) && [[ "${sourced}" == *" ${base} "* ]]; then
      log_error "${rel} sources _lib/${base} but uses nothing from it."
      failed=1
    fi
  done

  return "${failed}"
}

#######################################
# Checks every given tool, or every tool under bin/ outside _lib/.
# Globals:
#   BIN_DIR, REPO_ROOT
# Arguments:
#   Tools to check.
# Returns:
#   0 when every tool checks out, 1 otherwise.
#######################################
check_all() {
  local -a tools=("$@")
  if (( ${#tools[@]} == 0 )); then
    local path
    # -L so the walk resolves symlinks: the test fixtures mirror bin/ as links into the real tree, and
    # without it `-type f` matches none of them and the check passes having read nothing.
    while IFS= read -r -d '' path; do
      tools+=("${path}")
    done < <(find -L "${BIN_DIR}" -mindepth 2 -type f -name '*.sh' -not -path '*/_lib/*' -print0 | sort -z)
  fi

  # Unreachable while the walk above is right — it always finds at least this tool — and kept for when it
  # is not: a predicate that matches nothing would otherwise report success having read no file at all,
  # which is how `-type f` against a fixture of symlinks passed silently.
  if (( ${#tools[@]} == 0 )); then
    log_error "No tools to check under ${BIN_DIR#"${REPO_ROOT}/"}."
    return 1
  fi

  local failed=0 tool
  for tool in "${tools[@]}"; do
    if [[ ! -f "${tool}" ]]; then
      log_error "Tool not found: ${tool}"
      failed=1
      continue
    fi
    check_hint_pairs "${tool}" || failed=1
    check_symbols "${tool}" || failed=1
  done

  if (( failed )); then
    log_error "bin/ library check failed."
    return 1
  fi

  log_info "All ${#tools[@]} bin/ tool(s) source the library files they use."
}

#######################################
# Parses arguments and runs the checks.
#
# There is no guard for a missing bin/_lib: it is the directory this tool sourced its own library from, so
# reaching here at all proves it exists. check-includes.sh needs one because scripts/lib/ is somewhere
# else entirely.
# Arguments:
#   See show_usage.
#######################################
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
  fi

  check_all "$@"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

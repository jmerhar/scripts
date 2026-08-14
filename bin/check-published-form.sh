#!/usr/bin/env bash
#
# Verifies that compiling the tree produces published scripts that are genuinely self-contained.
#
# A published script is a single file: it carries the shared library inline instead of sourcing it, and
# each awk or jq program inline instead of reading it from beside the script. Neither the library nor the
# programs are shipped, so a script that still refers to them is one that fails on a user's machine at
# the first line that needs it. Nothing else checks this: package-script.sh does not compile, so
# `make smoke` alone packages the development form, and the release workflow compiles as a separate step.
#
# The compiler rewrites in place, which is right for a disposable CI checkout and wrong for a working
# tree — so this copies the tree to a temporary directory and compiles the copy, leaving the working tree
# untouched.
#
# It must therefore run against an *uncompiled* tree. The @embed directives are what it reads to know
# which program belongs to which script, and compiling removes them: run after an in-place compile, it
# would find no directives and report success having checked nothing. Hence its position before the
# compile step in the lint workflow.
#
# Checked, per published script:
#   * no `# @include` or `# @embed` directive, and no `load_program` call, survives;
#   * no `source`/`.` of the shared library survives;
#   * the file parses as bash;
#   * every program named by an `@embed` in the source tree appears in the compiled file with exactly the
#     text of its program file — the guarantee that tests exercising the development form say something
#     about what users run.
#
# Usage:
#   ./check-published-form.sh
#
# Exits non-zero if any published script would not be self-contained.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
WORK=""

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
# Prints a timestamped info message to stderr.
# Arguments:
#   Message to print.
#######################################
log_info() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [INFO]: $*" >&2
}

#######################################
# Removes the temporary copy of the tree.
# Globals:
#   WORK
#######################################
cleanup() {
  [[ -n "${WORK}" && -d "${WORK}" ]] && rm -rf "${WORK}"
}

#######################################
# Copies the working tree to a temporary directory and compiles it there.
# Globals:
#   REPO_ROOT, WORK
#######################################
compile_copy() {
  WORK=$(mktemp -d)
  trap cleanup EXIT
  # The working tree rather than HEAD, so this checks what is about to be committed.
  tar cf - -C "${REPO_ROOT}" --exclude=.git --exclude=dist --exclude=coverage . | tar xf - -C "${WORK}"
  ( cd "${WORK}" && ./bin/compile-all-includes.sh >/dev/null )
}

#######################################
# Reports any development-only construct left in a compiled script.
# Globals:
#   WORK
# Arguments:
#   rel: Script path relative to the repository root.
# Returns:
#   0 when the script is self-contained, 1 otherwise.
#######################################
check_self_contained() {
  local rel="$1"
  local compiled="${WORK}/${rel}"
  local failed=0 found

  # A real directive is an assignment, so a line whose first non-blank character is `#` is documentation
  # and not a leftover — the shared library documents the mechanism it implements.
  found=$(grep -nE '^[[:space:]]*[^#[:space:]][^=]*=\$\(load_program[[:space:]]' "${compiled}" || true)
  if [[ -n "${found}" ]]; then
    log_error "${rel} still reads a program at run time:"
    printf '%s\n' "${found}" >&2
    failed=1
  fi

  found=$(grep -nE '^[[:space:]]*#[[:space:]]*@(include|embed)[[:space:]]' "${compiled}" || true)
  if [[ -n "${found}" ]]; then
    log_error "${rel} still carries an unprocessed directive:"
    printf '%s\n' "${found}" >&2
    failed=1
  fi

  found=$(grep -nE '^[[:space:]]*(source|\.)[[:space:]]+.*lib/common\.sh' "${compiled}" || true)
  if [[ -n "${found}" ]]; then
    log_error "${rel} still sources the shared library:"
    printf '%s\n' "${found}" >&2
    failed=1
  fi

  # Defensive: with the compiler refusing a program that contains a single quote, there is no program
  # content that can make the compiled file invalid bash. This catches a fault in the compiler itself,
  # not in a program — bin/check-programs.sh is what rejects a program that awk or jq cannot parse.
  if ! bash -n "${compiled}" 2>/dev/null; then
    log_error "${rel} does not parse after compilation."
    bash -n "${compiled}" 2>&1 | head -n 5 >&2 || true
    failed=1
  fi

  return "${failed}"
}

#######################################
# Checks that every program an @embed names appears in the compiled script with its exact text.
# Globals:
#   REPO_ROOT, WORK
# Arguments:
#   rel: Script path relative to the repository root.
# Outputs:
#   The number of embedded programs verified, on stdout.
# Returns:
#   0 when every embedded program matches, 1 otherwise.
#######################################
check_embedded_text() {
  local rel="$1"
  local source_file="${REPO_ROOT}/${rel}"
  local compiled="${WORK}/${rel}"
  local script_dir
  script_dir=$(dirname "${source_file}")
  local failed=0 count=0

  local line indent var name program expected
  while IFS= read -r line; do
    [[ "${line}" =~ ^([[:space:]]*)([A-Za-z_][A-Za-z0-9_]*)=\$\(load_program[[:space:]]+([^\)]+)\)[[:space:]]*#[[:space:]]*@embed ]] || continue
    indent="${BASH_REMATCH[1]}"
    var="${BASH_REMATCH[2]}"
    name="${BASH_REMATCH[3]}"
    name="${name%"${name##*[![:space:]]}"}"

    program=$(cat "${script_dir}/${name}")
    expected="${indent}${var}='${program}'"
    count=$(( count + 1 ))

    if ! grep -qF -- "${expected%%$'\n'*}" "${compiled}"; then
      log_error "${rel}: the text of ${name} is not in the compiled script."
      failed=1
    fi
  done < "${source_file}"

  printf '%s' "${count}"
  return "${failed}"
}

#######################################
# Reports whether the source tree still carries the directives this check reads.
#
# A tree that has already been compiled has none, and every check below would then pass having verified
# nothing. Saying so is the difference between a green run that means something and one that does not.
# Globals:
#   REPO_ROOT
# Returns:
#   0 when the tree is in its development form, 1 when it appears already compiled.
#######################################
tree_is_uncompiled() {
  grep -rqE '^[[:space:]]*#[[:space:]]*@(include|embed)[[:space:]]' "${REPO_ROOT}/scripts" --include='*.sh'
}

#######################################
# Checks every publishable script.
# Globals:
#   REPO_ROOT, WORK
# Returns:
#   0 when every published script is self-contained, 1 otherwise.
#######################################
check_all() {
  local failed=0 scripts=0 programs=0 script rel n

  while IFS= read -r -d '' script; do
    rel="${script#"${REPO_ROOT}/"}"
    scripts=$(( scripts + 1 ))
    check_self_contained "${rel}" || failed=1
    n=$(check_embedded_text "${rel}") || failed=1
    programs=$(( programs + n ))
  done < <(find "${REPO_ROOT}/scripts" -mindepth 2 -type f -name '*.sh' -not -path '*/lib/*' -print0 | sort -z)

  if (( failed )); then
    log_error "Published form check failed."
    return 1
  fi

  log_info "All ${scripts} published script(s) are self-contained, with ${programs} program(s) inlined."
}

#######################################
# Compiles a copy of the tree and checks the result.
#######################################
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<EOF
Usage: $(basename "$0")

Compiles a temporary copy of the tree and verifies every published script is self-contained.

Options:
  -h    Show this help message.
EOF
    exit 0
  fi

  if ! tree_is_uncompiled; then
    log_error "No @include or @embed directive found under scripts/: this tree looks already compiled."
    log_error "Run this against a development tree, or the check passes without verifying anything."
    exit 1
  fi

  compile_copy
  check_all
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
#
# Compile the `# @include` directives of every publishable script, in place.
#
# Publishing and the packaging smoke test both need the whole tree inlined before packaging, so the walk
# lives here rather than in each workflow: the same code then runs locally, is checked by ShellCheck, and
# is covered by test/bin/compile-all-includes.bats.
#
# The library itself is skipped — it is what gets inlined, and it is not published as a package.
#
# Usage:
#   ./compile-all-includes.sh [script-dir]
#
# script-dir defaults to the repository's scripts/ directory.

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
readonly COMPILER="${HERE}/compile-includes.sh"

#######################################
# Compiles every script under a directory that carries an @include directive.
# Globals:
#   COMPILER
# Arguments:
#   root: Directory to walk.
# Outputs:
#   One line per compiled script.
# Returns:
#   0 on success, 1 if the directory does not exist or a compilation fails.
#######################################
compile_tree() {
  local root="$1"
  if [[ ! -d "${root}" ]]; then
    echo "compile-all-includes: no such directory: ${root}" >&2
    return 1
  fi

  local script count=0
  # NUL-delimited so a path containing whitespace cannot be split, and the library directory is excluded
  # because it is the file being inlined rather than a script to publish.
  while IFS= read -r -d '' script; do
    if grep -q '# @include ' "${script}"; then
      echo "Compiling: ${script}"
      "${COMPILER}" "${script}" -i
      count=$(( count + 1 ))
    fi
  done < <(find "${root}" -type f -name '*.sh' -not -path '*/lib/*' -print0 | sort -z)

  echo "Compiled ${count} script(s)."
}

main() {
  local root="${1:-${HERE}/../scripts}"
  compile_tree "${root}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

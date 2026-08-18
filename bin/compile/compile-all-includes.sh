#!/usr/bin/env bash
#
# Compiles every publishable script into dist/compiled/, resolving its `# @include` directives.
#
# The compiled form is what gets published: a single file carrying the shared library and any awk or jq
# programs inline, since neither is shipped beside it. Writing to an output directory rather than over the
# sources is what lets this run anywhere — `make compile` in a working tree, the lint workflow, the release
# workflow — with one code path and nothing to undo afterwards.
#
# Every script is compiled, not only the ones with directives, so dist/compiled/ is the complete set that
# bin/package/package-script.sh and bin/lint/check-published-form.sh read. A script with no directives
# is copied unchanged.
#
# The library itself is skipped: it is what gets inlined, and it is not published as a package.
#
# Usage:
#   ./compile-all-includes.sh [-o output-dir] [script-dir]
#
# Arguments:
#   script-dir  Directory to walk; defaults to the repository's scripts/ directory.
#
# Options:
#   -o DIR      Where to write the compiled scripts; defaults to dist/compiled/.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
readonly COMPILER="${SCRIPT_DIR}/compile-includes.sh"
readonly DEFAULT_OUTPUT_DIR="${REPO_ROOT}/dist/compiled"

#######################################
# Compiles every script under a directory into the output directory.
#
# The output is named after the script, not after its path, because the published artefact is a single
# file named after the script — so dist/compiled mirrors what a user installs rather than the source tree.
# Globals:
#   COMPILER
# Arguments:
#   root: Directory to walk.
#   out_dir: Directory to write compiled scripts into.
# Outputs:
#   One line per compiled script.
# Returns:
#   0 on success, 1 if the directory does not exist or a compilation fails.
#######################################
compile_tree() {
  local root="$1"
  local out_dir="$2"

  if [[ ! -d "${root}" ]]; then
    echo "compile-all-includes: no such directory: ${root}" >&2
    return 1
  fi

  mkdir -p "${out_dir}"

  local script count=0 out
  # NUL-delimited so a path containing whitespace cannot be split, and the library directory is excluded
  # because it is the file being inlined rather than a script to publish.
  while IFS= read -r -d '' script; do
    out="${out_dir}/$(basename "${script}")"
    echo "Compiling: ${script} -> ${out}"
    "${COMPILER}" "${script}" "${out}"
    # Runnable straight out of dist/compiled, which is what makes the compiled form easy to try by hand.
    chmod +x "${out}"
    count=$(( count + 1 ))
  done < <(find "${root}" -type f -name '*.sh' -not -path '*/lib/*' -print0 | sort -z)

  echo "Compiled ${count} script(s)."
}

#######################################
# Parses arguments and compiles the tree.
# Globals:
#   SCRIPT_DIR, DEFAULT_OUTPUT_DIR
# Arguments:
#   See the usage above.
#######################################
main() {
  local out_dir="${DEFAULT_OUTPUT_DIR}"

  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -o)
        if (( $# < 2 )); then
          echo "compile-all-includes: -o requires a directory." >&2
          exit 1
        fi
        out_dir="$2"
        shift 2
        ;;
      -h | --help)
        sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *)
        echo "compile-all-includes: unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  local root="${1:-${SCRIPTS_DIR}}"
  compile_tree "${root}" "${out_dir}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

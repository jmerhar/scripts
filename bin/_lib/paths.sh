# shellcheck shell=bash
#
# Shared path resolution for the bin/ tools.
#
# Every bin/ tool derives the repository root from its own location. The tools live one
# directory below bin/ (bin/<group>/<tool>.sh), so the root is two levels up. That depth
# is stated here, once, rather than reproduced in each tool: a tool is moved between
# groups, or the tree is reorganised, by changing this file alone.
#
# A tool sources this after setting SCRIPT_DIR to its own directory:
#
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
#   readonly SCRIPT_DIR
#   # shellcheck source=../_lib/paths.sh
#   source "${SCRIPT_DIR}/../_lib/paths.sh"
#
# Globals set:
#   REPO_ROOT     The repository root (absolute, symlinks resolved).
#   MANIFEST      The scripts.yaml path.
#   SCRIPTS_DIR   The scripts/ directory (publishable scripts and their shared library).
#
# Arguments:
#   None. Reads SCRIPT_DIR from the caller's environment.

# Double-source guard. It is what makes the `readonly` below safe: without it a second source would
# fail to re-assign REPO_ROOT and, under `set -o errexit`, take the tool down with it.
if [[ "${_BIN_PATHS_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_BIN_PATHS_SH_LOADED="true"

# The root below is computed from SCRIPT_DIR, so a tool that forgot to set it would otherwise die on
# "SCRIPT_DIR: unbound variable" pointing into a library it did not write. Named here, because the fix
# belongs in the caller's preamble.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
  printf '%s\n' "bin/_lib/paths.sh: SCRIPT_DIR must be set to the sourcing tool's directory first." >&2
  exit 1
fi

# bin/ tools live at bin/<group>/, so the root is the caller's grandparent. cd -P resolves
# symlinks, which matters under the test harness where a tool is reached through a fixture
# tree of symlinks.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

MANIFEST="${REPO_ROOT}/scripts.yaml"
# shellcheck disable=SC2034 # Set for the sourcing tool, not read here.
readonly MANIFEST

SCRIPTS_DIR="${REPO_ROOT}/scripts"
# shellcheck disable=SC2034 # Set for the sourcing tool, not read here.
readonly SCRIPTS_DIR

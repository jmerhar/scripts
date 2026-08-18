#!/usr/bin/env bash
#
# Package every script in the manifest at a throwaway version, as a smoke test.
#
# This is what proves the manifest and the packager still agree — a new entry with a missing field, or a
# script whose metadata no longer matches the tree, fails here rather than during a release. It lives in a
# script rather than in workflow YAML so `make lint` can run it before a push and
# test/bin/smoke-package-all.bats can cover it.
#
# Usage:
#   ./smoke-package-all.sh [version]
#
# version defaults to v0.0.0 and is never released; the artefacts land in dist/ like any other build.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
readonly PACKAGER="${SCRIPT_DIR}/package-script.sh"

#######################################
# Packages every manifest entry at the given version.
# Globals:
#   PACKAGER, MANIFEST
# Arguments:
#   version: Version string to build at.
# Outputs:
#   One line per script packaged.
# Returns:
#   0 when every entry packaged, 1 if the manifest is missing or unreadable, or a build failed.
#######################################
package_all() {
  local version="$1"

  if ! command -v yq &>/dev/null; then
    echo "smoke-package-all: yq is required to read the manifest." >&2
    return 1
  fi
  if [[ ! -r "${MANIFEST}" ]]; then
    echo "smoke-package-all: manifest not found: ${MANIFEST}" >&2
    return 1
  fi

  local name count=0
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    echo "Smoke-testing: ${name}"
    "${PACKAGER}" "${name}" "${version}"
    count=$(( count + 1 ))
  done < <(yq eval '.scripts | keys | .[]' "${MANIFEST}")

  if (( count == 0 )); then
    echo "smoke-package-all: the manifest lists no scripts." >&2
    return 1
  fi
  echo "Packaged ${count} script(s)."
}

main() {
  package_all "${1:-v0.0.0}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

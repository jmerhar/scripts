#!/usr/bin/env bash
#
# Package every script in the manifest at a throwaway version, as a smoke test.
#
# This is what proves the manifest and the packager still agree — a new entry with a missing field, or a
# script whose metadata no longer matches the tree, fails here rather than during a release — and that
# each published script answers --version with the version it was packaged at. It lives in a
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
# Runs one packaged script's published form with --version and checks it reports the version it was
# packaged at.
#
# Reads the script out of the tarball, the artefact every channel is built from, so what is checked is
# what a user installs: the stamped version and the bash guard ahead of it, as well as the option itself.
# Globals:
#   MANIFEST, REPO_ROOT
# Arguments:
#   name:    Manifest key of the script.
#   version: Version it was packaged at, with its leading "v".
# Outputs:
#   An explanation on stderr when the report is wrong.
# Returns:
#   0 when the script prints "<name> <version>", 1 otherwise.
#######################################
check_published_version() {
  local name="$1" version="$2"
  local filename tarball work reported
  filename=$(basename "$(yq eval ".scripts.\"${name}\".path" "${MANIFEST}")")
  tarball="${REPO_ROOT}/dist/tarballs/scripts-${name}-${version}.tar.gz"
  work=$(mktemp -d)
  tar -xzf "${tarball}" -C "${work}"
  reported=$(bash "${work}/scripts-${name}-${version}/${filename}" --version 2>&1) || true
  rm -rf "${work}"

  if [[ "${reported}" != "${name} ${version#v}" ]]; then
    echo "smoke-package-all: ${name} --version reported '${reported}', expected '${name} ${version#v}'." >&2
    return 1
  fi
}

#######################################
# Packages every manifest entry at the given version, and checks each published script reports it.
# Globals:
#   PACKAGER, MANIFEST
# Arguments:
#   version: Version string to build at.
# Outputs:
#   One line per script packaged.
# Returns:
#   0 when every entry packaged, 1 if the manifest is missing or unreadable, a build failed, or a
#   published script reported the wrong version.
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
    check_published_version "${name}" "${version}"
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

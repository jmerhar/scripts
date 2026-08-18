#!/usr/bin/env bash
#
# Packages a release and uploads its tarball as a release asset.
#
# Two modes, matching the two ways publish.yml runs: one script from a release tag, or the latest version
# of every script in the manifest from a manual dispatch. Both print the commit message the downstream
# repositories should carry, so the caller does not have to compose it.
#
# This was 44 lines inside a workflow `run:` block, where the tag parsing — the part that decides which
# script gets published, and refuses a malformed tag — could only be exercised by cutting a release. As a
# script it is checked by ShellCheck and covered by test/bin/release-package.bats.
#
# Usage:
#   ./release-package.sh release <tag>
#   ./release-package.sh republish-all
#   ./release-package.sh workflow_dispatch
#
# Arguments:
#   tag   A release tag of the form script-name-vX.Y.Z.
#
# The mode may be given as a GitHub event name — `release` or `workflow_dispatch` — so the workflow passes
# `github.event_name` straight through and the choice between publishing one script and republishing all
# of them is made here, where it is tested, rather than in a conditional in YAML.
#
# Outputs:
#   The commit message on stdout; progress on stderr. When GITHUB_OUTPUT is set, `commit_message=…` is
#   appended to it as well, which is what the workflow reads.
#
# Environment:
#   GH_TOKEN   Required by `gh release upload`.
#
# Exits non-zero on a malformed tag, an unknown mode, or a failed packaging run.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
PACKAGER="${SCRIPT_DIR}/package-script.sh"

#######################################
# Prints usage instructions to stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: $(basename "$0") release <tag>
       $(basename "$0") republish-all
       $(basename "$0") workflow_dispatch

Packages a release and uploads its tarball, printing the commit message for the downstream repositories.
The mode may also be a GitHub event name, so `github.event_name` can be passed through unchanged.

Options:
  -h    Show this help message.
EOF
}

#######################################
# Splits a release tag into a script name and a version.
#
# The pattern is what decides which script a release publishes, so a tag that does not match is refused
# rather than guessed at: publishing the wrong script, or a version the tarball name will not match, is
# worse than a failed run.
# Arguments:
#   tag: The release tag.
# Outputs:
#   "<name> <version>" on stdout.
# Returns:
#   1 when the tag is not of the form script-name-vX.Y.Z.
#######################################
parse_tag() {
  local tag="$1"
  if [[ ! "${tag}" =~ ^([a-zA-Z0-9_-]+)-v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    log_error "Tag format is invalid. Expected 'script-name-vX.Y.Z', got '${tag}'."
    return 1
  fi
  printf '%s v%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

#######################################
# Packages one script and uploads its tarball to the release.
#
# A missing tarball is not an error: a Homebrew-only or Debian-only entry still packages, and the upload
# is skipped rather than failing the run.
# Globals:
#   PACKAGER, REPO_ROOT
# Arguments:
#   name, version, tag.
# Returns:
#   Whatever the packager returns.
#######################################
package_and_upload() {
  local name="$1" version="$2" tag="$3"

  log_info "Packaging ${name} ${version}"
  # Both of these write to stdout — dpkg-deb announces the package it builds, gh reports the upload — and
  # this function's stdout is the commit message, captured by the caller. Sent to stderr so the message
  # stays one line: a multi-line value is what $GITHUB_OUTPUT rejects, which skips both downstream pushes.
  "${PACKAGER}" "${name}" "${version}" >&2

  local tarball="${REPO_ROOT}/dist/tarballs/scripts-${name}-${version}.tar.gz"
  if [[ -f "${tarball}" ]]; then
    log_info "Uploading $(basename "${tarball}") to ${tag}"
    gh release upload "${tag}" "${tarball}" --clobber >&2
  else
    log_info "No tarball for ${name} ${version}; nothing to upload."
  fi
}

#######################################
# Packages the single script a release tag names.
# Arguments:
#   tag: The release tag.
# Outputs:
#   The commit message on stdout.
#######################################
release_one() {
  local tag="$1"
  local parsed name version
  # Tested rather than left to errexit: this function's own output is captured by a command substitution
  # in main, and inside one of those a failing `x=$(...)` does not abort — so an invalid tag would carry
  # on with an empty name and package nothing under a nonsense commit message.
  if ! parsed=$(parse_tag "${tag}"); then
    return 1
  fi
  read -r name version <<<"${parsed}"

  package_and_upload "${name}" "${version}" "${tag}"
  printf 'feat(%s): Release version %s\n' "${name}" "${version}"
}

#######################################
# Packages the latest tagged version of every script in the manifest.
#
# A script with no version tags is skipped rather than packaged at some invented version: there is no
# release to upload its tarball to.
# Globals:
#   MANIFEST, REPO_ROOT
# Outputs:
#   The commit message on stdout.
#######################################
republish_all() {
  local name latest_tag version
  while IFS= read -r name; do
    latest_tag=$(git -C "${REPO_ROOT}" tag --list "${name}-v*" --sort=-v:refname | head -n 1)
    if [[ -z "${latest_tag}" ]]; then
      log_info "Skipping ${name}: no version tags found."
      continue
    fi

    version="v${latest_tag##*-v}"
    package_and_upload "${name}" "${version}" "${latest_tag}"
  done < <(yq eval '.scripts | keys | .[]' "${MANIFEST}")

  printf 'chore: Republish latest version of all scripts\n'
}

#######################################
# Parses arguments, packages, and reports the commit message.
# Globals:
#   GITHUB_OUTPUT
# Arguments:
#   See show_usage.
#######################################
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
  fi

  local mode="${1:-}"
  local message

  case "${mode}" in
    release)
      if (( $# < 2 )); then
        log_error "release requires a tag."
        show_usage >&2
        exit 1
      fi
      if ! message=$(release_one "$2"); then
        exit 1
      fi
      ;;
    republish-all | workflow_dispatch)
      if ! message=$(republish_all); then
        exit 1
      fi
      ;;
    *)
      log_error "Unknown mode '${mode}'. Expected 'release', 'republish-all' or 'workflow_dispatch'."
      show_usage >&2
      exit 1
      ;;
  esac

  # A message that picked up a stray line would be written as a multi-line value, which $GITHUB_OUTPUT
  # rejects — and the two downstream pushes are skipped when that output is empty, so the failure is a
  # release that packages and then publishes nowhere. Refused here instead, where it names the cause.
  if [[ "${message}" != "${message%%$'\n'*}" ]]; then
    log_error "The commit message is not a single line; something wrote to stdout:"
    printf '%s\n' "${message}" >&2
    exit 1
  fi

  printf '%s\n' "${message}"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'commit_message=%s\n' "${message}" >> "${GITHUB_OUTPUT}"
  fi
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

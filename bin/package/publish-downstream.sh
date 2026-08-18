#!/usr/bin/env bash
#
# Copies freshly packaged artefacts into a downstream repository, regenerates what is derived from them,
# and pushes — retrying against a moving remote.
#
# Both downstream repositories need the same sequence, so it lives here once rather than twice in
# publish.yml, where 49 lines of it could only be exercised by cutting a release. The Homebrew tap takes
# formulas; the APT repository takes .debs and additionally needs its package index rebuilt and signed.
#
# Why fetch-reset rather than rebase: when several releases are published at once, parallel workflow runs
# all push to the same repository, and every generated file (a formula, the APT index) conflicts on a
# rebase. Each attempt therefore starts from the remote's current state and regenerates from the full
# repository contents plus the new artefacts, which cannot conflict. Artefacts are copied rather than
# moved so they survive into the next attempt.
#
# Usage:
#   ./publish-downstream.sh <homebrew|apt> <checkout-dir> <commit-message> [options]
#
# Arguments:
#   channel        homebrew or apt.
#   checkout-dir   The downstream repository's working copy.
#   commit-message The message to commit with.
#
# Options:
#   --attempts N   How many times to try the fetch-regenerate-push cycle (default 10).
#   --dry-run      Do everything except push, so the sequence can be exercised without a remote.
#
# Environment (apt only):
#   GPG_PRIVATE_KEY, GPG_PASSPHRASE   Imported once, before the retry loop, and used to sign the release.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
GENERATOR="${SCRIPT_DIR}/../docs/update-readme-index.sh"

#######################################
# Prints usage instructions to stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: $(basename "$0") <homebrew|apt> <checkout-dir> <commit-message> [options]

Options:
  --attempts N   Retry the fetch-regenerate-push cycle N times (default 10).
  --dry-run      Do everything except push.
  -h             Show this help message.
EOF
}

#######################################
# Copies the packaged formulas in and regenerates the tap's index.
#
# A Debian-only release produces no formula, so the copy is skipped rather than failing: the run still
# regenerates the index, which is derived from the whole Formula/ directory.
# Globals:
#   REPO_ROOT, GENERATOR
# Arguments:
#   checkout: The tap's working copy.
#######################################
refresh_homebrew() {
  local checkout="$1"

  if compgen -G "${REPO_ROOT}/dist/homebrew/*.rb" > /dev/null; then
    cp "${REPO_ROOT}"/dist/homebrew/*.rb "${checkout}/Formula/"
  else
    log_info "No formulas to copy."
  fi

  ( cd "${checkout}" && "${GENERATOR}" README.md )
}

#######################################
# Copies the packaged .debs in, rebuilds the APT index, signs it, and regenerates the repository's index.
#
# The Release file is removed before being regenerated, or it would contribute its own checksum to itself.
# An empty one is fatal: apt clients reject the repository, and a signed empty Release is worse than a
# failed publish.
# Globals:
#   REPO_ROOT, GENERATOR, GPG_PASSPHRASE
# Arguments:
#   checkout: The APT repository's working copy.
# Returns:
#   1 when the Release file comes out empty.
#######################################
refresh_apt() {
  local checkout="$1"

  if compgen -G "${REPO_ROOT}/dist/debian/*.deb" > /dev/null; then
    cp "${REPO_ROOT}"/dist/debian/*.deb "${checkout}/pool/main/"
  else
    log_info "No .deb packages to copy."
  fi

  (
    cd "${checkout}"
    apt-ftparchive packages pool/ > dists/stable/main/binary-all/Packages
    gzip -c dists/stable/main/binary-all/Packages > dists/stable/main/binary-all/Packages.gz

    rm -f dists/stable/Release dists/stable/InRelease
    apt-ftparchive -c apt-ftparchive.conf release dists/stable/ > dists/stable/Release
    if [[ ! -s dists/stable/Release ]]; then
      log_error "Failed to generate a valid Release file."
      exit 1
    fi

    gpg --batch --pinentry-mode loopback --passphrase "${GPG_PASSPHRASE:-}" \
      --default-key "jmerhar-bot" --clearsign -o dists/stable/InRelease dists/stable/Release

    "${GENERATOR}" README.md
  )
}

#######################################
# Imports the signing key, once, before the retry loop.
# Globals:
#   GPG_PRIVATE_KEY, GPG_PASSPHRASE
#######################################
import_signing_key() {
  if [[ -z "${GPG_PRIVATE_KEY:-}" ]]; then
    log_info "No GPG_PRIVATE_KEY set; skipping key import."
    return
  fi
  printf '%s' "${GPG_PRIVATE_KEY}" | gpg --batch --import --passphrase "${GPG_PASSPHRASE:-}"
}

#######################################
# Runs the fetch-regenerate-commit-push cycle until it succeeds or the attempts run out.
# Globals:
#   None
# Arguments:
#   channel, checkout, message, attempts, dry_run.
# Returns:
#   0 when a push succeeded or there was nothing to commit; 1 when every attempt failed.
#######################################
publish() {
  local channel="$1" checkout="$2" message="$3" attempts="$4" dry_run="$5"
  local attempt

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    log_info "Attempt ${attempt}/${attempts} in ${checkout}"

    # A fetch or reset that fails is retried rather than fatal: the remote may be briefly unavailable, and
    # the point of the loop is to survive that. A permanently broken remote exhausts the attempts and gets
    # the clearer "gave up" message instead of a raw git error.
    if ! git -C "${checkout}" fetch origin; then
      log_info "Fetch failed (attempt ${attempt}/${attempts}); retrying."
      continue
    fi
    if ! git -C "${checkout}" reset --hard origin/main; then
      log_info "Reset failed (attempt ${attempt}/${attempts}); retrying."
      continue
    fi

    case "${channel}" in
      homebrew) refresh_homebrew "${checkout}" ;;
      apt)      refresh_apt "${checkout}" ;;
    esac

    git -C "${checkout}" add .
    if ! git -C "${checkout}" commit -m "${message}"; then
      log_info "Nothing to commit; the downstream repository is already current."
      return 0
    fi

    if [[ "${dry_run}" == true ]]; then
      log_info "Dry run: not pushing."
      return 0
    fi

    if git -C "${checkout}" push; then
      return 0
    fi
    log_info "Push failed (attempt ${attempt}/${attempts}); retrying."
  done

  log_error "Gave up after ${attempts} attempts pushing to ${checkout}."
  return 1
}

#######################################
# Parses arguments and publishes.
# Arguments:
#   See show_usage.
#######################################
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
  fi

  if (( $# < 3 )); then
    log_error "Expected a channel, a checkout directory and a commit message."
    show_usage >&2
    exit 1
  fi

  local channel="$1" checkout="$2" message="$3"
  shift 3

  local attempts=10 dry_run=false
  while (( $# > 0 )); do
    case "$1" in
      --attempts)
        if (( $# < 2 )); then log_error "--attempts requires a number."; exit 1; fi
        attempts="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) log_error "Unknown option '$1'."; show_usage >&2; exit 1 ;;
    esac
  done

  case "${channel}" in
    homebrew | apt) ;;
    *) log_error "Unknown channel '${channel}'. Expected 'homebrew' or 'apt'."; exit 1 ;;
  esac

  if [[ ! -d "${checkout}" ]]; then
    log_error "Checkout directory not found: ${checkout}"
    exit 1
  fi

  if [[ ! "${attempts}" =~ ^[0-9]+$ ]] || (( attempts < 1 )); then
    log_error "--attempts must be a positive integer, got '${attempts}'."
    exit 1
  fi

  if [[ "${channel}" == apt ]]; then
    import_signing_key
  fi

  publish "${channel}" "${checkout}" "${message}" "${attempts}" "${dry_run}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

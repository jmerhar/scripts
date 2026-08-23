#!/usr/bin/env bash
#
# Provisions the kcov container and runs the bats suite inside it.
#
# The container side of bin/coverage/run-coverage.sh, which mounts the repository at /src and invokes
# this. A file rather than a string passed to `bash -c`: the provisioning is twenty lines of shell with
# its own reasoning to record, and inside a quoted argument none of it can be linted by ShellCheck,
# indented for reading, or commented without the comment ending up in the wrong shell. It also cannot
# hold an apostrophe without the '"'"' dance, which is how a note about mikefarah came to be written
# three quotes deep.
#
# Expects the repository at /src and reads BATS_VERSION, YQ_VERSION and JUNIT_DIR from the environment,
# which run-coverage.sh passes through so both sides agree on the pinned versions.
#
# Usage: bash /src/bin/coverage/in-container.sh
#
# Guarded at the bottom so the test suite can source it and call one function at a time; unguarded, a
# source would apt-get its way through a developer machine.

set -o errexit
set -o nounset
set -o pipefail

# Every path this writes to is a seam, and that is a safety mechanism rather than a convenience: the
# defaults are a container's own filesystem, so a test that ran the real steps against them would install
# into the developer's /usr/local and extract into their /tmp. One did, before these existed.
#
# bats is a seam for a different reason — it cannot be stubbed on PATH under its own name, since the
# coverage harness tracing the test would pick that up instead of the real one.
: "${SRC:=/src}"
: "${TMP:=/tmp}"
: "${PREFIX:=/usr/local}"
: "${BATS_BIN:=bats}"
readonly SRC TMP PREFIX BATS_BIN

# wget fetches bats and yq; the rest are what the scripts under test shell out to, and a suite covering a
# script that needs one fails for want of the tool rather than for a fault in the code. Keep this in step
# with what the suites exercise.
#
# procps is for bats, not for the scripts: its per-test timeout shells out to ps/pkill, and without them
# every test in a file that sets BATS_TEST_TIMEOUT aborts with "Cannot execute timeout".
#
# git is for the release suites: they drive real repositories rather than stubbing git, because what they
# check is that a fetch-reset really discards a failed commit and a rejected push really retries.
readonly PACKAGES=(wget libxml2-utils zip unzip jq procps git)

#######################################
# Installs the packages the suites need.
#######################################
install_packages() {
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PACKAGES[@]}" >/dev/null
}

#######################################
# Installs bats from source at the pinned version.
#
# Not the distribution package: Debian ships 1.8, which predates BATS_TEST_TIMEOUT, so a suite bounding a
# test to turn a runaway loop into a failure would silently have no bound here while having one locally.
# Globals:
#   BATS_VERSION, TMP, PREFIX
#######################################
install_bats() {
  wget -qO "${TMP}/bats.tar.gz" "https://github.com/bats-core/bats-core/archive/refs/tags/${BATS_VERSION}.tar.gz"
  tar -xzf "${TMP}/bats.tar.gz" -C "${TMP}"
  "${TMP}/bats-core-${BATS_VERSION#v}/install.sh" "${PREFIX}" >/dev/null
}

#######################################
# Installs mikefarah's yq at the pinned version.
#
# The distribution package named yq is the Python jq wrapper, which does not speak the v4 expressions the
# packaging scripts use — so it is fetched rather than installed, at the version the workflows pin.
# Globals:
#   YQ_VERSION, PREFIX
#######################################
install_yq() {
  wget -qO "${PREFIX}/bin/yq" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_$(dpkg --print-architecture)"
  chmod +x "${PREFIX}/bin/yq"
}

#######################################
# Runs the suite under kcov and leaves its output readable outside the container.
#
# The container runs as root, so what it writes into the mounted tree would otherwise be unreadable to
# the host user and to the CI steps that publish it.
# Globals:
#   JUNIT_DIR
#######################################
run_suite() {
  local report=()
  if [[ -n "${JUNIT_DIR:-}" ]]; then
    report=(--report-formatter junit --output "${SRC}/${JUNIT_DIR}")
  fi

  COVERAGE_DIR="${SRC}/coverage" ${BATS_BIN} --recursive "${report[@]}" test/

  chmod -R a+rX "${SRC}/coverage"
  if [[ -n "${JUNIT_DIR:-}" ]]; then
    chmod -R a+rX "${SRC}/${JUNIT_DIR}"
  fi
}

# Guarded so the suite can source this file and exercise one step at a time.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_packages
  install_bats
  install_yq
  run_suite
fi

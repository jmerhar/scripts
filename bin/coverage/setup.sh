#!/usr/bin/env bash
#
# Installs the pinned bats and yq in the kcov container, before the suite runs there.
#
# Named as the `setup` of the scripts suite in coverage.toml, so jmerhar/coverage's run-kcov.sh runs it
# inside the container after installing that suite's apt `packages` (wget among them, which this needs).
# A local run never calls it: there, the bats and yq on PATH are used.
#
# Usage: bash bin/coverage/setup.sh
#
# Guarded at the bottom so the test suite can source it and call one function at a time; unguarded, a
# source would install into the developer's machine.

set -o errexit
set -o nounset
set -o pipefail

# Every path this writes to is a seam, and that is a safety mechanism rather than a convenience: the
# defaults are a container's own filesystem, so a test that ran the real steps against them would install
# into the developer's /usr/local and extract into their /tmp. One did, before these existed.
: "${TMP:=/tmp}"
: "${PREFIX:=/usr/local}"
readonly TMP PREFIX

# Debian's bats is 1.8, which predates BATS_TEST_TIMEOUT (added in 1.9). A suite that bounds a test to turn
# a runaway loop into a failure would silently have no bound there, so bats is installed from source at the
# version a local run and the macOS job use — all three then behave the same.
#
# Normalised to a leading v, which the release tags carry, because bats exports BATS_VERSION itself: run
# from inside a suite — as this script's own tests do — the value is whatever the outer bats is, without
# the prefix, and the archive URL built from it is a 404 rather than an error that says so.
BATS_VERSION=${BATS_VERSION:-v1.14.0}
BATS_VERSION="v${BATS_VERSION#v}"

# The packaging scripts need mikefarah's yq, pinned to the version the workflows install so a figure
# measured here matches one measured there.
YQ_VERSION=${YQ_VERSION:-v4.52.4}

#######################################
# Installs bats from source at the pinned version.
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

# Guarded so the suite can source this file and exercise one step at a time.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_bats
  install_yq
fi

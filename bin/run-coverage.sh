#!/usr/bin/env bash
#
# Run the bats suite under kcov and leave a merged report in coverage/.
#
# kcov is applied per invocation from the test helper rather than wrapped around bats: running kcov over
# bats collects nothing, because bats executes the code under test in grandchild processes (kcov issue
# #462). test/test_helper.bash notices COVERAGE_DIR and traces each invocation, and kcov accumulates
# into one output directory, writing a merged report beside one report per traced invocation. Only the
# merged report is published; the per-invocation ones each list every file while crediting a single
# run's hits, so they read as wrong.
#
# Two kcov requirements are easy to get wrong: the target must be the *script*, never `bash script`,
# which instruments the bash binary instead; and the default PS4 collection method must be used, since
# --bash-method=DEBUG measures nothing here.
#
# Function-level tests need a harness. `bash -c 'source …'` sets $0 correctly but cannot be traced —
# kcov's prologue reads BASH_SOURCE, unset inside a -c string, so a script under `set -o nounset` dies
# before its function runs. A harness that kcov executes directly works, provided it sits beside the
# script, so the library path the script derives from $(dirname "$0") still resolves. This writes one
# into each directory holding a script, and removes them on exit.
#
# kcov is not packaged for Ubuntu 24.04 (its Debian package was dropped over an FTBFS with GCC 15), so
# CI uses the upstream image. A locally installed kcov is preferred because it avoids the container
# round-trip; both produce identical figures.
#
# Usage: bin/run-coverage.sh
#   JUNIT_DIR=junit          also write bats's JUnit report there, for Codecov's test analytics
#   KCOV_FORCE_DOCKER=1      exercise the container path even with a local toolchain

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${HERE}/.." && pwd -P)"

# Pinned by digest so the reported percentage cannot drift when the tag moves. Image: kcov/kcov
# v44-pre-test3; update deliberately, then re-check the gate in coverage.toml.
KCOV_IMAGE=${KCOV_IMAGE:-kcov/kcov@sha256:481289ae32e55e5b733019515acd10948a4f76dfed381765577db909664fc603}

# The packaging scripts need mikefarah's yq, pinned to the version the workflows install so a figure
# measured here matches one measured there.
YQ_VERSION=${YQ_VERSION:-v4.52.4}
export YQ_VERSION

# Debian's bats is 1.8, which predates BATS_TEST_TIMEOUT (added in 1.9). A suite that bounds a test to turn
# a runaway loop into a failure would silently have no bound there, so bats is installed from source at the
# version a local run and the macOS job use — all three then behave the same.
BATS_VERSION=${BATS_VERSION:-v1.14.0}
export BATS_VERSION

COVERAGE_HARNESS_NAME="_coverage-harness"
export COVERAGE_HARNESS_NAME

cd "${ROOT}"

#######################################
# Removes the sourcing harnesses the test helper wrote beside the scripts.
# The helper creates them on demand — it also needs them beside tool copies in fixture trees — and this
# is what guarantees none survive the run.
# Globals:
#   ROOT, COVERAGE_HARNESS_NAME
#######################################
remove_harnesses() {
  find "${ROOT}/scripts" "${ROOT}/bin" -name "${COVERAGE_HARNESS_NAME}" -delete 2>/dev/null || true
}

#######################################
# Reports whether a locally installed kcov runs the scripts under a bash new enough for them.
# kcov's macOS build ignores the shebang and execs /bin/bash, which there is 3.2 — and eight of these
# scripts use case conversion, associative arrays, mapfile or namerefs, so they fail on it in ways that
# look like test failures rather than a toolchain problem. Probed rather than assumed from the platform,
# so a fixed kcov or an unusual box is judged on what it actually does.
# Returns:
#   0 when kcov runs bash 4 or newer, 1 otherwise.
#######################################
local_kcov_runs_modern_bash() {
  local probe_dir probe out
  probe_dir="$(mktemp -d)"
  probe="${probe_dir}/probe.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s" "${BASH_VERSINFO[0]}"\n' > "${probe}"
  chmod +x "${probe}"
  out="$(kcov --include-path="${probe}" "${probe_dir}/out" "${probe}" 2>/dev/null || true)"
  rm -rf "${probe_dir}"
  [[ "${out}" =~ ^[0-9]+$ ]] && (( out >= 4 ))
}

rm -rf coverage
trap remove_harnesses EXIT
remove_harnesses

# bats writes a JUnit report when asked, which is what Codecov's test analytics reads. Its flags take a
# directory, so JUNIT_DIR is passed through as one; without it nothing extra is written.
bats_report=()
if [[ -n "${JUNIT_DIR:-}" ]]; then
  case "${JUNIT_DIR}" in
    /*) echo "run-coverage: JUNIT_DIR must be repo-relative" >&2; exit 2 ;;
  esac
  mkdir -p "${JUNIT_DIR}"
  bats_report=(--report-formatter junit --output "${JUNIT_DIR}")
fi

# Prefer the local toolchain when it is complete and usable. KCOV_FORCE_DOCKER exercises the container
# path without pruning PATH to hide kcov, which would also hide python3 and everything else Homebrew
# provides and make the run fail somewhere unrelated.
use_local=false
if [[ -z "${KCOV_FORCE_DOCKER:-}" ]] && command -v kcov &>/dev/null && command -v bats &>/dev/null; then
  if local_kcov_runs_modern_bash; then
    use_local=true
  else
    echo "The local kcov runs the scripts under bash 3.x, which most of them cannot use." >&2
  fi
fi

if [[ "${use_local}" == true ]]; then
  echo "Running the suite under the locally installed kcov …"
  COVERAGE_DIR="${ROOT}/coverage" bats --recursive "${bats_report[@]}" test/
else
  if [[ -n "${KCOV_FORCE_DOCKER:-}" ]]; then
    echo "KCOV_FORCE_DOCKER is set; running the suite in ${KCOV_IMAGE} …"
  else
    echo "Running the suite in ${KCOV_IMAGE} …"
  fi
  docker run --rm -v "${ROOT}":/src -w /src \
    -e "JUNIT_DIR=${JUNIT_DIR:-}" -e "COVERAGE_HARNESS_NAME=${COVERAGE_HARNESS_NAME}" \
    -e "YQ_VERSION=${YQ_VERSION}" -e "BATS_VERSION=${BATS_VERSION}" \
    --entrypoint bash "${KCOV_IMAGE}" -c '
    set -euo pipefail
    apt-get update -qq >/dev/null
    # wget fetches bats and yq; the rest are what the scripts under test shell out to, and a suite covering
    # a script that needs one fails for want of the tool rather than for a fault in the code. Keep this in
    # step with what the suites exercise.
    # procps is for bats, not for the scripts: its per-test timeout shells out to ps/pkill, and without
    # them every test in a file that sets BATS_TEST_TIMEOUT aborts with "Cannot execute timeout".
    packages="wget libxml2-utils zip unzip jq procps"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $packages >/dev/null
    # Not the distribution package: see the BATS_VERSION note above.
    wget -qO /tmp/bats.tar.gz \
      "https://github.com/bats-core/bats-core/archive/refs/tags/${BATS_VERSION}.tar.gz"
    tar -xzf /tmp/bats.tar.gz -C /tmp
    "/tmp/bats-core-${BATS_VERSION#v}/install.sh" /usr/local >/dev/null
    # Distribution "yq" is the Python jq wrapper, which does not speak the v4 expressions the packaging
    # scripts use, so mikefarah'"'"'s build is fetched at the version the workflows pin.
    wget -qO /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_$(dpkg --print-architecture)"
    chmod +x /usr/local/bin/yq
    report=()
    if [ -n "$JUNIT_DIR" ]; then report=(--report-formatter junit --output "/src/$JUNIT_DIR"); fi
    COVERAGE_DIR=/src/coverage bats --recursive "${report[@]}" test/
    # The container runs as root; keep what it wrote readable by the host user and later CI steps.
    chmod -R a+rX /src/coverage
    if [ -n "$JUNIT_DIR" ]; then chmod -R a+rX "/src/$JUNIT_DIR"; fi
  '
fi

if [[ ! -f coverage/kcov-merged/coverage.json ]]; then
  echo "run-coverage: kcov produced no merged report in coverage/" >&2
  exit 1
fi
echo "Coverage in coverage/kcov-merged/"

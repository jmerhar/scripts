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
# round-trip; both produce identical figures. What runs inside the container is
# bin/coverage/in-container.sh, invoked through the mount.
#
# Both files are measured like anything else under bin/. kcov reports only what it observes running, so
# they appear because test/bin/run-coverage.bats and test/bin/in-container.bats drive them — through the
# seams below, never the real kcov, bats or docker.
#
# Usage: bin/coverage/run-coverage.sh
#   JUNIT_DIR=junit          also write bats's JUnit report there, for Codecov's test analytics
#   KCOV_FORCE_DOCKER=1      exercise the container path even with a local toolchain

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
readonly ROOT="${REPO_ROOT}"

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
#
# Normalised to a leading v, which the release tags carry, because bats exports BATS_VERSION itself: run
# from inside a suite — as this script's own tests do — the value is whatever the outer bats is, without
# the prefix, and the archive URL built from it is a 404 rather than an error that says so.
BATS_VERSION=${BATS_VERSION:-v1.14.0}
BATS_VERSION="v${BATS_VERSION#v}"
export BATS_VERSION

COVERAGE_HARNESS_NAME="_coverage-harness"
export COVERAGE_HARNESS_NAME

# The three tools this decides between, named through the environment so a test can hand it doubles. They
# cannot be stubbed on PATH under the names they really have: a `kcov` or `bats` earlier on PATH would be
# picked up by the coverage harness tracing the test, and a `docker` would be handed to
# ufw-docker-expose's suite, which runs the real CLI against pinned images.
: "${KCOV_BIN:=kcov}"
: "${BATS_BIN:=bats}"
: "${DOCKER_BIN:=docker}"
readonly KCOV_BIN BATS_BIN DOCKER_BIN

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
  out="$(${KCOV_BIN} --include-path="${probe}" "${probe_dir}/out" "${probe}" 2>/dev/null || true)"
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
if [[ -z "${KCOV_FORCE_DOCKER:-}" ]] && command -v "${KCOV_BIN}" &>/dev/null && command -v "${BATS_BIN}" &>/dev/null; then
  if local_kcov_runs_modern_bash; then
    use_local=true
  else
    echo "The local kcov runs the scripts under bash 3.x, which most of them cannot use." >&2
  fi
fi

if [[ "${use_local}" == true ]]; then
  echo "Running the suite under the locally installed kcov …"
  COVERAGE_DIR="${ROOT}/coverage" ${BATS_BIN} --recursive "${bats_report[@]}" test/
else
  if [[ -n "${KCOV_FORCE_DOCKER:-}" ]]; then
    echo "KCOV_FORCE_DOCKER is set; running the suite in ${KCOV_IMAGE} …"
  else
    echo "Running the suite in ${KCOV_IMAGE} …"
  fi
  # Assembled as an array rather than one command: every -e is a decision with a reason, and a run of
  # them wrapped across continuations hides the lines it spans from kcov as well as from a reader.
  docker_args=(run --rm)
  docker_args+=(-v "${ROOT}:/src" -w /src)
  docker_args+=(-e "JUNIT_DIR=${JUNIT_DIR:-}")
  docker_args+=(-e "COVERAGE_HARNESS_NAME=${COVERAGE_HARNESS_NAME}")
  docker_args+=(-e "YQ_VERSION=${YQ_VERSION}")
  docker_args+=(-e "BATS_VERSION=${BATS_VERSION}")
  docker_args+=(--entrypoint bash "${KCOV_IMAGE}")
  # Invoked through the mount rather than passed as a -c string, so the provisioning is a file that
  # ShellCheck reads, a test can source, and a comment can be written in.
  docker_args+=(/src/bin/coverage/in-container.sh)
  ${DOCKER_BIN} "${docker_args[@]}"
fi

if [[ ! -f coverage/kcov-merged/coverage.json ]]; then
  echo "run-coverage: kcov produced no merged report in coverage/" >&2
  exit 1
fi
echo "Coverage in coverage/kcov-merged/"

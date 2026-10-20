#!/usr/bin/env bash
#
# Runs the bats suite for a coverage measurement, and removes the sourcing harnesses the test helper
# writes beside the scripts while measuring.
#
# The `command` of the scripts suite in coverage.toml: jmerhar/coverage's run-kcov.sh runs it with
# COVERAGE_DIR set, locally or in the kcov container. kcov is applied per invocation by
# test/test_helper.bash rather than wrapped around bats, because bats executes the code under test in
# grandchild processes and kcov over bats collects nothing (kcov issue #462).
#
# Function-level tests need a harness. `bash -c 'source …'` sets $0 correctly but cannot be traced —
# kcov's prologue reads BASH_SOURCE, unset inside a -c string, so a script under `set -o nounset` dies
# before its function runs. A harness that kcov executes directly works, provided it sits beside the
# script, so the library path the script derives from $(dirname "$0") still resolves. The test helper
# writes one on demand into each directory holding a script it traces; this removes them on exit.
#
# Usage: bin/coverage/measure.sh
#   JUNIT_DIR=junit   also write bats's JUnit report there, for Codecov's test analytics

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
readonly ROOT="${REPO_ROOT}"

# bats is named through the environment so a test can hand it a double: a stub named bats on PATH would be
# picked up by the coverage harness tracing that very test.
: "${BATS_BIN:=bats}"
readonly BATS_BIN

COVERAGE_HARNESS_NAME="_coverage-harness"
export COVERAGE_HARNESS_NAME

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

cd "${ROOT}"
trap remove_harnesses EXIT
remove_harnesses

report=()
if [[ -n "${JUNIT_DIR:-}" ]]; then
  report=(--report-formatter junit --output "${JUNIT_DIR}")
fi

${BATS_BIN} --recursive "${report[@]}" test/

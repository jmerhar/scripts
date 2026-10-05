#!/usr/bin/env bats
#
# run-suite.sh decides how the suite is run, and the two ways that decision can be wrong are both silent.
# A run that lost its parallelism because an optional dependency went missing looks like a slow machine,
# and a gate run that differs from CI by one environment variable looks like a flaky test. So the job
# count and the environment are both asserted rather than trusted.
#
# bats and parallel are reached through the BATS_BIN and PARALLEL_BIN seams. Neither can be doubled on
# PATH under its real name: a `bats` there is picked up by the very suite running these tests, and a
# `parallel` there would change how that suite runs.

load ../test_helper

setup() {
  setup_common
  fake_repo_tool run-suite.sh
  mkdir -p "$FAKE_REPO/test"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"

  export BATS_BIN="$BIN/bats-double"
  double_at "$BATS_BIN"

  # Absent by default, so the serial fallback is what a test gets unless it asks for parallel.
  export PARALLEL_BIN="$BIN/parallel-missing"

  # Pinned so a test asserts on a decision rather than on however many cores this machine has.
  export JOBS=""

  # The coverage entry point exports this into every test, so a test asserting on its absence would
  # otherwise be asserting about the runner.
  unset JUNIT_DIR GITHUB_ACTIONS GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
}

########################################
# Writes a double that records its argv and the environment variables under test.
# Arguments:
#   path: Where to write it.
#   status: Exit status it should return (default 0).
########################################
double_at() {
  cat > "$1" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$1")" "\$*" >> "${CALLS}"
printf 'env GITHUB_ACTIONS=%s GIT_CONFIG_COUNT=%s GIT_CONFIG_VALUE_0=%s JUNIT_DIR=%s\n' \
  "\${GITHUB_ACTIONS:-}" "\${GIT_CONFIG_COUNT:-}" "\${GIT_CONFIG_VALUE_0:-}" "\${JUNIT_DIR:-}" >> "${CALLS}"
exit ${2:-0}
STUB
  chmod +x "$1"
}

########################################
# Makes GNU parallel look installed.
########################################
parallel_present() {
  export PARALLEL_BIN="$BIN/parallel-double"
  double_at "$PARALLEL_BIN"
}

# --- Choosing the job count ---------------------------------------------------------------------

@test "with GNU parallel present the probed core count is used without being asked" {
  parallel_present
  JOBS=6 run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  grep -q -- 'bats-double .*--jobs 6' "$CALLS"
  [[ "$output" == *"with 6 jobs"* ]]
}

# The probe itself, rather than the seam that pins it: without this the getconf call is never run by
# any test, and a machine that reported nothing would fall back silently.
@test "the core count is read from the machine when nothing pins it" {
  local cores
  cores="$(getconf _NPROCESSORS_ONLN)"
  (( cores > 1 )) || skip "needs more than one core to distinguish from serial"
  parallel_present
  unset JOBS
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  grep -q -- "bats-double .*--jobs ${cores}" "$CALLS"
}

# The suite still has to run; losing the parallelism is a slower run, not a failure.
@test "without GNU parallel the suite runs serially and says so" {
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  run bash -c "grep -c -- '--jobs' '$CALLS' || true"
  [ "$output" = "0" ]
}

@test "without GNU parallel the reason is reported rather than left to be guessed at" {
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GNU parallel is not installed"* ]]
  [[ "$output" == *"one test at a time"* ]]
}

@test "an explicit --jobs overrides the detected count" {
  parallel_present
  JOBS=6 run_script "$FAKE_TOOL" --jobs 3
  [ "$status" -eq 0 ]
  grep -q -- 'bats-double .*--jobs 3' "$CALLS"
}

@test "--jobs 1 runs serially without asking bats for parallelism" {
  parallel_present
  run_script "$FAKE_TOOL" --jobs 1
  [ "$status" -eq 0 ]
  run bash -c "grep -c -- '--jobs' '$CALLS' || true"
  [ "$output" = "0" ]
}

# Asked for parallelism that cannot be delivered, the difference is announced rather than absorbed.
@test "--jobs above one without GNU parallel warns and falls back to serial" {
  run_script "$FAKE_TOOL" --jobs 4
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot be honoured"* ]]
  run bash -c "grep -c -- '--jobs' '$CALLS' || true"
  [ "$output" = "0" ]
}

@test "a job count that is not a positive number is refused" {
  run_script "$FAKE_TOOL" --jobs 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive whole number"* ]]
  run_script "$FAKE_TOOL" --jobs two
  [ "$status" -eq 1 ]
}

@test "--jobs without a value is refused" {
  run_script "$FAKE_TOOL" --jobs
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an argument"* ]]
}

# --- The CI environment -------------------------------------------------------------------------

@test "--ci applies every variable the runners set" {
  run_script "$FAKE_TOOL" --ci
  [ "$status" -eq 0 ]
  grep -q 'env GITHUB_ACTIONS=true GIT_CONFIG_COUNT=1 GIT_CONFIG_VALUE_0=master JUNIT_DIR=junit' "$CALLS"
}

@test "without --ci none of those variables is set" {
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  grep -q 'env GITHUB_ACTIONS= GIT_CONFIG_COUNT= GIT_CONFIG_VALUE_0= JUNIT_DIR=' "$CALLS"
}

@test "--ci keeps a JUNIT_DIR the caller already chose" {
  JUNIT_DIR=elsewhere run_script "$FAKE_TOOL" --ci
  [ "$status" -eq 0 ]
  grep -q 'JUNIT_DIR=elsewhere' "$CALLS"
}

# --- What gets run ------------------------------------------------------------------------------

@test "the whole test tree is run by default, recursively" {
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  grep -q -- 'bats-double --recursive --print-output-on-failure test/' "$CALLS"
}

# bats does not recurse by default and the suites are grouped in subdirectories, so a run without it
# would silently cover only part of the tree.
@test "--recursive is always passed" {
  parallel_present
  JOBS=2 run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  grep -q -- 'bats-double --recursive' "$CALLS"
}

# A failure whose output is not shown costs another run to diagnose.
@test "a failing test's output is printed" {
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  grep -q -- '--print-output-on-failure' "$CALLS"
}

@test "a path argument narrows the run" {
  run_script "$FAKE_TOOL" test/scripts/unlock-pdf.bats
  [ "$status" -eq 0 ]
  grep -q -- 'bats-double .*test/scripts/unlock-pdf.bats' "$CALLS"
}

@test "more than one path argument is refused" {
  run_script "$FAKE_TOOL" one two
  [ "$status" -eq 1 ]
  [[ "$output" == *"at most one path"* ]]
}

@test "an unknown option is refused with the usage" {
  run_script "$FAKE_TOOL" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
  [[ "$output" == *"Usage:"* ]]
}

# The gate's exit status is bats's own, or a red suite would report success.
@test "bats's exit status is propagated" {
  double_at "$BATS_BIN" 1
  run_script "$FAKE_TOOL"
  [ "$status" -eq 1 ]
}

@test "--help prints the usage and exits cleanly" {
  run_script "$FAKE_TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: run-suite.sh"* ]]
  [[ "$output" == *"GNU parallel is an optional dependency"* ]]
  run bash -c "grep -c 'bats-double' '$CALLS' || true"
  [ "$output" = "0" ]
}

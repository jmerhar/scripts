#!/usr/bin/env bats
#
# measure.sh is the command jmerhar/coverage's run-kcov.sh runs to measure the suite: it runs bats from the
# repository root and removes the sourcing harnesses the test helper leaves beside the scripts. A harness
# that survived would be committed, and a run that did not reach bats would produce no measurement.
#
# bats is reached through the BATS_BIN seam: a stub named bats on PATH would be picked up by the coverage
# harness tracing these very tests. Every test drives the tool inside the fake repository, since it
# deletes files relative to its own location.

load ../test_helper

setup() {
  setup_common
  fake_repo_tool measure.sh
  mkdir -p "$FAKE_REPO/test" "$FAKE_REPO/scripts"

  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  export BATS_BIN="$BATS_TEST_TMPDIR/bats-double"
  cat > "$BATS_BIN" <<STUB
#!/usr/bin/env bash
printf 'bats-double %s\n' "\$*" >> "${CALLS}"
printf 'cwd=%s harness=%s\n' "\$PWD" "\${COVERAGE_HARNESS_NAME:-unset}" >> "${CALLS}"
exit "\${BATS_DOUBLE_EXIT:-0}"
STUB
  chmod +x "$BATS_BIN"
  # The CI coverage job sets JUNIT_DIR for the whole run, so the tests asserting on its absence unset it.
  unset JUNIT_DIR
}

@test "runs the whole suite recursively from the repository root" {
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" '^bats-double --recursive test/$'
  # Resolved, because the tool finds its root with `pwd -P` and the temp directory may be a symlink.
  stub_called_in "$CALLS" "^cwd=$(cd "$FAKE_REPO" && pwd -P) "
}

@test "tells the test helper the harness name it removes" {
  run_script "$FAKE_TOOL"
  stub_called_in "$CALLS" 'harness=_coverage-harness$'
}

@test "a JUNIT_DIR is passed to bats as a report directory" {
  JUNIT_DIR=junit run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" '^bats-double --recursive --report-formatter junit --output junit test/$'
}

@test "no JUNIT_DIR means no report flags" {
  run_script "$FAKE_TOOL"
  ! stub_called_in "$CALLS" 'report-formatter'
}

@test "the harnesses the test helper wrote are removed" {
  # The helper writes one beside each script on demand, including into fixture trees, so this is what
  # guarantees none survives a run and gets committed.
  mkdir -p "$FAKE_REPO/scripts/system/tool"
  touch "$FAKE_REPO/scripts/system/tool/_coverage-harness"
  touch "$FAKE_REPO/bin/lint/_coverage-harness"
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_REPO/scripts/system/tool/_coverage-harness" ]
  [ ! -f "$FAKE_REPO/bin/lint/_coverage-harness" ]
}

@test "a failing suite keeps its status and still removes the harnesses" {
  touch "$FAKE_REPO/bin/lint/_coverage-harness"
  BATS_DOUBLE_EXIT=3 run_script "$FAKE_TOOL"
  [ "$status" -eq 3 ]
  [ ! -f "$FAKE_REPO/bin/lint/_coverage-harness" ]
}

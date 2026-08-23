#!/usr/bin/env bats
#
# run-coverage.sh decides how the suite gets measured: locally when the toolchain is usable, in the pinned
# container otherwise. That decision has been wrong in ways that cost hours — kcov's macOS build execs
# /bin/bash 3.2 and most of these scripts die on it, which reads as a suite full of failures rather than as
# a toolchain that cannot run them — so it is worth testing rather than trusting.
#
# Nothing here runs kcov, bats or docker for real. They are reached through the KCOV_BIN, BATS_BIN and
# DOCKER_BIN seams, because a stub named kcov or bats on PATH would be picked up by the coverage harness
# tracing these very tests, and one named docker would be handed to ufw-docker-expose's suite, which runs
# the real CLI against pinned images.
#
# Every test drives the tool inside the fake repository: it does `rm -rf coverage` and `find … -delete`
# relative to its own location, so running the real one from the repository would delete the report of the
# run in progress.

load ../test_helper

setup() {
  setup_common
  fake_repo_tool run-coverage.sh
  mkdir -p "$FAKE_REPO/test" "$FAKE_REPO/scripts"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"

  export KCOV_BIN="$BIN/kcov-double"
  export BATS_BIN="$BIN/bats-double"
  export DOCKER_BIN="$BIN/docker-double"
  # The CI coverage job runs this tool as `JUNIT_DIR=junit …`, so the variable is in the environment of
  # every test there. Left inherited, the tests that assert on its absence assert on the runner instead.
  unset JUNIT_DIR
}

########################################
# Writes a double that records its argv and optionally prints something.
# Arguments:
#   path: Where to write it.
#   stdout: What it should print (may be empty).
########################################
double_at() {
  cat > "$1" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$1")" "\$*" >> "${CALLS}"
printf '%s' '${2:-}'
exit 0
STUB
  chmod +x "$1"
}

########################################
# Makes the local toolchain look present and modern, and has the bats double leave a merged report so the
# run reaches its success path.
########################################
usable_local_toolchain() {
  # The probe reads the bash major version the traced script ran under from kcov's stdout.
  double_at "$KCOV_BIN" "5"
  cat > "$BATS_BIN" <<STUB
#!/usr/bin/env bash
printf 'bats-double %s\n' "\$*" >> "${CALLS}"
mkdir -p "${FAKE_REPO}/coverage/kcov-merged"
echo '{}' > "${FAKE_REPO}/coverage/kcov-merged/coverage.json"
exit 0
STUB
  chmod +x "$BATS_BIN"
  double_at "$DOCKER_BIN"
}

# --- Choosing between the local toolchain and the container ------------------------------------

@test "runs the suite locally when kcov and bats are present and modern" {
  usable_local_toolchain
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"locally installed kcov"* ]]
  stub_called_in "$CALLS" '^bats-double --recursive test/$'
  ! stub_called_in "$CALLS" '^docker-double'
}

@test "falls back to the container when kcov runs the scripts under bash 3.x" {
  # kcov's macOS build ignores the shebang and execs /bin/bash. Running the suite under it produces
  # failures that look like bugs in the scripts, so the fallback is the whole point of the probe.
  usable_local_toolchain
  double_at "$KCOV_BIN" "3"
  run_script "$FAKE_TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash 3.x"* ]]
  stub_called_in "$CALLS" '^docker-double run --rm'
}

@test "falls back to the container when kcov is not installed at all" {
  usable_local_toolchain
  rm -f "$KCOV_BIN"
  run_script "$FAKE_TOOL"
  stub_called_in "$CALLS" '^docker-double run --rm'
}

@test "falls back to the container when bats is not installed" {
  usable_local_toolchain
  rm -f "$BATS_BIN"
  run_script "$FAKE_TOOL"
  stub_called_in "$CALLS" '^docker-double run --rm'
}

@test "KCOV_FORCE_DOCKER takes the container path despite a usable toolchain" {
  # Set rather than pruning PATH to hide kcov, which would also hide python3 and everything else
  # Homebrew provides and break the run somewhere unrelated.
  usable_local_toolchain
  KCOV_FORCE_DOCKER=1 run_script "$FAKE_TOOL"
  [[ "$output" == *"KCOV_FORCE_DOCKER is set"* ]]
  stub_called_in "$CALLS" '^docker-double run --rm'
  ! stub_called_in "$CALLS" '^bats-double'
}

# --- The container invocation ------------------------------------------------------------------

@test "the container is given the mount, the pinned versions and the in-container script" {
  usable_local_toolchain
  KCOV_FORCE_DOCKER=1 run_script "$FAKE_TOOL"
  local line physical
  line=$(grep '^docker-double' "$CALLS")
  # The mount is the physical path: the tool resolves its root with pwd -P, and on macOS a temp directory
  # reached through /var is really under /private/var.
  physical=$(cd "$FAKE_REPO" && pwd -P)
  [[ "$line" == *"-v ${physical}:/src -w /src"* ]]
  [[ "$line" == *"-e COVERAGE_HARNESS_NAME=_coverage-harness"* ]]
  [[ "$line" == *"--entrypoint bash"* ]]
  [[ "$line" == *"/src/bin/coverage/in-container.sh"* ]]
}

@test "the pinned bats version reaches the container with the v its release tag carries" {
  # bats exports BATS_VERSION itself, so running this tool from inside a suite hands it the outer bats
  # version without the prefix — and the archive URL built from that is a 404, not an error that explains
  # itself. This test runs under bats, so the collision is live here and the assertion is the guard.
  usable_local_toolchain
  KCOV_FORCE_DOCKER=1 run_script "$FAKE_TOOL"
  local line
  line=$(grep '^docker-double' "$CALLS")
  [[ "$line" == *"-e BATS_VERSION=v"* ]]
  [[ "$line" != *"-e BATS_VERSION=1"* ]]
  [[ "$line" == *"-e YQ_VERSION=v"* ]]
}

# --- The JUnit report --------------------------------------------------------------------------

@test "an absolute JUNIT_DIR is refused before anything runs" {
  # It is passed into the container and joined onto /src, so an absolute path would land outside the
  # mount — silently, since the container would happily create it.
  usable_local_toolchain
  JUNIT_DIR=/tmp/junit run_script "$FAKE_TOOL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"repo-relative"* ]]
  [ ! -s "$CALLS" ]
}

@test "a relative JUNIT_DIR is created and passed to bats" {
  usable_local_toolchain
  JUNIT_DIR=junit run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  [ -d "$FAKE_REPO/junit" ]
  stub_called_in "$CALLS" 'report-formatter junit --output junit'
}

@test "no JUNIT_DIR means no report flags" {
  usable_local_toolchain
  run_script "$FAKE_TOOL"
  ! stub_called_in "$CALLS" 'report-formatter'
}

# --- Its own output ----------------------------------------------------------------------------

@test "a run that produced no merged report is a failure" {
  # The whole point of the run is that file, and every path above can fail without saying so: a container
  # that could not install its packages still exits 0 from docker run.
  double_at "$KCOV_BIN" "5"
  double_at "$BATS_BIN"
  double_at "$DOCKER_BIN"
  run_script "$FAKE_TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"produced no merged report"* ]]
}

@test "the harnesses the test helper wrote are removed" {
  # The helper writes one beside each script on demand, including into fixture trees, so this is what
  # guarantees none survives a run and gets committed.
  usable_local_toolchain
  mkdir -p "$FAKE_REPO/scripts/system/tool"
  touch "$FAKE_REPO/scripts/system/tool/_coverage-harness"
  touch "$FAKE_REPO/bin/lint/_coverage-harness"
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_REPO/scripts/system/tool/_coverage-harness" ]
  [ ! -f "$FAKE_REPO/bin/lint/_coverage-harness" ]
}

@test "a previous report is cleared before the run" {
  usable_local_toolchain
  mkdir -p "$FAKE_REPO/coverage/stale"
  touch "$FAKE_REPO/coverage/stale/old.json"
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  [ ! -d "$FAKE_REPO/coverage/stale" ]
}

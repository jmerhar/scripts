#!/usr/bin/env bats
#
# bin/_lib/ is the bin tools' own library, sourced at run time rather than inlined by the compiler the way
# scripts/lib/ is. Two properties are worth pinning down here rather than inferring them from whichever
# tool happens to exercise them:
#
#   * paths.sh states the bin/<group>/<tool>.sh depth once, for all fourteen tools. Getting it wrong sends
#     every manifest read and every dist/ write one directory too deep, and the tools honour no override,
#     so a wrong root cannot be corrected from outside.
#   * log.sh emits a GitHub Actions annotation on stdout as well as the timestamped line on stderr. That
#     split is what a test counting reported items has to account for, so it is asserted per stream.
#
# The library is reached through a probe placed where a real tool sits, so the `../_lib/` path it resolves
# is the one the tools resolve, and the repository root it derives is the fixture's rather than this one.

load ../test_helper

setup() {
  setup_common
  # Mirrors bin/ into the fixture, _lib/ included, which is what a tool's ../_lib/ resolves against.
  fake_repo_tool check-manifest.sh
  PROBE="$FAKE_REPO/bin/lint/probe.sh"
  SNIPPET="$BATS_TEST_TMPDIR/snippet.sh"
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
  # The fixture root as the library reports it: BATS_TEST_TMPDIR sits under a symlinked /var on macOS,
  # and paths.sh resolves symlinks, so the literal $FAKE_REPO would not compare equal.
  FAKE_REPO_REAL="$(cd "$FAKE_REPO" && pwd -P)"

  cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
#
# Sources the bin/ library exactly as a tool in this directory does, then runs the snippet file named by
# $1 with stderr redirected to the file named by $2, so a test can tell the annotation on stdout from the
# timestamped line on stderr.
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"

exec 2>"$2"
# shellcheck source=/dev/null
source "$1"
PROBE_EOF
  chmod +x "$PROBE"
}

########################################
# Runs a snippet against the library, leaving stdout in $output and stderr in $STDERR_FILE.
# Arguments:
#   snippet: Bash to run with the library loaded.
########################################
probe() {
  printf '%s\n' "$1" > "$SNIPPET"
  run_script "$PROBE" "$SNIPPET" "$STDERR_FILE"
}

########################################
# Prints what the probe wrote to stderr.
########################################
probe_stderr() {
  cat "$STDERR_FILE"
}

# --- paths.sh ----------------------------------------------------------------------------------

# The depth is the whole point of the file: a tool at bin/<group>/ has the repository two levels up.
@test "REPO_ROOT is the grandparent of the sourcing tool's directory" {
  probe 'printf "%s" "${REPO_ROOT}"'
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_REPO_REAL" ]
}

@test "MANIFEST and SCRIPTS_DIR hang off that root" {
  probe 'printf "%s\n%s" "${MANIFEST}" "${SCRIPTS_DIR}"'
  [ "${lines[0]}" = "$FAKE_REPO_REAL/scripts.yaml" ]
  [ "${lines[1]}" = "$FAKE_REPO_REAL/scripts" ]
}

# The tools are tested against fixture trees whose bin/ holds symlinks into the real one, so the root has
# to come from the directory the tool sits in rather than from the file the link points at.
@test "REPO_ROOT resolves through the fixture's symlinks to the fixture, not the real repository" {
  probe 'printf "%s" "${REPO_ROOT}"'
  [ "$output" != "$REPO_ROOT" ]
  [ -f "$output/bin/_lib/paths.sh" ]
}

# The suites depend on a tool reading the fixture's manifest and writing into the fixture's dist/. An
# inherited value would point the tool at the real repository, which setup_common exports.
@test "an inherited REPO_ROOT is overridden rather than honoured" {
  REPO_ROOT="/nowhere" probe 'printf "%s" "${REPO_ROOT}"'
  [ "$output" = "$FAKE_REPO_REAL" ]
}

# The variables are readonly, so without the guard a second source would abort the tool under errexit.
@test "sourcing paths.sh twice is a no-op rather than a readonly failure" {
  probe 'source "${SCRIPT_DIR}/../_lib/paths.sh"
printf "%s" "${REPO_ROOT}"'
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_REPO_REAL" ]
}

# --- log.sh ------------------------------------------------------------------------------------

@test "log_error writes a timestamped line to stderr" {
  probe 'log_error "boom"'
  [ "$status" -eq 0 ]
  run probe_stderr
  [[ "$output" == *"[ERROR]: boom"* ]]
  [[ "$output" =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}\] ]]
}

@test "log_info and log_warning write their own level to stderr" {
  probe 'log_info "fyi"
log_warning "careful"'
  run probe_stderr
  [[ "$output" == *"[INFO]: fyi"* ]]
  [[ "$output" == *"[WARNING]: careful"* ]]
}

# Nothing outside CI should see workflow-command syntax; a developer reading a failure wants the one line.
@test "no annotation is emitted when GITHUB_ACTIONS is unset" {
  GITHUB_ACTIONS= probe 'log_error "boom"
log_warning "careful"'
  [ "$output" = "" ]
}

# The annotation goes to stdout, where the runner reads workflow commands, and the timestamped line still
# goes to stderr — so under CI a reported item appears twice across the two streams, once in each.
@test "under GITHUB_ACTIONS the annotation goes to stdout and the line still to stderr" {
  GITHUB_ACTIONS=true probe 'log_error "boom"'
  [ "$output" = "::error::boom" ]
  run probe_stderr
  [[ "$output" == *"[ERROR]: boom"* ]]
  [[ "$output" != *"::error::"* ]]
}

@test "log_warning annotates as a warning, not an error" {
  GITHUB_ACTIONS=true probe 'log_warning "careful"'
  [ "$output" = "::warning::careful" ]
}

# An informational line is not a build annotation: annotating it would mark a passing step.
@test "log_info never annotates" {
  GITHUB_ACTIONS=true probe 'log_info "fyi"'
  [ "$output" = "" ]
  run probe_stderr
  [[ "$output" == *"[INFO]: fyi"* ]]
}

@test "each function joins its arguments into one message" {
  probe 'log_error "two" "parts"'
  run probe_stderr
  [[ "$output" == *"[ERROR]: two parts"* ]]
}

@test "sourcing log.sh twice leaves the functions working" {
  probe 'source "${SCRIPT_DIR}/../_lib/log.sh"
log_error "boom"'
  [ "$status" -eq 0 ]
  run probe_stderr
  [[ "$output" == *"[ERROR]: boom"* ]]
}

#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared setup for the bats suites.
#
# Code under test is always reached through run_script, run_func or run_snippet. All three launch a
# subprocess, which buys two properties every suite depends on:
#
#   * $0 is the script's own path. Every script here derives its library include, SCRIPT_NAME,
#     install prefix, config search path and usage text from $0, so a harness that got $0 wrong
#     would exercise different code than production does.
#   * No state survives a call, so no test can be perturbed by an earlier one. This matters more
#     than usual because the scripts declare `readonly` globals, which a second in-process source
#     would refuse to re-assign.
#
# These three functions are also the only place that knows how to launch a script, so adding line
# coverage later means editing them and nothing else.

########################################
# Prepares an isolated environment for one test: repo paths, the stub PATH, and a deterministic
# locale and timezone.
# Globals:
#   REPO_ROOT, STUB_FIXTURES, STUB_CALLS, PATH, TZ, LC_ALL
# Outputs:
#   Writes a diagnostic to stderr and fails the test if the stubs are not first on PATH.
########################################
setup_common() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT

  LIB="$REPO_ROOT/scripts/lib/common.sh"
  export LIB

  # Every stub appends its argv to STUB_CALLS and takes canned behaviour from files in
  # STUB_FIXTURES; test/stubs/_stub documents the file names it looks for.
  STUB_FIXTURES="$BATS_TEST_TMPDIR/stub-fixtures"
  STUB_CALLS="$BATS_TEST_TMPDIR/stub-calls"
  export STUB_FIXTURES STUB_CALLS
  mkdir -p "$STUB_FIXTURES"
  : > "$STUB_CALLS"

  # The stubs shadow the real binaries, and that is a safety mechanism rather than a convenience.
  # Several scripts here delete files, drive rsync, or talk to a torrent daemon, and they read their
  # settings from the repo's own committed .conf files — load_config resolves that path from $0 and
  # honours no override — so on a developer machine a test can be handed real, populated paths.
  # The stub directory sitting first on PATH is what keeps that harmless.
  PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export PATH
  _assert_stubs_first || return 1

  # Pinned so that a developer's shell cannot move a date, a sort order or a decimal separator.
  export TZ=UTC
  export LC_ALL=C

  # Scripts and the shared library read these from the environment; a value inherited from the
  # surrounding shell would silently change what is being tested.
  unset LOG_FILE IS_DEBUG_MODE _LOG_QUIET SCRIPT_NAME
}

########################################
# Verifies the stub directory is the first PATH entry, so no test can reach a real binary.
# Globals:
#   PATH, BATS_TEST_DIRNAME
# Returns:
#   0 when the stubs are first, 1 otherwise.
########################################
_assert_stubs_first() {
  local first="${PATH%%:*}"
  if [[ "${first}" != "$BATS_TEST_DIRNAME/stubs" ]]; then
    printf 'test_helper: stub directory is not first on PATH (found %s)\n' "${first}" >&2
    return 1
  fi
}

########################################
# Runs a script end to end through its command line, as a user would.
# `bash <script>` rather than executing it directly: the repo's exec bits are inconsistent
# (local-backup.sh is 0644, remove-sidecars.sh is 0711) because package-script.sh normalises them
# to 0755 when packaging, so relying on them here would make a suite fail for an unrelated reason.
# Arguments:
#   script: Absolute path of the script to run.
#   Remaining arguments are passed to the script.
# Outputs:
#   Sets the bats `status`, `output` and `lines` variables.
########################################
run_script() {
  local script="$1"
  shift
  run bash "${script}" "$@"
}

########################################
# Spells a path so that it names the same file as its argument while comparing unequal to it.
# Scripts end in the idiomatic `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard, and the suites need $0 to
# be the script's own path for fidelity — but then both sides of that comparison are identical and
# main would run on source. Bash offers no other signal: under `bash -c 'source "$0"'` a sourced
# script is indistinguishable from an executed one, down to the length of BASH_SOURCE.
# Inserting a `/./` gives the `source` argument a different spelling of the same file, so the guard
# is false while every $0-derived path still resolves exactly as it does in production. Nothing in
# these scripts reads BASH_SOURCE other than the guard itself.
# Arguments:
#   path: Path to respell.
# Outputs:
#   Prints the path with a `/./` inserted before its final component.
########################################
_sourceable_path() {
  printf '%s/./%s' "$(dirname "$1")" "$(basename "$1")"
}

########################################
# Calls one function from a script or library, without running its main.
# Arguments:
#   script: Absolute path of the script to source.
#   func: Name of the function to call.
#   Remaining arguments are passed to the function.
# Outputs:
#   Sets the bats `status`, `output` and `lines` variables.
########################################
run_func() {
  local script="$1" func="$2"
  shift 2
  run bash -c 'source "$1"; shift; "$@"' \
    "${script}" "$(_sourceable_path "${script}")" "${func}" "$@"
}

########################################
# Evaluates a snippet of bash after sourcing a script or library.
# For assertions that a single function call cannot express: inspecting a global the script sets,
# calling two functions in sequence, or checking state after a failure.
# Arguments:
#   script: Absolute path of the script to source.
#   snippet: Bash to evaluate once the script is sourced.
# Outputs:
#   Sets the bats `status`, `output` and `lines` variables.
########################################
run_snippet() {
  local script="$1" snippet="$2"
  run bash -c 'source "$1"; shift; eval "$1"' \
    "${script}" "$(_sourceable_path "${script}")" "${snippet}"
}

########################################
# Asserts a stub recorded a call whose argv matches a pattern.
# Globals:
#   STUB_CALLS
# Arguments:
#   pattern: A grep basic-regular-expression matched against whole recorded lines.
# Returns:
#   0 if at least one recorded call matches, 1 otherwise.
########################################
stub_called() {
  grep -q "$1" "$STUB_CALLS"
}

########################################
# Counts the calls a given command recorded.
# Globals:
#   STUB_CALLS
# Arguments:
#   command: The stubbed command name.
# Outputs:
#   Prints the number of recorded invocations.
########################################
stub_calls() {
  grep -c "^$1 " "$STUB_CALLS" 2>/dev/null || true
}

########################################
# Makes a stub fail on its next invocation.
# Globals:
#   STUB_FIXTURES
# Arguments:
#   command: The stubbed command name.
#   code: Optional exit status, defaulting to 1.
########################################
stub_fails() {
  printf '%s' "${2:-1}" > "$STUB_FIXTURES/$1.fail"
}

########################################
# Gives a stub canned stdout for every invocation.
# Globals:
#   STUB_FIXTURES
# Arguments:
#   command: The stubbed command name.
# Inputs:
#   The desired stdout, read from this function's stdin.
########################################
stub_outputs() {
  cat > "$STUB_FIXTURES/$1.stdout"
}

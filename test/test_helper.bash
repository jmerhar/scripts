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
  # Derived from this file rather than from the suite's directory: the suites are grouped in
  # subdirectories, so BATS_TEST_DIRNAME is a level deeper for most of them and would put the repository
  # root and the stub directory in the wrong place. TEST_DIR is always the directory holding this helper.
  TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
  export TEST_DIR REPO_ROOT

  LIB="$REPO_ROOT/scripts/lib/common.sh"
  export LIB

  # Basename of the harness bin/run-coverage.sh places beside each script while measuring. Named here
  # because both the seams below and the runner that creates them need to agree on it.
  COVERAGE_HARNESS_NAME="${COVERAGE_HARNESS_NAME:-_coverage-harness}"
  export COVERAGE_HARNESS_NAME

  # Every stub appends its argv to STUB_CALLS and takes canned behaviour from files in
  # STUB_FIXTURES; test/stubs/_stub documents the file names it looks for.
  STUB_FIXTURES="$BATS_TEST_TMPDIR/stub-fixtures"
  STUB_CALLS="$BATS_TEST_TMPDIR/stub-calls"
  export STUB_FIXTURES STUB_CALLS
  mkdir -p "$STUB_FIXTURES"
  : > "$STUB_CALLS"

  # The stubs shadow the real binaries, and that is a safety mechanism rather than a convenience.
  # Several scripts here delete files, drive rsync, or talk to a torrent daemon, and a test that does
  # not name its own CONFIG_FILE gets their settings from the repo's own committed .conf files, which
  # on a developer machine can point at real, populated paths. The stub directory sitting first on
  # PATH is what keeps that harmless.
  PATH="$TEST_DIR/stubs:$PATH"
  export PATH
  _assert_stubs_first || return 1

  # Pinned so that a developer's shell cannot move a date, a sort order or a decimal separator.
  export TZ=UTC
  export LC_ALL=C

  # Scripts and the shared library read these from the environment; a value inherited from the
  # surrounding shell would silently change what is being tested. CONFIG_FILE matters most: left set, it
  # would point every config-reading script at a developer's own file.
  unset LOG_FILE IS_DEBUG_MODE _LOG_QUIET SCRIPT_NAME CONFIG_FILE
}

########################################
# Verifies the stub directory is the first PATH entry, so no test can reach a real binary.
# Globals:
#   PATH, TEST_DIR
# Returns:
#   0 when the stubs are first, 1 otherwise.
########################################
_assert_stubs_first() {
  local first="${PATH%%:*}"
  if [[ "${first}" != "$TEST_DIR/stubs" ]]; then
    printf 'test_helper: stub directory is not first on PATH (found %s)\n' "${first}" >&2
    return 1
  fi
}

########################################
# Prints the kcov invocation that traces a run, or nothing when coverage is not being measured.
# kcov must be given the script itself: handed `bash script` it instruments the bash binary and reports
# nothing. .conf files are excluded because load_config sources them, so they would otherwise appear in
# the report as instrumented files; the coverage harness and runner are excluded as tooling.
# Globals:
#   COVERAGE_DIR, REPO_ROOT
# Outputs:
#   Prints the command prefix, unquoted by the caller so it splits into arguments.
########################################
_coverage_prefix() {
  [[ -n "${COVERAGE_DIR:-}" ]] || return 0
  printf 'kcov --include-path=%s/scripts,%s/bin --exclude-pattern=.conf,.md,%s,run-coverage.sh %s' \
    "$REPO_ROOT" "$REPO_ROOT" "$COVERAGE_HARNESS_NAME" "$COVERAGE_DIR"
}

########################################
# Runs a script end to end through its command line, as a user would.
# Executed directly rather than via `bash <script>`, both because that is how a user invokes it — every
# published script is executable, which bin/check-manifest.sh enforces — and because kcov can only trace
# a script it runs itself.
# Globals:
#   COVERAGE_DIR
# Arguments:
#   script: Absolute path of the script to run.
#   Remaining arguments are passed to the script.
# Outputs:
#   Sets the bats `status`, `output` and `lines` variables.
########################################
run_script() {
  local script="$1"
  shift
  # Word-split on purpose: the prefix is a command with its own arguments, and is empty without
  # COVERAGE_DIR.
  # shellcheck disable=SC2046
  run $(_coverage_prefix) "${script}" "$@"
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
# Writes the sourcing harness kcov executes, at the given path.
# Created next to its target on demand, because it must live beside the script it sources: $0 is the
# harness, and the scripts resolve their library relative to "$(dirname "$0")". Written here
# rather than only by bin/run-coverage.sh so that a tool copied into a fixture tree — as the bin/ suites
# do — gets one too. bin/run-coverage.sh deletes any that a run leaves behind.
# Arguments:
#   path: Where to write the harness.
########################################
_write_coverage_harness() {
  cat > "$1" <<'HARNESS'
#!/usr/bin/env bash
# Sources a script under test and calls into it, so kcov — which can only trace a script it executes
# itself — measures the functions the suite exercises directly. SCRIPT_NAME is passed in so the sourced
# script keeps its own identity: its config path and log prefix derive from it, not from this filename.
mode="$1"
# Defaulted, not forced: a test may pin SCRIPT_NAME to something of its own, exactly as a caller of the
# shared library can, and that choice has to survive reaching the script through here.
SCRIPT_NAME="${SCRIPT_NAME:-$2}"
export SCRIPT_NAME
target="$3"
shift 3
# shellcheck source=/dev/null
source "${target}"
if [[ "${mode}" == "eval" ]]; then
  eval "$1"
else
  "$@"
fi
HARNESS
  chmod +x "$1"
}

########################################
# Sources a script and calls a function in it, or evaluates a snippet.
#
# Two implementations, because kcov cannot trace the cheap one. Without coverage, `bash -c` sets $0 to
# the script's own path directly. Under kcov that path is unusable: kcov's injected prologue reads
# BASH_SOURCE, which is unset inside a `-c` command string, so a script running under `set -o nounset`
# — all of them here — dies before its function is reached. (--bash-method=DEBUG survives that but
# measures nothing at all.) So under coverage the call goes through a harness script that kcov executes
# directly; bin/run-coverage.sh places one beside every script for the duration of a run, so that
# $(dirname "$0") is still the script's own directory and its library include resolves, and the harness
# exports SCRIPT_NAME so the config path and log prefix are the script's own rather than the harness's.
# Globals:
#   COVERAGE_DIR, COVERAGE_HARNESS_NAME
# Arguments:
#   mode: `call` to invoke a function with arguments, `eval` to evaluate a snippet.
#   script: Absolute path of the script to source.
#   Remaining arguments are the function and its arguments, or the snippet.
# Outputs:
#   Sets the bats `status`, `output` and `lines` variables.
########################################
_run_sourced() {
  local mode="$1" script="$2"
  shift 2

  if [[ -z "${COVERAGE_DIR:-}" ]]; then
    if [[ "${mode}" == "eval" ]]; then
      run bash -c 'source "$1"; shift; eval "$1"' \
        "${script}" "$(_sourceable_path "${script}")" "$@"
    else
      run bash -c 'source "$1"; shift; "$@"' \
        "${script}" "$(_sourceable_path "${script}")" "$@"
    fi
    return
  fi

  local harness
  harness="$(dirname "${script}")/${COVERAGE_HARNESS_NAME}"
  [[ -x "${harness}" ]] || _write_coverage_harness "${harness}"

  local script_name
  script_name="$(basename "${script}" .sh)"
  # shellcheck disable=SC2046  # the prefix is a command with arguments
  run $(_coverage_prefix) "${harness}" "${mode}" "${script_name}" "${script}" "$@"
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
  _run_sourced call "${script}" "${func}" "$@"
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
  _run_sourced eval "${script}" "${snippet}"
}

########################################
# Places one bin/ tool in a self-contained fake repository under the test's temp directory.
#
# The bin/ tools locate the manifest and their output directories relative to $0 and honour no override,
# so testing them against the real repository would read the real manifest and write into the real
# dist/. They source nothing, so a lone entry in a fixture tree works unmodified: it reads the fixture
# manifest and writes only inside the test's own directory.
#
# Symlinked rather than copied, so that coverage is credited to the tool in bin/ and not to a path
# under the temp directory that nothing measures — a copy makes these suites exercise the real logic
# while reporting nothing for it. Fidelity is unaffected: the tools resolve their repo root as
# "$(cd "$(dirname "$0")" && pwd -P)", and pwd -P resolves the *directory*, which is the fixture's.
#
# Sets FAKE_REPO and FAKE_TOOL rather than printing the path: a command substitution would run in a
# subshell, leaving FAKE_REPO unset in the caller and every fixture path resolving against the
# filesystem root.
# Globals:
#   REPO_ROOT, BATS_TEST_TMPDIR; sets FAKE_REPO and FAKE_TOOL.
# Arguments:
#   tool: Filename of the tool in bin/, e.g. package-script.sh.
########################################
fake_repo_tool() {
  FAKE_REPO="$BATS_TEST_TMPDIR/repo"
  FAKE_TOOL="$FAKE_REPO/bin/$1"
  export FAKE_REPO FAKE_TOOL
  mkdir -p "$FAKE_REPO/bin"
  ln -sf "$REPO_ROOT/bin/$1" "$FAKE_TOOL"

  # This directory stands in for the real bin/, so it mirrors it: the awk and jq programs a tool runs with
  # `awk -f`, and the sibling tools one shells out to — package-script.sh compiles through
  # compile-includes.sh, and compile-all-includes.sh does the same. Linking the lot rather than mapping
  # each tool to its dependencies keeps one thing in step instead of two, and a test still invokes only
  # what it names.
  local sibling
  for sibling in "$REPO_ROOT"/bin/*.sh "$REPO_ROOT"/bin/*.awk "$REPO_ROOT"/bin/*.jq; do
    [ -e "$sibling" ] || continue
    ln -sf "$sibling" "$FAKE_REPO/bin/$(basename "$sibling")"
  done
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

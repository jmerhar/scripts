#!/usr/bin/env bats
#
# Tests the test harness itself.
#
# Every other suite trusts test_helper.bash to run the right file, with the right $0, under a PATH
# where nothing real can be reached. A fault there does not announce itself: it makes suites pass
# while exercising something other than what they name, or — worse — lets a script reach a real
# rsync. These assertions are what keep the rest of the suite meaningful, so they check the harness's
# guarantees rather than any script's behaviour.

load ../test_helper

setup() {
  setup_common

  # A stand-in for a real script: the same guard, and enough reporting to show what the harness did.
  FIXTURE="$BATS_TEST_TMPDIR/fixture-tool.sh"
  cat > "$FIXTURE" <<'EOF'
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

VALUE="from the fixture"

report_dollar_zero() { printf '%s' "$0"; }
double() { printf '%s' "$(( $1 * 2 ))"; }
fail_with() { return "$1"; }

main() {
  printf 'main ran with [%s]' "$*"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
EOF
  chmod +x "$FIXTURE"
}

# --- The three seams ---------------------------------------------------------------------------

@test "run_script runs the script's main" {
  run_script "$FIXTURE" alpha beta
  [ "$status" -eq 0 ]
  [ "$output" = "main ran with [alpha beta]" ]
}

@test "run_func calls one function and leaves main alone" {
  run_func "$FIXTURE" double 21
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
}

@test "run_snippet evaluates bash against the sourced script's state" {
  run_snippet "$FIXTURE" 'printf "%s" "$VALUE"'
  [ "$status" -eq 0 ]
  [ "$output" = "from the fixture" ]
}

@test "run_func propagates a function's exit status" {
  run_func "$FIXTURE" fail_with 3
  [ "$status" -eq 3 ]
}

@test "run_script propagates a script's exit status" {
  run_script "$REPO_ROOT/scripts/utility/unlock-pdf/unlock-pdf.sh"
  [ "$status" -eq 1 ]
}

# --- $0 fidelity, which everything $0-derived depends on ---------------------------------------
#
# What the scripts actually need from $0 is its *directory*, to find the shared library, and their own
# name, for the config path and usage text. Those are asserted rather than $0 literally, because under
# coverage the sourced call arrives through a harness beside the script: the directory is the same, the
# name is passed in, and kcov can trace it — whereas the `bash -c` form that sets $0 exactly cannot be
# traced at all.

@test "run_script sets \$0 to the script's own path" {
  # unlock-pdf builds its usage line from basename "$0", and reaches it when given no argument.
  run_script "$REPO_ROOT/scripts/utility/unlock-pdf/unlock-pdf.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: unlock-pdf.sh"* ]]
}

@test "a sourced call sees the script's own directory as \$0's" {
  run_snippet "$FIXTURE" 'printf "%s" "$(cd "$(dirname "$0")" && pwd -P)"'
  [ "$output" = "$(cd "$(dirname "$FIXTURE")" && pwd -P)" ]
}

@test "a sourced call resolves the shared library the way the scripts do" {
  # The property the directory matters for: every script includes the shared library relative to $0.
  run_snippet "$REPO_ROOT/scripts/utility/subtitle-report/subtitle-report.sh" \
    'declare -F log_info >/dev/null && printf "library loaded"'
  [ "$status" -eq 0 ]
  [ "$output" = "library loaded" ]
}

@test "a sourced script keeps its own name, not the harness's" {
  run_snippet "$REPO_ROOT/scripts/utility/subtitle-report/subtitle-report.sh" 'printf "%s" "$SCRIPT_NAME"'
  [ "$output" = "subtitle-report" ]
}

# The whole reason run_func can source a guarded script: the path handed to `source` names the same
# file as $0 but is spelled differently, so the guard is false. If these ever became equal, every
# run_func call would silently start running main instead of the function asked for.
@test "_sourceable_path names the same file as its argument" {
  local respelled
  respelled=$(_sourceable_path "$FIXTURE")
  [ "$respelled" != "$FIXTURE" ]
  [ "$(cat "$respelled")" = "$(cat "$FIXTURE")" ]
}

@test "sourcing through the respelled path does not trigger the guard" {
  run_snippet "$FIXTURE" 'printf "no main"'
  [ "$output" = "no main" ]
  [[ "$output" != *"main ran"* ]]
}

# --- The PATH guarantee ------------------------------------------------------------------------
#
# Asserted against TEST_DIR, the directory holding the helper, rather than the suite's own directory: the
# suites are grouped in subdirectories and the stubs are shared by all of them, so the two are not the
# same place.

@test "the stub directory is first on PATH" {
  [ "${PATH%%:*}" = "$TEST_DIR/stubs" ]
}

@test "a stubbed command resolves to the stub, not the real binary" {
  run command -v rsync
  [ "$output" = "$TEST_DIR/stubs/rsync" ]
}

@test "the PATH assertion fails when the stubs are not first" {
  PATH="/usr/bin:$PATH"
  run _assert_stubs_first
  [ "$status" -eq 1 ]
  [[ "$output" == *"stub directory is not first on PATH"* ]]
}

# --- Stub behaviour ----------------------------------------------------------------------------

@test "a stub records its argv and succeeds" {
  run rsync -a --delete /from /to
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_CALLS")" = "rsync -a --delete /from /to" ]
}

@test "each stub records under its own command name" {
  exiftool -Model x.jpg
  ffmpeg -i in.mkv
  run cat "$STUB_CALLS"
  [[ "$output" == *"exiftool -Model x.jpg"* ]]
  [[ "$output" == *"ffmpeg -i in.mkv"* ]]
}

# The stubs that fabricate an output file infer its path from the argument list, which is a guess: a
# command may be called with an input last, as `ffmpeg -i in.mkv` is. Writing that guess would put a file
# wherever the suite happened to be run from — the repository itself, under a relative path.
@test "a stub never writes outside a temp directory" {
  # Deliberately not cd-ing anywhere: the cwd a suite actually runs in is the repository, which is what
  # makes a relative destination dangerous. Both strays are cleared before asserting, so a broken guard
  # reports itself rather than leaving debris for the next run to trip over.
  local relative="$PWD/in.mkv" absolute="$PWD/escaped.pdf"
  local made_relative=no made_absolute=no
  ffmpeg -i in.mkv
  qpdf --decrypt --password=x locked.pdf "$absolute"
  [ -e "$relative" ] && made_relative=yes
  [ -e "$absolute" ] && made_absolute=yes
  rm -f "$relative" "$absolute"
  [ "$made_relative" = no ]
  [ "$made_absolute" = no ]
}

@test "a stub still writes an output file inside the test temp directory" {
  ffmpeg -i "$BATS_TEST_TMPDIR/v.mkv" -f srt "$BATS_TEST_TMPDIR/out.srt"
  [ -s "$BATS_TEST_TMPDIR/out.srt" ]
  grep -q ' --> ' "$BATS_TEST_TMPDIR/out.srt"
}

# A script under test makes its own scratch directory with mktemp, which is not the test temp directory
# but is still a legitimate destination — refusing it would break every suite whose script works there.
@test "a stub writes into a scratch directory a script made for itself" {
  local scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/harness-bats.XXXXXX")
  ffmpeg -i "$scratch/v.mkv" -f srt "$scratch/out.srt"
  [ -s "$scratch/out.srt" ]
  rm -rf "$scratch"
}

@test "stub_called matches a recorded call" {
  rsync -a --delete /from /to
  stub_called 'rsync .*--delete'
  run stub_called 'rsync .*--dry-run'
  [ "$status" -ne 0 ]
}

@test "stub_calls counts invocations, including none" {
  [ "$(stub_calls rsync)" -eq 0 ]
  rsync one
  rsync two
  [ "$(stub_calls rsync)" -eq 2 ]
}

@test "stub_fails makes a stub exit non-zero" {
  stub_fails rsync
  run rsync -a x y
  [ "$status" -eq 1 ]
}

@test "stub_fails can name the exit status" {
  stub_fails rsync 23
  run rsync -a x y
  [ "$status" -eq 23 ]
  # The call is still recorded, so a test can assert on what was attempted.
  stub_called 'rsync -a x y'
}

@test "stub_outputs gives a stub canned stdout" {
  stub_outputs exiftool <<< 'FUJIFILM X100V'
  run exiftool -Model photo.raf
  [ "$status" -eq 0 ]
  [ "$output" = "FUJIFILM X100V" ]
}

@test "a stub with no fixtures prints nothing" {
  run rsync -a x y
  [ -z "$output" ]
}

@test "the qpdf stub leaves an output file, which its caller checks for" {
  run qpdf --decrypt --password=x "$BATS_TEST_TMPDIR/in.pdf" "$BATS_TEST_TMPDIR/out.pdf"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/out.pdf" ]
}

# --- Isolation ---------------------------------------------------------------------------------

@test "the call log starts empty in every test" {
  [ -f "$STUB_CALLS" ]
  [ ! -s "$STUB_CALLS" ]
}

@test "the temp directory is this test's own and is writable" {
  [ -d "$BATS_TEST_TMPDIR" ]
  touch "$BATS_TEST_TMPDIR/probe"
  [ -f "$BATS_TEST_TMPDIR/probe" ]
}

@test "the environment is pinned so results cannot vary by machine" {
  [ "$TZ" = "UTC" ]
  [ "$LC_ALL" = "C" ]
}

@test "logging variables inherited from the developer's shell are cleared" {
  [ -z "${LOG_FILE:-}" ]
  [ -z "${IS_DEBUG_MODE:-}" ]
  [ -z "${_LOG_QUIET:-}" ]
  [ -z "${SCRIPT_NAME:-}" ]
}

# --- fake_repo_tool ----------------------------------------------------------------------------

# Sets its variables rather than printing a path: a command substitution would run it in a subshell
# and leave FAKE_REPO unset in the caller, which resolves every fixture path against the filesystem
# root instead of the test's own directory.
@test "fake_repo_tool sets both of its variables in the caller" {
  fake_repo_tool package-script.sh
  [ -n "$FAKE_REPO" ]
  [ -n "$FAKE_TOOL" ]
  [ "$FAKE_REPO" = "$BATS_TEST_TMPDIR/repo" ]
  [ "$FAKE_TOOL" = "$FAKE_REPO/bin/package/package-script.sh" ]
}

@test "fake_repo_tool places a working tool in the fake repository" {
  fake_repo_tool package-script.sh
  [ -f "$FAKE_TOOL" ]
  run_script "$FAKE_TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected exactly 2 arguments"* ]]
}

# Linked, not copied, so kcov credits the tool in bin/ rather than a path under the temp directory that
# nothing measures. A copy leaves these suites exercising the real logic while reporting nothing for it —
# package-script.sh read 7% with 48 tests against it.
@test "fake_repo_tool links the tool so its coverage is credited" {
  fake_repo_tool package-script.sh
  [ -L "$FAKE_TOOL" ]
  [ "$(readlink "$FAKE_TOOL")" = "$REPO_ROOT/bin/package/package-script.sh" ]
}

# The tools source ../_lib/ and reach cross-group siblings as ../<group>/, so a flat fixture would
# leave every one of them unable to load paths.sh. Asserted here rather than left to the bin/ suites:
# a fixture missing _lib/ fails dozens of tests across the bin/ suites, none of which names the cause.
@test "fake_repo_tool mirrors bin/'s subdirectories, the library included" {
  fake_repo_tool package-script.sh
  [ -f "$FAKE_REPO/bin/_lib/paths.sh" ]
  [ -f "$FAKE_REPO/bin/_lib/log.sh" ]
  # The cross-group sibling package-script.sh compiles through, and the awk program beside it.
  [ -f "$FAKE_REPO/bin/compile/compile-includes.sh" ]
  [ -f "$FAKE_REPO/bin/package/class-name.awk" ]
  # Every real subdirectory is reproduced, so a tool from any group can be asked for next.
  local group
  for group in lint compile package docs coverage _lib; do
    [ -d "$FAKE_REPO/bin/$group" ]
  done
}

# A name that matches no tool would otherwise yield an empty subdirectory and place the fixture's copy at
# bin/<name>, which no tool resolves — the suite would then fail further on, describing something else.
@test "fake_repo_tool refuses a tool that does not exist" {
  run fake_repo_tool no-such-tool.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"no tool named no-such-tool.sh"* ]]
}

@test "the linked tool reads the fake repository's manifest, not the real one" {
  fake_repo_tool package-script.sh
  run_script "$FAKE_TOOL" unlock-pdf v1.0.0
  [ "$status" -eq 1 ]
  # unlock-pdf exists in the real manifest; the fake repository has none at all.
  [[ "$output" == *"Manifest not found:"* ]]
  [[ "$output" == *"$BATS_TEST_TMPDIR"* ]]
}

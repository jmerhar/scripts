#!/usr/bin/env bats
#
# check-published-form.sh is the only thing that checks what users actually install. package-script.sh
# does not compile, so `make smoke` packages the development form — a script that still sources the
# shared library and reads its awk and jq programs from beside itself, neither of which is shipped.
#
# The failure this suite guards hardest against is the check passing while verifying nothing: it reads the
# @embed directives out of the source tree, and compiling removes them, so run on an already-compiled tree
# it would find no programs and report success.

load ../test_helper

setup() {
  setup_common
  # One call is enough: fake_repo_tool mirrors the whole of bin/, including the two compilers this shells
  # out to.
  fake_repo_tool check-published-form.sh
  TOOL="$FAKE_TOOL"
  mkdir -p "$FAKE_REPO/scripts/lib"
  printf 'log_error() { echo "$*" >&2; }\n' > "$FAKE_REPO/scripts/lib/common.sh"
}

########################################
# Writes a publishable script with a program beside it, in its own directory.
# Arguments:
#   name: Script name; created at scripts/utility/<name>/<name>.sh.
#   directive: The @embed line to include, or empty for none.
########################################
publishable() {
  local name="$1" directive="${2:-}"
  local dir="$FAKE_REPO/scripts/utility/$name"
  mkdir -p "$dir"
  printf 'BEGIN { print "program" }\n' > "$dir/prog.awk"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# shellcheck source=../../lib/common.sh\n'
    printf 'source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/common.sh"\n'
    printf '# @include ../../lib/common.sh\n'
    [[ -n "${directive}" ]] && printf '%s\n' "${directive}"
    printf 'echo body\n'
  } > "$dir/$name.sh"
  chmod +x "$dir/$name.sh"
}

# --- The happy path ----------------------------------------------------------------------------

@test "passes when every script compiles to a self-contained file" {
  publishable alpha 'PROG=$(load_program prog.awk)  # @embed prog.awk'
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 published script(s) are self-contained"* ]]
  [[ "$output" == *"1 program(s) inlined"* ]]
}

@test "a script with no program of its own still counts as self-contained" {
  publishable alpha
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 program(s) inlined"* ]]
}

@test "the working tree is left untouched" {
  publishable alpha 'PROG=$(load_program prog.awk)  # @embed prog.awk'
  local before
  before=$(cat "$FAKE_REPO/scripts/utility/alpha/alpha.sh")
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_REPO/scripts/utility/alpha/alpha.sh")" = "$before" ]
}

# --- What it catches ---------------------------------------------------------------------------

# Without the directive the compiler leaves the loader in place, and the published script tries to read a
# file that no package contains.
@test "a load_program call left in the compiled script fails the check" {
  publishable alpha 'PROG=$(load_program prog.awk)'
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"still reads a program at run time"* ]]
  [[ "$output" == *"Published form check failed."* ]]
}

@test "every offending script is reported, not just the first" {
  publishable alpha 'PROG=$(load_program prog.awk)'
  publishable beta 'PROG=$(load_program prog.awk)'
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alpha.sh still reads"* ]]
  [[ "$output" == *"beta.sh still reads"* ]]
}

@test "one bad script among sound ones fails the run" {
  publishable good 'PROG=$(load_program prog.awk)  # @embed prog.awk'
  publishable bad 'PROG=$(load_program prog.awk)'
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad.sh still reads"* ]]
  [[ "$output" != *"good.sh still reads"* ]]
}

# --- The empty-run guard -----------------------------------------------------------------------

# "All 0 published scripts are self-contained" is true of an empty tree and says nothing, so a walk that
# found nothing is a failure rather than a pass. For this repository, zero means the walk is broken.
@test "a run that finds no scripts is refused rather than passing vacuously" {
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing was checked"* ]]
}

# --- Usage ------------------------------------------------------------------------------------

@test "shows usage on request" {
  run_script "$TOOL" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: check-published-form.sh"* ]]
}

# --- Against this repository ------------------------------------------------------------------

# The check earns its place only if it holds for the scripts this repository actually publishes.
@test "every script in this repository compiles to a self-contained file" {
  run_script "$REPO_ROOT/bin/lint/check-published-form.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"are self-contained"* ]]
}

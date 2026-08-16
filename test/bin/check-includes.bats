#!/usr/bin/env bats
#
# check-includes.sh is the backstop for the arrangement where a script lists only the libraries it uses
# directly and the compiler resolves their dependencies. That leaves one thing unchecked: a script may call
# a function no library it lists provides, and still work — because some other include happens to pull that
# library in. It breaks later, when that other include changes, on whichever path logs.
#
# The fixture library set is written here rather than borrowed from scripts/lib, so the tests state the
# dependency shapes they care about instead of tracking the real split.

load ../test_helper

setup() {
  setup_common
  fake_repo_tool check-includes.sh
  TOOL="$FAKE_TOOL"
  LIB="$FAKE_REPO/scripts/lib"
  mkdir -p "$LIB" "$FAKE_REPO/scripts/utility/thing"

  printf 'log_error() { echo "$*" >&2; }\nlog_info() { echo "$*"; }\n' > "$LIB/core.sh"
  {
    printf '# shellcheck source=./core.sh\n'
    printf 'source "$(dirname "${BASH_SOURCE[0]}")/core.sh"\n'
    printf '# @include core.sh\n'
    printf 'load_config() { :; }\nvalidate_config() { :; }\n'
  } > "$LIB/config.sh"
  printf 'load_program() { :; }\n' > "$LIB/program.sh"
}

########################################
# Writes a script into the fixture tree.
# Arguments:
#   includes: Space-separated library basenames to include, or "none".
# Inputs:
#   The script body, read from stdin.
########################################
make_script() {
  local includes="$1" lib
  {
    printf '#!/usr/bin/env bash\n'
    if [[ "$includes" != none ]]; then
      for lib in $includes; do
        printf '# shellcheck source=../../lib/%s\n' "$lib"
        printf 'source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/%s"\n' "$lib"
        printf '# @include ../../lib/%s\n' "$lib"
      done
    fi
    cat
  } > "$FAKE_REPO/scripts/utility/thing/thing.sh"
  chmod +x "$FAKE_REPO/scripts/utility/thing/thing.sh"
}

# --- Calls must be provided for --------------------------------------------------------------

@test "a script including the library it calls into passes" {
  make_script core.sh <<'EOF'
log_error "boom"
EOF
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"include the libraries they use"* ]]
}

@test "a call with no include at all is reported, naming the library" {
  make_script none <<'EOF'
log_error "boom"
EOF
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"calls log_error, provided by core.sh"* ]]
  [[ "$output" == *"Include check failed"* ]]
}

@test "a call into a library the script does not list is reported" {
  make_script core.sh <<'EOF'
log_error "boom"
load_program prog.awk
EOF
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"calls load_program, provided by program.sh"* ]]
}

# The point of letting the compiler resolve dependencies: a script wanting config need not know that
# config wants core.
@test "a function reached through a library's own dependency is provided" {
  make_script config.sh <<'EOF'
validate_config FOO
log_error "boom"
EOF
  run_script "$TOOL"
  [ "$status" -eq 0 ]
}

# A script with its own log_error is not relying on the library's, so it needs no include for it.
@test "a function the script defines itself is not required from a library" {
  make_script none <<'EOF'
log_error() { printf 'ERROR: %s\n' "$*" >&2; }
log_error "boom"
EOF
  run_script "$TOOL"
  [ "$status" -eq 0 ]
}

# A name in a comment is not a call, or every doc block mentioning a helper would demand an include.
@test "a function named only in a comment is not a call" {
  make_script none <<'EOF'
# This would normally log_error, but it does not.
echo hi
EOF
  run_script "$TOOL"
  [ "$status" -eq 0 ]
}

@test "every missing call is reported, not just the first" {
  make_script none <<'EOF'
log_error "one"
load_program prog.awk
EOF
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"log_error"* ]]
  [[ "$output" == *"load_program"* ]]
}

# --- The loader pair must agree ---------------------------------------------------------------

# Three statements of one fact, and only the directive is acted on: a mismatch publishes a script whose
# development form loaded something else.
@test "a shellcheck hint naming a different library than the directive is reported" {
  {
    printf '#!/usr/bin/env bash\n'
    printf '# shellcheck source=../../lib/program.sh\n'
    printf 'source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"\n'
    printf '# @include ../../lib/core.sh\n'
    printf 'log_error "boom"\n'
  } > "$FAKE_REPO/scripts/utility/thing/thing.sh"
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shellcheck hint names"* ]]
  [[ "$output" == *"program.sh"* ]]
}

@test "a source line loading a different library than the directive is reported" {
  {
    printf '#!/usr/bin/env bash\n'
    printf '# shellcheck source=../../lib/core.sh\n'
    printf 'source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/program.sh"\n'
    printf '# @include ../../lib/core.sh\n'
    printf 'log_error "boom"\n'
  } > "$FAKE_REPO/scripts/utility/thing/thing.sh"
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source loads"* ]]
}

@test "several agreeing pairs in one script pass" {
  make_script "core.sh config.sh program.sh" <<'EOF'
log_error "boom"
validate_config FOO
load_program prog.awk
EOF
  run_script "$TOOL"
  [ "$status" -eq 0 ]
}

# --- Arguments ---------------------------------------------------------------------------------

@test "a named script is checked instead of the whole tree" {
  make_script none <<'EOF'
log_error "boom"
EOF
  run_script "$TOOL" "$FAKE_REPO/scripts/utility/thing/thing.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"All 1 script"* ]] || [[ "$output" == *"calls log_error"* ]]
}

@test "a script that does not exist is reported" {
  run_script "$TOOL" "$FAKE_REPO/scripts/utility/absent.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Script not found"* ]]
}

@test "shows usage on request" {
  run_script "$TOOL" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: check-includes.sh"* ]]
}

# --- Against this repository -------------------------------------------------------------------

# The check earns its place only if it holds for the scripts as they are.
@test "every script in this repository includes what it uses" {
  run_script "$REPO_ROOT/bin/check-includes.sh"
  [ "$status" -eq 0 ]
}

#!/usr/bin/env bats
#
# compile-includes.sh turns a development script — which sources scripts/lib/common.sh at run time —
# into the self-contained form that gets published. It runs on every release for every script that
# has an @include, so a fault here ships broken packages for the whole repository at once, and would
# most likely show up only when a user ran the installed script.

load test_helper

setup() {
  setup_common
  TOOL="$REPO_ROOT/bin/compile-includes.sh"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/lib"
  printf 'LIBRARY LINE ONE\nLIBRARY LINE TWO\n' > "$WORK/lib/common.sh"
}

########################################
# Writes a script under test into the work directory.
# Arguments:
#   name: Filename to create inside the work directory.
# Inputs:
#   The file's contents, read from stdin.
# Outputs:
#   Prints the path of the created file.
########################################
script_fixture() {
  cat > "$WORK/$1"
  printf '%s' "$WORK/$1"
}

# --- Argument handling -------------------------------------------------------------------------

@test "shows usage for -h" {
  run_script "$TOOL" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: compile-includes.sh"* ]]
  [[ "$output" == *"-i"* ]]
}

@test "refuses to run without an input file" {
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required input file argument."* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "reports an input file that does not exist" {
  run_script "$TOOL" "$WORK/absent.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Input file not found: "*"absent.sh"* ]]
}

# --- Include expansion -------------------------------------------------------------------------

@test "replaces an @include directive with the file's contents" {
  local f; f=$(script_fixture main.sh <<'EOF'
echo before
# @include lib/common.sh
echo after
EOF
)
  run_script "$TOOL" "$f"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "echo before" ]
  [ "${lines[1]}" = "LIBRARY LINE ONE" ]
  [ "${lines[2]}" = "LIBRARY LINE TWO" ]
  [ "${lines[3]}" = "echo after" ]
}

@test "drops the development-time source line that precedes an @include" {
  local f; f=$(script_fixture main.sh <<'EOF'
source "$(dirname "$0")/lib/common.sh"
# @include lib/common.sh
EOF
)
  run_script "$TOOL" "$f"
  [[ "$output" != *"dirname"* ]]
  [[ "$output" == *"LIBRARY LINE ONE"* ]]
}

@test "strips the shellcheck source directive, which is meaningless once inlined" {
  local f; f=$(script_fixture main.sh <<'EOF'
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# @include lib/common.sh
EOF
)
  run_script "$TOOL" "$f"
  [[ "$output" != *"shellcheck source="* ]]
  [[ "$output" == *"LIBRARY LINE ONE"* ]]
}

@test "keeps a source line that is not followed by an @include" {
  local f; f=$(script_fixture main.sh <<'EOF'
source "some/other/thing.sh"
echo end
EOF
)
  run_script "$TOOL" "$f"
  [ "${lines[0]}" = 'source "some/other/thing.sh"' ]
  [ "${lines[1]}" = "echo end" ]
}

@test "keeps a trailing source line at end of file" {
  local f; f=$(script_fixture main.sh <<'EOF'
echo start
source "trailing/thing.sh"
EOF
)
  run_script "$TOOL" "$f"
  [ "${lines[1]}" = 'source "trailing/thing.sh"' ]
}

@test "accepts a quoted include path" {
  local f; f=$(script_fixture main.sh <<'EOF'
# @include "lib/common.sh"
EOF
)
  run_script "$TOOL" "$f"
  [ "${lines[0]}" = "LIBRARY LINE ONE" ]
}

@test "accepts an indented include directive" {
  local f; f=$(script_fixture main.sh <<'EOF'
  #  @include lib/common.sh
EOF
)
  run_script "$TOOL" "$f"
  [ "${lines[0]}" = "LIBRARY LINE ONE" ]
}

@test "expands the same include more than once" {
  local f; f=$(script_fixture main.sh <<'EOF'
# @include lib/common.sh
middle
# @include lib/common.sh
EOF
)
  run_script "$TOOL" "$f"
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'LIBRARY LINE ONE'" _ "$output"
  [ "$output" = "2" ]
}

# Includes are expanded by concatenation, not recursively, so a directive inside an included file is
# emitted as text. Nothing in this repository nests includes; the assertion records the boundary so a
# script that tried to would fail visibly here rather than ship a literal comment.
@test "does not expand an @include nested inside an included file" {
  printf 'OUTER LIB\n# @include deeper.sh\n' > "$WORK/lib/outer.sh"
  printf 'DEEPER\n' > "$WORK/lib/deeper.sh"
  local f; f=$(script_fixture main.sh <<'EOF'
# @include lib/outer.sh
EOF
)
  run_script "$TOOL" "$f"
  [ "${lines[0]}" = "OUTER LIB" ]
  [ "${lines[1]}" = "# @include deeper.sh" ]
  [[ "$output" != *"DEEPER"* ]]
}

@test "fails when an include target is missing" {
  local f; f=$(script_fixture main.sh <<'EOF'
# @include lib/absent.sh
EOF
)
  run_script "$TOOL" "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Include file not found:"*"lib/absent.sh"* ]]
}

@test "resolves includes relative to the input file, not the working directory" {
  mkdir -p "$WORK/nested/lib"
  printf 'NESTED LIB\n' > "$WORK/nested/lib/common.sh"
  printf '# @include lib/common.sh\n' > "$WORK/nested/main.sh"
  cd "$BATS_TEST_TMPDIR"
  run_script "$TOOL" "$WORK/nested/main.sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "NESTED LIB" ]
}

# --- Output destinations -----------------------------------------------------------------------

@test "writes to stdout when given no destination" {
  local f; f=$(script_fixture main.sh <<'EOF'
# @include lib/common.sh
EOF
)
  run_script "$TOOL" "$f"
  [[ "$output" == *"LIBRARY LINE ONE"* ]]
  # The input must be left alone.
  [[ "$(cat "$f")" == *"@include"* ]]
}

@test "writes to an explicit output file, creating its parent directory" {
  local f; f=$(script_fixture main.sh <<'EOF'
# @include lib/common.sh
EOF
)
  run_script "$TOOL" "$f" "$WORK/out/deep/compiled.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORK/out/deep/compiled.sh" ]
  [[ "$(cat "$WORK/out/deep/compiled.sh")" == *"LIBRARY LINE ONE"* ]]
}

@test "rewrites the input in place with -i" {
  local f; f=$(script_fixture main.sh <<'EOF'
# @include lib/common.sh
EOF
)
  run_script "$TOOL" "$f" -i
  [ "$status" -eq 0 ]
  [[ "$(cat "$f")" == *"LIBRARY LINE ONE"* ]]
  [[ "$(cat "$f")" != *"@include"* ]]
}

# An in-place rewrite copies over the original file rather than moving a temp file onto it,
# specifically so the mode survives. mktemp creates 0600, and a published script that lost its
# read bit could not be executed by its interpreter after install.
@test "in-place rewriting preserves the file's mode" {
  local f; f=$(script_fixture main.sh <<'EOF'
# @include lib/common.sh
EOF
)
  chmod 0755 "$f"
  run_script "$TOOL" "$f" -i
  [ "$status" -eq 0 ]
  # GNU stat first, then BSD, so the assertion holds on Linux and macOS alike.
  run bash -c "stat -c '%a' '$f' 2>/dev/null || stat -f '%Lp' '$f'"
  [ "$output" = "755" ]
}

@test "compiling a script with no includes leaves it unchanged" {
  local f; f=$(script_fixture plain.sh <<'EOF'
echo one
echo two
EOF
)
  run_script "$TOOL" "$f"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "echo one" ]
  [ "${lines[1]}" = "echo two" ]
}

# --- The real library --------------------------------------------------------------------------

# The published form of every @include-using script is produced by this path, so it is worth one
# assertion against the actual library rather than a fixture.
@test "inlines the real shared library into a real script" {
  cp -R "$REPO_ROOT/scripts" "$BATS_TEST_TMPDIR/scripts"
  run_script "$TOOL" "$BATS_TEST_TMPDIR/scripts/system/local-backup/local-backup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_COMMON_SH_LOADED"* ]]
  [[ "$output" == *"validate_config()"* ]]
  [[ "$output" != *"@include"* ]]
  # The script's own directive naming the library is gone, since there is nothing left to resolve.
  [[ "$output" != *"shellcheck source=../lib/common.sh"* ]]
  # The library's own `shellcheck source=/dev/null` must survive: included files are concatenated
  # verbatim, and the published script still sources a config file at that point.
  [[ "$output" == *"shellcheck source=/dev/null"* ]]
}

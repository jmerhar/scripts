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

# --- The @embed directive ----------------------------------------------------------------------
#
# An awk or jq program lives in a file beside its script so it can be highlighted, syntax-checked and
# kept out of the coverage measurement. Published scripts are single files, so the directive inlines the
# program as a literal. The development form and the published form must hold exactly the same text —
# a difference there means the tests exercise one program and users run another.

########################################
# Writes a program file into the work directory.
# Arguments:
#   name: Filename to create.
# Inputs:
#   The program text, read from stdin.
########################################
program_fixture() {
  cat > "$WORK/$1"
}

@test "an @embed line becomes the same assignment holding the program" {
  program_fixture sum.awk <<'EOF'
BEGIN { total = 0 }
{ total += $1 }
END { print total }
EOF
  local script
  script=$(script_fixture embed.sh <<'EOF'
#!/usr/bin/env bash
_AWK_SUM=$(load_program sum.awk)  # @embed sum.awk
printf '%s\n' 1 2 3 | awk "${_AWK_SUM}"
EOF
)
  run_script "$TOOL" "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_AWK_SUM='BEGIN { total = 0 }"* ]]
  [[ "$output" == *"END { print total }'"* ]]
  [[ "$output" != *"load_program"* ]]
  [[ "$output" != *"@embed"* ]]
}

# The point of the whole mechanism: what the published script runs must behave as the development form
# does. Both are executed here rather than compared as text, since text equality would not prove the
# quoting survived.
@test "the compiled script produces what the development form produces" {
  program_fixture sum.awk <<'EOF'
{ total += $1 }
END { print total + 0 }
EOF
  cp "$REPO_ROOT/scripts/lib/common.sh" "$WORK/common.sh"
  cat > "$WORK/dev.sh" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
SCRIPT_NAME="$(basename "$0" .sh)"
source "$(cd "$(dirname "$0")" && pwd -P)/common.sh"
_AWK_SUM=$(load_program sum.awk)  # @embed sum.awk
printf '%s
' 4 5 6 | awk "${_AWK_SUM}"
EOF
  chmod +x "$WORK/dev.sh"
  run bash "$WORK/dev.sh"
  [ "$status" -eq 0 ]
  local from_dev="$output"

  run_script "$TOOL" "$WORK/dev.sh" "$WORK/pub.sh"
  run bash "$WORK/pub.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$from_dev" ]
  [ "$output" = "15" ]
}

# `$(...)` strips trailing newlines, so a literal that kept them would give the published script a
# different string from the one the development form loads.
@test "trailing newlines in the program file are not embedded" {
  printf 'BEGIN { print "x" }\n\n\n' > "$WORK/trail.awk"
  local script
  script=$(script_fixture trail.sh <<'EOF'
#!/usr/bin/env bash
_P=$(load_program trail.awk)  # @embed trail.awk
EOF
)
  run_script "$TOOL" "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_P='BEGIN { print \"x\" }'"* ]]
}

# A program embedded single-quoted is handed to awk or jq untouched, which is the whole reason for the
# quoting: `$1` is an awk field, not a shell argument.
@test "shell metacharacters in the program are embedded literally" {
  program_fixture meta.awk <<'EOF'
{ print $1, $NF, "`backtick`", "${brace}" }
EOF
  local script
  script=$(script_fixture meta.sh <<'EOF'
#!/usr/bin/env bash
_P=$(load_program meta.awk)  # @embed meta.awk
EOF
)
  run_script "$TOOL" "$script"
  [[ "$output" == *'$1, $NF'* ]]
  [[ "$output" == *'`backtick`'* ]]
  [[ "$output" == *'${brace}'* ]]
}

@test "indentation and a local declaration are preserved" {
  program_fixture ind.awk <<'EOF'
{ print }
EOF
  local script
  script=$(script_fixture ind.sh <<'EOF'
#!/usr/bin/env bash
f() {
  local prog
  prog=$(load_program ind.awk)  # @embed ind.awk
}
EOF
)
  run_script "$TOOL" "$script"
  [[ "$output" == *"  prog='{ print }'"* ]]
}

@test "a script may embed more than one program" {
  program_fixture one.awk <<'EOF'
{ print "one" }
EOF
  program_fixture two.jq <<'EOF'
.[] | .name
EOF
  local script
  script=$(script_fixture multi.sh <<'EOF'
#!/usr/bin/env bash
_A=$(load_program one.awk)  # @embed one.awk
_B=$(load_program two.jq)  # @embed two.jq
EOF
)
  run_script "$TOOL" "$script"
  [[ "$output" == *"_A='{ print \"one\" }'"* ]]
  [[ "$output" == *"_B='.[] | .name'"* ]]
}

@test "@embed and @include can appear in the same script" {
  program_fixture both.awk <<'EOF'
{ print }
EOF
  local script
  script=$(script_fixture both.sh <<'EOF'
#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# @include lib/common.sh
_P=$(load_program both.awk)  # @embed both.awk
EOF
)
  run_script "$TOOL" "$script"
  [[ "$output" == *"LIBRARY LINE ONE"* ]]
  [[ "$output" == *"_P='{ print }'"* ]]
  [[ "$output" != *"@include"* ]]
  [[ "$output" != *"source "* ]]
}

# --- The @embed guards -------------------------------------------------------------------------

# The directive and the call name are two statements of the same fact, and the compiler acts on the
# directive. If they drift, the published script holds a program the development form never ran.
@test "a directive naming a different program than the call is refused" {
  program_fixture right.awk <<'EOF'
{ print }
EOF
  program_fixture wrong.awk <<'EOF'
{ exit 1 }
EOF
  local script
  script=$(script_fixture drift.sh <<'EOF'
#!/usr/bin/env bash
_P=$(load_program right.awk)  # @embed wrong.awk
EOF
)
  run_script "$TOOL" "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"@embed names 'wrong.awk'"* ]]
  [[ "$output" == *"load_program is called with 'right.awk'"* ]]
}

# The program is embedded inside single quotes, so a single quote in it would end the string early and
# publish a script that is not even valid bash.
@test "a program containing a single quote is refused" {
  printf 'BEGIN { print "it%ss here" }\n' "'" > "$WORK/apos.awk"
  local script
  script=$(script_fixture apos.sh <<'EOF'
#!/usr/bin/env bash
_P=$(load_program apos.awk)  # @embed apos.awk
EOF
)
  run_script "$TOOL" "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"contains a single quote"* ]]
}

@test "a missing program file is refused, naming it" {
  local script
  script=$(script_fixture absent.sh <<'EOF'
#!/usr/bin/env bash
_P=$(load_program nowhere.awk)  # @embed nowhere.awk
EOF
)
  run_script "$TOOL" "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Program file not found"* ]]
  [[ "$output" == *"nowhere.awk"* ]]
}

# Documentation shows the pattern, and a comment is not code: acting on an example would make any file
# that documents @embed — the shared library among them — impossible to compile.
@test "a commented-out example is not treated as a directive" {
  local script
  script=$(script_fixture doc.sh <<'EOF'
#!/usr/bin/env bash
# The call site looks like this:
#   _P=$(load_program candidates.jq)  # @embed candidates.jq
echo body
EOF
)
  run_script "$TOOL" "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *'#   _P=$(load_program candidates.jq)  # @embed candidates.jq'* ]]
  [[ "$output" == *"echo body"* ]]
}

# An ordinary assignment must not be touched: the directive is what marks a line for embedding, and
# without it the line is just code.
@test "an assignment without the directive is left alone" {
  local script
  script=$(script_fixture plain.sh <<'EOF'
#!/usr/bin/env bash
_P=$(load_program something.awk)
other=$(date)
EOF
)
  run_script "$TOOL" "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *'_P=$(load_program something.awk)'* ]]
  [[ "$output" == *'other=$(date)'* ]]
}

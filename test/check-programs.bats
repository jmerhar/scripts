#!/usr/bin/env bats
#
# check-programs.sh is the reason for keeping awk and jq programs in files: a typo in a filter that
# decides which torrents to delete otherwise surfaces mid-run, on the server, after the confirmation
# prompt. So the checker itself has to be known to fail — a syntax checker nobody has watched reject
# something is not known to work.
#
# The two cases worth most attention are the ones where a valid program looks invalid: jq reports an
# undefined variable with the same exit status as a syntax error, and a filter written for object input
# fails at run time when handed the null this checker feeds it. Reading either as "broken" would make the
# check unusable for exactly the filters it exists to protect.

load test_helper

setup() {
  setup_common
  TOOL="$REPO_ROOT/bin/check-programs.sh"
  DIR="$BATS_TEST_TMPDIR/programs"
  mkdir -p "$DIR"
}

########################################
# Writes a program file into the fixture directory.
# Arguments:
#   name: Filename to create.
# Inputs:
#   The program text, read from stdin.
########################################
program() {
  cat > "$DIR/$1"
}

# --- Valid programs ----------------------------------------------------------------------------

@test "reports success and a count when every program parses" {
  program a.awk <<'EOF'
BEGIN { print "hi" }
EOF
  program b.jq <<'EOF'
.name
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 program(s) parse."* ]]
}

@test "an empty directory passes with a count of zero" {
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 0 program(s) parse."* ]]
}

@test "programs in subdirectories are found" {
  mkdir -p "$DIR/nested/deeper"
  printf 'BEGIN { print 1 }\n' > "$DIR/nested/deeper/x.awk"
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 1 program(s) parse."* ]]
}

@test "files that are not programs are ignored" {
  program keep.awk <<'EOF'
BEGIN { print 1 }
EOF
  printf 'this is not awk at all {{{\n' > "$DIR/notes.txt"
  printf 'SETTING=1\n' > "$DIR/thing.conf"
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 1 program(s) parse."* ]]
}

# --- Broken awk --------------------------------------------------------------------------------

@test "a broken awk program fails, naming the file" {
  program broken.awk <<'EOF'
BEGIN { print "unterminated
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broken.awk is not valid awk"* ]]
  [[ "$output" == *"Program syntax check failed."* ]]
}

# Only the location is asserted, not the wording: the awk on macOS says "syntax error at source line 1"
# and the mawk in the Linux container says "line 1: missing ) near }". What matters is that whichever
# diagnostic awk produced reaches the reader instead of being discarded with the exit status.
@test "awk's own diagnostic is shown, not swallowed" {
  program broken.awk <<'EOF'
BEGIN { if ( }
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 1"* ]]
}

# --- Broken jq ---------------------------------------------------------------------------------

@test "a broken jq program fails, naming the file" {
  program broken.jq <<'EOF'
.a |
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broken.jq is not valid jq"* ]]
}

# jq exits 3 both for a syntax error and for a variable it never received, so a filter that expects
# --arg values has to declare them or it is reported for the wrong reason.
@test "a filter using an undeclared variable fails, with the fix named" {
  program needs-args.jq <<'EOF'
$prefix + .name
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not valid jq"* ]]
  [[ "$output" == *"lint-args"* ]]
}

@test "a lint-args header supplies the variables the filter expects" {
  program with-args.jq <<'EOF'
# lint-args: --arg prefix /mnt --argjson ratio 0.5
$prefix + "/x" | length > $ratio
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 1 program(s) parse."* ]]
}

# The checker feeds null, so a filter written for object input fails at run time. That says nothing
# about whether the filter compiles, and treating it as a failure would reject every filter the
# repository actually has.
@test "a filter that cannot run against null input still passes the check" {
  program object-input.jq <<'EOF'
to_entries[] | .key
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 1 program(s) parse."* ]]
}

# --- Embeddability -----------------------------------------------------------------------------
#
# The rule is scoped by path — programs under scripts/ are embedded, those under bin/ are not — and the
# tool derives that root from its own location. So these run a copy of the tool in a fake repository,
# which is what keeps the fixtures inside the test's temp directory: a probe file written into the real
# scripts/ would be left behind by a failing test and break `make lint` afterwards.

########################################
# Writes a program containing an apostrophe into the fake repository.
# Arguments:
#   dir: Directory relative to the fake repository root.
########################################
apostrophe_program() {
  mkdir -p "$FAKE_REPO/$1"
  printf "# it%ss a comment\nBEGIN { print 1 }\n" "'" > "$FAKE_REPO/$1/probe.awk"
}

# A published script is one file, so a program under scripts/ is always inlined as a single-quoted
# literal. A single quote in it — an apostrophe in a comment being the likely way — would end that
# literal early. The compiler refuses it as well, but only at packaging time, which is after a push.
@test "a single quote in a program under scripts/ is refused, quoting the line" {
  fake_repo_tool check-programs.sh
  apostrophe_program scripts/utility/thing
  run_script "$FAKE_TOOL" "$FAKE_REPO/scripts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains a single quote"* ]]
  [[ "$output" == *"a comment"* ]]
}

# The tools under bin/ are never published as a single file and run their programs with `awk -f`, so an
# apostrophe in one is harmless and must not fail the build.
@test "a single quote in a program under bin/ is allowed" {
  fake_repo_tool check-programs.sh
  apostrophe_program bin
  run_script "$FAKE_TOOL" "$FAKE_REPO/bin"
  [ "$status" -eq 0 ]
  [[ "$output" != *"contains a single quote"* ]]
}

# --- Reporting ---------------------------------------------------------------------------------

@test "every broken program is reported, not just the first" {
  program one.awk <<'EOF'
BEGIN { if ( }
EOF
  program two.jq <<'EOF'
.a |
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"one.awk"* ]]
  [[ "$output" == *"two.jq"* ]]
}

@test "one broken program among sound ones fails the run" {
  program good.awk <<'EOF'
BEGIN { print 1 }
EOF
  program bad.awk <<'EOF'
BEGIN { if ( }
EOF
  program alsogood.jq <<'EOF'
.name
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad.awk"* ]]
  [[ "$output" != *"good.awk is not valid"* ]]
}

@test "a failure is annotated for GitHub Actions under CI" {
  program bad.awk <<'EOF'
BEGIN { if ( }
EOF
  GITHUB_ACTIONS=true run_script "$TOOL" "$DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

# GITHUB_ACTIONS is set for the whole job when the suite runs in CI, so it has to be cleared explicitly
# rather than assumed absent — otherwise this passes only on a developer machine.
@test "no annotations outside Actions" {
  program bad.awk <<'EOF'
BEGIN { if ( }
EOF
  GITHUB_ACTIONS= run_script "$TOOL" "$DIR"
  [ "$status" -ne 0 ]
  [[ "$output" != *"::error::"* ]]
}

# --- Arguments and prerequisites ---------------------------------------------------------------

@test "shows usage on request" {
  run_script "$TOOL" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: check-programs.sh"* ]]
}

@test "a directory that does not exist is reported" {
  run_script "$TOOL" "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Directory not found"* ]]
}

@test "several directories can be given, and all are searched" {
  local other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  program a.awk <<'EOF'
BEGIN { print 1 }
EOF
  printf 'BEGIN { print 2 }\n' > "$other/b.awk"
  run_script "$TOOL" "$DIR" "$other"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 program(s) parse."* ]]
}

@test "a missing jq is reported rather than silently skipping the filters" {
  program a.jq <<'EOF'
.name
EOF
  local minimal="$BATS_TEST_TMPDIR/minimal-bin" cmd
  mkdir -p "$minimal"
  for cmd in bash basename dirname find sort sed awk date printf cat; do
    [ -e "$(command -v "$cmd" 2>/dev/null)" ] && ln -sf "$(command -v "$cmd")" "$minimal/$cmd"
  done
  run env PATH="$minimal" "$(command -v bash)" "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq"*"required"* ]]
}

# --- Against this repository's own programs ----------------------------------------------------

# The check earns its place only if it holds for the programs the scripts actually run.
@test "every program in this repository parses" {
  run_script "$REPO_ROOT/bin/check-programs.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"program(s) parse."* ]]
}

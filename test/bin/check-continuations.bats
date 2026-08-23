#!/usr/bin/env bats
#
# check-continuations.sh exists because the thing it looks for is invisible: a `\` continuation costs
# coverage lines silently, so seventeen of them accumulated in a repository whose own notes claimed there
# were none. A checker for an invisible fault has to be known to reject something, or it is indistinguishable
# from one that reads nothing.
#
# The case worth most attention is the line ending in two backslashes. That is not a continuation — the
# final backslash is a literal and the command ends — so flagging it would report a fault in correct code
# and, worse, teach whoever hits it to distrust the check.
#
# The tool takes directory roots, so most tests hand it a temp directory of hand-written files. The
# coverage harness is the exception: proving that nothing under bin/ is exempt needs the fake repository
# fixture, where the tool's own location decides what the repository root is.

load ../test_helper

setup() {
  setup_common
  TOOL="$REPO_ROOT/bin/lint/check-continuations.sh"
  DIR="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$DIR"
}

########################################
# Writes a shell file into the fixture directory.
# Arguments:
#   name: Filename to create.
# Inputs:
#   The file contents, read from stdin.
########################################
file_at() {
  cat > "$DIR/$1"
}

# --- Files that pass ---------------------------------------------------------------------------

@test "reports success and a count when no file carries a continuation" {
  file_at a.sh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "one long line that says everything it needs to"
EOF
  file_at b.sh <<'EOF'
#!/usr/bin/env bash
: nothing to see
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 shell file(s) are free of line continuations."* ]]
}

@test "a line ending in an escaped backslash is not a continuation" {
  # `: ending\\` passes a literal backslash and ends there; bash reads no following line, and kcov sees
  # nothing unusual. Reporting it would be a fault found in correct code.
  printf '#!/usr/bin/env bash\n: ending\\\\\n: next\n' > "$DIR/escaped.sh"
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
}

@test "files that are not shell are left alone" {
  # An awk or jq program is not measured as bash, and a continuation is idiomatic in awk.
  printf 'BEGIN { x = 1 + \\\n 2 }\n' > "$DIR/prog.awk"
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 0 shell file(s)"* ]]
}

# --- Files that fail ---------------------------------------------------------------------------

@test "a continuation is reported with its file and line" {
  printf '#!/usr/bin/env bash\n: one \\\n  two\n' > "$DIR/bad.sh"
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.sh:2 ends with a line continuation"* ]]
}

@test "every continuation in a file is reported, not just the first" {
  printf '#!/usr/bin/env bash\n: one \\\n  two\n: three \\\n  four\n' > "$DIR/bad.sh"
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  # Counted on the [ERROR]: prefix rather than the message, since log.sh prints each one twice under
  # GITHUB_ACTIONS. Three: one per continuation, plus the closing explanation.
  [ "$(printf '%s\n' "$output" | grep -c '\[ERROR\]:')" -eq 3 ]
}

@test "a continuation in one file does not stop the others being read" {
  printf '#!/usr/bin/env bash\n: one \\\n  two\n' > "$DIR/a-bad.sh"
  printf '#!/usr/bin/env bash\n: three \\\n  four\n' > "$DIR/z-bad.sh"
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a-bad.sh:2"* ]]
  [[ "$output" == *"z-bad.sh:2"* ]]
}

@test "the failure says what to do about it" {
  # The fix is not obvious from the finding: a continuation looks like tidy formatting, and the reason it
  # is not is a property of kcov nobody reads a diff for.
  printf '#!/usr/bin/env bash\n: one \\\n  two\n' > "$DIR/bad.sh"
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"one long line"* ]]
}

@test "a continuation on the last line of a file is still reported" {
  # No trailing newline and nothing after it, which is the shape a `\` left behind by an edit takes.
  printf '#!/usr/bin/env bash\n: dangling \\' > "$DIR/bad.sh"
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.sh:2"* ]]
}

# --- Nothing is exempt -------------------------------------------------------------------------

@test "the coverage harness is not exempt, though nothing measures it" {
  # bin/coverage/ is kept out of the report, so a continuation there costs no coverage — and it was
  # exempt on that reasoning until the thirty-line docker invocation hiding behind the exemption made the
  # case against it. A continuation costs a reader whatever kcov does.
  fake_repo_tool check-continuations.sh
  fake_repo_replace_tool run-coverage.sh <<'EOF'
#!/usr/bin/env bash
docker run --rm \
  -v x:y image
EOF
  run_script "$FAKE_TOOL" "$FAKE_REPO/bin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run-coverage.sh:2"* ]]
}

@test "a continuation in any other bin tool is reported too" {
  fake_repo_tool check-continuations.sh
  fake_repo_replace_tool check-manifest.sh <<'EOF'
#!/usr/bin/env bash
: one \
  two
EOF
  run_script "$FAKE_TOOL" "$FAKE_REPO/bin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"check-manifest.sh:2"* ]]
}

# --- The command line --------------------------------------------------------------------------

@test "defaults to scripts/ and bin/, which is what kcov measures" {
  # Run with no arguments against the real tree, which make lint keeps clean — so this both exercises the
  # default roots and asserts the repository's own claim.
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"free of line continuations"* ]]
}

@test "a root that does not exist is an error rather than an empty pass" {
  run_script "$TOOL" "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Directory not found"* ]]
}

@test "-h prints usage and exits 0" {
  run_script "$TOOL" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"line continuation"* ]]
}

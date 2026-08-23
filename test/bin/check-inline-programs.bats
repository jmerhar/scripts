#!/usr/bin/env bats
#
# check-inline-programs.sh enforces the other half of the rule check-continuations.sh covers: a command
# spread over several lines is attributed by bash to its final line, so kcov counts the first as dead and
# does not instrument the middle at all. A quoted multi-line awk or jq program is the way that shape
# reaches this repository, and three of them were sitting in dmarc-report while the notes claimed there
# were none.
#
# Detection is per line and textual, so the tests that matter most are the ones where a valid line looks
# like a violation: an apostrophe in a comment, a program legitimately written on one line, and the word
# jq appearing as a file extension. A checker that cried wolf over any of those would be turned off.

load ../test_helper

setup() {
  setup_common
  TOOL="$REPO_ROOT/bin/lint/check-inline-programs.sh"
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

# --- Scripts that pass -------------------------------------------------------------------------

@test "reports success and a count when no script holds a multi-line program" {
  file_at a.sh <<'EOF'
#!/usr/bin/env bash
prog=$(load_program candidates.jq)  # @embed candidates.jq
jq "${args[@]}" "${prog}" <<<"${status}"
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 1 script(s) keep their awk and jq programs"* ]]
}

@test "a program written on one line is left alone" {
  # It costs one measured line like any other statement, and a file for it would read worse.
  file_at ok.sh <<'EOF'
#!/usr/bin/env bash
awk -v mb="$1" 'BEGIN { printf "%.1f GB\n", mb / 1024 }'
awk -F'\t' '$12 == 1 && $6 != "none" {b += $5} END {print b + 0}' "$file"
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
}

@test "an apostrophe in a comment is not an unterminated program" {
  # The likeliest false positive in a repository whose comments are prose: a lone apostrophe on a line
  # that also mentions awk.
  file_at prose.sh <<'EOF'
#!/usr/bin/env bash
# awk's field splitting is what this relies on
awk '{print}' file  # it's fine
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
}

@test "a .jq filename is not a jq invocation" {
  file_at ext.sh <<'EOF'
#!/usr/bin/env bash
prog=$(load_program strays.jq)  # @embed strays.jq
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
}

@test "a multi-line quoted argument to another command is not reported" {
  # dmarc-report's xmllint --xpath expressions have no program-file option and contain single quotes, so
  # they cannot be extracted at all. Reporting them would leave a check that can never pass.
  file_at xpath.sh <<'EOF'
#!/usr/bin/env bash
xmllint --xpath '
  //record/row
' "$file"
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
}

@test "an apostrophe inside a double-quoted string does not desynchronise the line" {
  file_at quoted.sh <<'EOF'
#!/usr/bin/env bash
awk -v msg="the receiver's verdict" '{print msg}' file
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 0 ]
}

# --- Scripts that fail -------------------------------------------------------------------------

@test "a program opened with a bare quote is reported" {
  file_at bad.sh <<'EOF'
#!/usr/bin/env bash
awk '
  BEGIN { print 1 }
' file
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.sh:2 opens an awk or jq program that does not end on that line"* ]]
}

@test "a program whose first line carries code is reported" {
  # The shape a naive check misses, because the line does not end with the quote it opened — and the
  # shape one of dmarc-report's three violations actually had.
  file_at bad.sh <<'EOF'
#!/usr/bin/env bash
if awk -F'\t' '$1 == "policy" {found = 1}
   END {exit !found}' "$flags"; then
  :
fi
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.sh:2"* ]]
}

@test "a multi-line jq filter is reported as well as an awk one" {
  file_at bad.sh <<'EOF'
#!/usr/bin/env bash
jq -r '
  .torrents | to_entries
' <<<"$status"
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.sh:2"* ]]
}

@test "a program opened inside a command substitution is reported" {
  file_at bad.sh <<'EOF'
#!/usr/bin/env bash
read -r pass fail <<<"$(awk -F'\t' '
  { p += $5 }
  END { printf "%d", p }' "$tsv")"
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.sh:2"* ]]
}

@test "every offending line in a file is reported, not just the first" {
  file_at bad.sh <<'EOF'
#!/usr/bin/env bash
awk '
  BEGIN { print 1 }
' file
jq '
  .name
' <<<"$json"
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  # Counted on the [ERROR]: prefix rather than the message, since log.sh prints each one twice under
  # GITHUB_ACTIONS. Three: one per offending line, plus the closing instruction.
  [ "$(printf '%s\n' "$output" | grep -c '\[ERROR\]:')" -eq 3 ]
}

@test "the failure says where the program should go instead" {
  file_at bad.sh <<'EOF'
#!/usr/bin/env bash
awk '
  BEGIN { print 1 }
' file
EOF
  run_script "$TOOL" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"@embed"* ]]
  [[ "$output" == *"awk -f"* ]]
}

# --- The command line --------------------------------------------------------------------------

@test "defaults to scripts/ and bin/, and the real tree passes" {
  # Both exercises the default roots and asserts the repository's own claim, which was false for three
  # programs in dmarc-report until this check existed.
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep their awk and jq programs"* ]]
}

@test "a root that does not exist is an error rather than an empty pass" {
  run_script "$TOOL" "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Directory not found"* ]]
}

@test "a missing detector program is an error, not a silent pass" {
  # The detector is a file beside the tool, so a rename or a partial install would otherwise leave the
  # check reading nothing and reporting success.
  fake_repo_tool check-inline-programs.sh
  rm -f "$FAKE_REPO/bin/lint/inline-programs.awk"
  run_script "$FAKE_TOOL" "$FAKE_REPO/bin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Detector program not found"* ]]
}

@test "-h prints usage and exits 0" {
  run_script "$TOOL" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"multi-line awk or jq"* ]]
}

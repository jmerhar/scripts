#!/usr/bin/env bats
#
# scripts/lib/program.sh reads the awk and jq programs a script keeps beside itself. It is the development
# half of the @embed mechanism: bin/compile/compile-includes.sh replaces each call with the program's text, so what
# this returns has to be exactly what gets embedded, and a program it cannot read has to stop the run —
# awk and jq both accept an empty program and print nothing.

load ../test_helper

setup() { setup_common; }

# --- load_program ------------------------------------------------------------------------------
#
# load_program is the development half of the @embed mechanism: it reads an awk or jq program from a file
# beside the script, and bin/compile/compile-includes.sh replaces the call with the program text on the way to a
# package. So the text it returns has to be exactly what gets embedded, and a program it cannot read has
# to stop the run — awk and jq both accept an empty program and print nothing, which would turn a
# packaging mistake into a script that silently finds no results.

@test "load_program reads a program from beside the script" {
  local tool; tool=$(lib_at opt/tools progtool program.sh)
  printf 'BEGIN { print "hello" }\n' > "$BATS_TEST_TMPDIR/opt/tools/greet.awk"
  run_snippet "$tool" 'load_program greet.awk'
  [ "$status" -eq 0 ]
  [ "$output" = 'BEGIN { print "hello" }' ]
}

@test "load_program returns a multi-line program intact" {
  local tool; tool=$(lib_at opt/tools progtool program.sh)
  printf '{ n += $1 }\nEND { print n + 0 }\n' > "$BATS_TEST_TMPDIR/opt/tools/sum.awk"
  run_snippet "$tool" 'load_program sum.awk'
  [ "${lines[0]}" = '{ n += $1 }' ]
  [ "${lines[1]}" = 'END { print n + 0 }' ]
}

# The program is resolved against the script, not the working directory, so a script called by an
# absolute path from anywhere still finds its own programs.
@test "load_program resolves against the script's directory, not the caller's" {
  local tool; tool=$(lib_at opt/tools progtool program.sh)
  printf 'BEGIN { print "beside" }\n' > "$BATS_TEST_TMPDIR/opt/tools/where.awk"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  printf 'BEGIN { print "decoy" }\n' > "$BATS_TEST_TMPDIR/elsewhere/where.awk"
  cd "$BATS_TEST_TMPDIR/elsewhere"
  run_snippet "$tool" 'load_program where.awk'
  [ "$output" = 'BEGIN { print "beside" }' ]
}

# An empty program is a valid program to awk and jq, so returning "" for a missing file would hide the
# mistake and report no matches instead of failing.
@test "load_program is fatal when the program is missing" {
  local tool; tool=$(lib_at opt/tools progtool program.sh)
  run_snippet "$tool" 'load_program nowhere.awk; echo "kept going"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Program file not found or not readable"* ]]
  [[ "$output" == *"nowhere.awk"* ]]
  [[ "$output" != *"kept going"* ]]
}

@test "load_program is fatal when the program cannot be read" {
  # Root can read a mode-000 file, so -r is true there and the refusal is unreachable — which is the
  # case in the Linux coverage job.
  [ "${EUID:-$(id -u)}" -ne 0 ] || skip "mode 000 is still readable as root"
  local tool; tool=$(lib_at opt/tools progtool program.sh)
  local prog="$BATS_TEST_TMPDIR/opt/tools/locked.awk"
  printf 'BEGIN { print 1 }\n' > "$prog"
  chmod 000 "$prog"
  run_snippet "$tool" 'load_program locked.awk'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found or not readable"* ]]
  chmod 644 "$prog"
}


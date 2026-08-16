#!/usr/bin/env bats
#
# The argument and dependency checks are covered by cli-contract.bats; this suite covers the decryption
# itself. Two properties matter: the password reaches qpdf through a file descriptor rather than the
# argument list — anyone on the machine can read another process's argv — and an existing output file is
# never overwritten, since the unlocked copy is the one worth keeping.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/utility/unlock-pdf/unlock-pdf.sh"
  PDF="$BATS_TEST_TMPDIR/secret.pdf"
  printf '%%PDF-1.4 encrypted\n' > "$PDF"
}

########################################
# Evaluates a snippet inside the script.
########################################
with_script() {
  run_snippet "$SCRIPT" "$1"
}

# --- The qpdf invocation -----------------------------------------------------------------------

@test "the unlocked copy is named after the input" {
  with_script "decrypt_pdf 'hunter2' '$PDF'"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/secret-unlocked.pdf" ]
  [[ "$output" == *"Writing $BATS_TEST_TMPDIR/secret-unlocked.pdf"* ]]
  [[ "$output" == *"Done."* ]]
}

@test "qpdf is asked to decrypt" {
  with_script "decrypt_pdf 'hunter2' '$PDF'"
  stub_called 'qpdf --decrypt'
}

# The password is handed over on a file descriptor precisely so it does not appear in the process's
# arguments, where any user on the machine could read it out of ps.
@test "the password never appears in the argument list" {
  with_script "decrypt_pdf 'hunter2' '$PDF'"
  run bash -c "grep -c hunter2 '$STUB_CALLS' || true"
  [ "$output" = "0" ]
  stub_called 'qpdf .*--password-file=/dev/fd/'
}

@test "the input and output are both passed to qpdf" {
  with_script "decrypt_pdf 'hunter2' '$PDF'"
  stub_called "qpdf .*$PDF $BATS_TEST_TMPDIR/secret-unlocked.pdf"
}

# An unlocked copy is the artefact worth keeping, so a second run must not quietly replace it.
@test "an existing unlocked copy is not overwritten" {
  printf 'previously unlocked\n' > "$BATS_TEST_TMPDIR/secret-unlocked.pdf"
  with_script "decrypt_pdf 'hunter2' '$PDF'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Output file already exists"* ]]
  [ "$(stub_calls qpdf)" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/secret-unlocked.pdf"
  [ "$output" = "previously unlocked" ]
}

# `${input%.pdf}` is case-sensitive, so an uppercase extension is not stripped and the copy is named
# "file.PDF-unlocked.pdf". Asserted as it stands: the file is still produced and still recognisable.
@test "an uppercase extension yields a suffixed name rather than failing" {
  local upper="$BATS_TEST_TMPDIR/SCAN.PDF"
  printf '%%PDF-1.4\n' > "$upper"
  with_script "decrypt_pdf 'hunter2' '$upper'"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/SCAN.PDF-unlocked.pdf" ]
}

@test "a path with spaces is handled" {
  local spaced="$BATS_TEST_TMPDIR/my scan.pdf"
  printf '%%PDF-1.4\n' > "$spaced"
  with_script "decrypt_pdf 'hunter2' '$spaced'"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/my scan-unlocked.pdf" ]
}

@test "a failing qpdf is not reported as success" {
  stub_fails qpdf 3
  with_script "decrypt_pdf 'hunter2' '$PDF'"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Done."* ]]
}

# --- The password prompt -----------------------------------------------------------------------

# The prompt itself is not asserted: bash writes a `read -p` prompt only when input comes from a terminal,
# and under bats it never does. What matters is that the password read from stdin is the one used.
@test "the password is read from stdin and used" {
  run_script "$SCRIPT" "$PDF" <<< "hunter2"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/secret-unlocked.pdf" ]
  stub_called 'qpdf --decrypt --password-file='
}

# An empty password would make qpdf fail with something unhelpful, so it is refused up front.
@test "an empty password is refused before qpdf runs" {
  run_script "$SCRIPT" "$PDF" <<< ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"Password cannot be empty"* ]]
  [ "$(stub_calls qpdf)" -eq 0 ]
}

@test "the typed password is not echoed back" {
  run_script "$SCRIPT" "$PDF" <<< "hunter2"
  [[ "$output" != *"hunter2"* ]]
}

# --- The dependency check ----------------------------------------------------------------------

# The install hint is platform-specific; whichever branch this machine takes, it must name a command that
# would actually work here.
@test "a missing qpdf is explained with an instruction for this platform" {
  local minimal="$BATS_TEST_TMPDIR/minimal-bin" cmd
  mkdir -p "$minimal"
  for cmd in bash basename dirname uname printf echo date tput; do
    [ -e "$(command -v "$cmd" 2>/dev/null)" ] && ln -sf "$(command -v "$cmd")" "$minimal/$cmd"
  done
  run env PATH="$minimal" "$(command -v bash)" "$SCRIPT" "$PDF"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'qpdf' is not installed"* ]]
  case "$(uname)" in
    Darwin) [[ "$output" == *"brew install qpdf"* ]] ;;
    Linux)  [[ "$output" == *"apt-get install qpdf"* ]] ;;
    *)      [[ "$output" == *"package manager"* ]] ;;
  esac
}

# The dependency is checked before the arguments, so a machine without qpdf is told what to install rather
# than being corrected about its command line first.
@test "the dependency is checked before the argument count" {
  local minimal="$BATS_TEST_TMPDIR/minimal-bin" cmd
  mkdir -p "$minimal"
  for cmd in bash basename dirname uname printf echo date tput; do
    [ -e "$(command -v "$cmd" 2>/dev/null)" ] && ln -sf "$(command -v "$cmd")" "$minimal/$cmd"
  done
  run env PATH="$minimal" "$(command -v bash)" "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'qpdf' is not installed"* ]]
  [[ "$output" != *"Usage:"* ]]
}

#!/usr/bin/env bats
#
# photo-backup drives `rsync --delete` at a remote server, so the failures that matter are the ones that
# delete photographs: syncing from a source that failed to mount (which would empty the remote copy), or
# syncing one source without protecting the other sources that share the same destination. The empty-source
# check and the protection filter exist for exactly those cases and are what this suite concentrates on.
#
# rsync and dot_clean are stubbed and asserted on by argv, because that is the whole of what the script
# decides. find is real, so the cleaning and the filter generation are exercised for real against a fixture
# tree.
#
# dot_clean is stubbed rather than left to the platform: it exists at /usr/sbin on macOS and not at all on
# Linux, so without a stub the cleaning tests would take a different branch on each CI runner. The cost is
# that the "command not found" log line is never reached; it reports nothing a test could assert anyway.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/photography/photo-backup/photo-backup.sh"
  ONE="$BATS_TEST_TMPDIR/one"
  TWO="$BATS_TEST_TMPDIR/two"
  mkdir -p "$ONE" "$TWO"
  # Config and CLI sources accumulate rather than replace, so a fixture config with an empty SOURCES is
  # what keeps a test from also syncing whatever the machine's own config names.
  CONF="$BATS_TEST_TMPDIR/photo.conf"
  printf 'SOURCES=()\nHOST=""\nDEST_PATH=""\nLOG_FILE=""\n' > "$CONF"
}

########################################
# Creates a file inside a source directory.
# Arguments:
#   path: Path relative to BATS_TEST_TMPDIR.
########################################
make_file() {
  mkdir -p "$(dirname "$BATS_TEST_TMPDIR/$1")"
  printf 'bytes' > "$BATS_TEST_TMPDIR/$1"
}

########################################
# Runs the script with the fixture config.
########################################
backup_run() {
  CONFIG_FILE="$CONF" run_script "$SCRIPT" "$@"
}

########################################
# Runs the script with one populated source and the required destination settings.
########################################
backup_one() {
  make_file one/photo.jpg
  backup_run -s "$ONE" -H server -p /backups "$@"
}

########################################
# Evaluates a snippet inside the script.
########################################
with_script() {
  run_snippet "$SCRIPT" "$1"
}

########################################
# Prints the recorded rsync argv.
########################################
rsync_argv() {
  grep '^rsync ' "$STUB_CALLS" || true
}

# --- Options and required settings -------------------------------------------------------------

@test "-h prints the usage and the required settings" {
  backup_run -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Syncs photos from multiple sources"* ]]
  [[ "$output" == *"-s, --source PATH"* ]]
}

@test "the host, destination and sources are all required" {
  backup_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"HOST"* ]]
  backup_run -H server
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEST_PATH"* ]]
  backup_run -H server -p /backups
  [ "$status" -eq 1 ]
  [[ "$output" == *"SOURCES"* ]]
}

@test "a missing setting prints the usage alongside the error" {
  backup_run
  [[ "$output" == *"Usage:"* ]]
}

@test "-s may be given more than once" {
  make_file one/a.jpg
  make_file two/b.jpg
  backup_run -s "$ONE" -s "$TWO" -H server -p /backups
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 2 source directories"* ]]
}

@test "a single source is described in the singular" {
  backup_one
  [[ "$output" == *"Found 1 source directory:"* ]]
}

@test "an unexpected positional argument is refused" {
  backup_run -H server -p /backups -s "$ONE" stray
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected arguments: stray"* ]]
}

@test "an option missing its argument is refused" {
  backup_run -H
  [ "$status" -eq 1 ]
  [[ "$output" == *"Option '-H' requires an argument"* ]]
}

@test "an unknown option is refused" {
  backup_run -Z
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '-Z'"* ]]
}

@test "settings can come entirely from the config file" {
  make_file one/photo.jpg
  printf 'SOURCES=("%s")\nHOST="confhost"\nDEST_PATH="/confpath"\nLOG_FILE=""\n' "$ONE" > "$CONF"
  backup_run
  [ "$status" -eq 0 ]
  stub_called 'rsync .*confhost:/confpath'
}

@test "a command-line host and path override the config" {
  make_file one/photo.jpg
  printf 'SOURCES=("%s")\nHOST="confhost"\nDEST_PATH="/confpath"\nLOG_FILE=""\n' "$ONE" > "$CONF"
  backup_run -H clihost -p /clipath
  stub_called 'rsync .*clihost:/clipath'
  run bash -c "grep -c confhost '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "an unreadable CONFIG_FILE is refused rather than ignored" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_script "$SCRIPT" -s "$ONE" -H server -p /backups
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_FILE is set to"* ]]
}

# --- Refusing to sync from a source that is not there ------------------------------------------

@test "a source directory that does not exist stops the run" {
  backup_run -s "$BATS_TEST_TMPDIR/absent" -H server -p /backups
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found or not mounted"* ]]
  [ "$(stub_calls rsync)" -eq 0 ]
}

# An unmounted external drive presents as an empty directory, and syncing from it with --delete would
# delete the entire remote copy. This check is the only thing standing between that and the photographs.
@test "an empty source directory stops the run before rsync" {
  backup_run -s "$ONE" -H server -p /backups
  [ "$status" -eq 1 ]
  [[ "$output" == *"appears to be empty. Aborting for safety"* ]]
  [ "$(stub_calls rsync)" -eq 0 ]
}

@test "a source holding only a hidden file counts as populated" {
  make_file one/.hidden
  backup_run -s "$ONE" -H server -p /backups
  [ "$status" -eq 0 ]
  [ "$(stub_calls rsync)" -eq 1 ]
}

@test "one empty source among several stops the whole run" {
  make_file one/a.jpg
  backup_run -s "$ONE" -s "$TWO" -H server -p /backups
  [ "$status" -eq 1 ]
  [[ "$output" == *"Aborting for safety"* ]]
  [ "$(stub_calls rsync)" -eq 0 ]
}

# --- Cleaning ----------------------------------------------------------------------------------

@test "macOS metadata and editor originals are deleted from the source" {
  make_file one/photo.jpg
  make_file one/.DS_Store
  make_file one/IMG_1234_original
  backup_one
  [ ! -e "$ONE/.DS_Store" ]
  [ ! -e "$ONE/IMG_1234_original" ]
  [ -f "$ONE/photo.jpg" ]
}

@test "nested metadata files are deleted too" {
  make_file one/photo.jpg
  make_file one/trip/.DS_Store
  backup_one
  [ ! -e "$ONE/trip/.DS_Store" ]
}

@test "a file merely containing the word original is kept" {
  make_file one/photo.jpg
  make_file one/original-notes.txt
  backup_one
  [ -f "$ONE/original-notes.txt" ]
}

@test "dot_clean is run against each source" {
  backup_one
  stub_called "dot_clean -v $ONE"
}

# In dry-run nothing may be changed, and deleting the metadata files is a change.
@test "--dry-run cleans nothing" {
  make_file one/photo.jpg
  make_file one/.DS_Store
  backup_run -s "$ONE" -H server -p /backups -n
  [ -f "$ONE/.DS_Store" ]
  [ "$(stub_calls dot_clean)" -eq 0 ]
}

# --- The rsync invocation ----------------------------------------------------------------------

@test "rsync preserves hard links and deletes what is gone" {
  backup_one
  stub_called 'rsync .*-aHv'
  stub_called 'rsync .*--delete'
  stub_called 'rsync .*--progress'
}

# Dotfiles are the metadata the cleaning step removes locally; excluding them keeps them from being
# copied at all.
@test "rsync excludes dotfiles" {
  backup_one
  stub_called "rsync .*--exclude \.\*"
}

@test "the destination is the host and path joined by a colon" {
  backup_one
  stub_called 'rsync .*server:/backups'
}

# The trailing slash makes rsync copy the directory's contents rather than the directory itself; without
# it every run would nest another level deeper.
@test "the source is passed with a trailing slash" {
  backup_one
  stub_called "rsync .*${ONE}/ server:/backups"
}

@test "-n adds rsync's own dry-run flag" {
  backup_one -n
  stub_called 'rsync .*--dry-run'
  [[ "$output" == *"Dry-run mode is enabled"* ]]
}

@test "without -n no dry-run flag is passed" {
  backup_one
  run bash -c "grep -c -- '--dry-run' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "each source gets its own rsync run" {
  make_file one/a.jpg
  make_file two/b.jpg
  backup_run -s "$ONE" -s "$TWO" -H server -p /backups
  [ "$(stub_calls rsync)" -eq 2 ]
}

@test "the run reports completion" {
  backup_one
  [[ "$output" == *"Backup operation completed successfully"* ]]
}

# --- The protection filter ---------------------------------------------------------------------

@test "a single source needs no protection filter" {
  backup_one
  [[ "$output" == *"running sync without protection filter"* ]]
  run bash -c "grep -c -- '--filter' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

# Both sources land in the same remote directory, so syncing one with --delete would delete the other's
# files. The filter is what protects them, and it must be in the argv or the protection did not happen.
@test "with several sources each rsync carries a merge filter" {
  make_file one/a.jpg
  make_file two/b.jpg
  backup_run -s "$ONE" -s "$TWO" -H server -p /backups
  [ "$(stub_calls rsync)" -eq 2 ]
  run bash -c "grep -c -- '--filter=merge' '$STUB_CALLS' || true"
  [ "$output" = "2" ]
}

@test "the filter protects the other source's files by relative path" {
  make_file two/b.jpg
  make_file two/trip/c.jpg
  with_script "generate_protection_filter '$BATS_TEST_TMPDIR/f.rules' '$TWO' >/dev/null; cat '$BATS_TEST_TMPDIR/f.rules'"
  [[ "$output" == *"P /b.jpg"* ]]
  [[ "$output" == *"P /trip/c.jpg"* ]]
  [[ "$output" == *"P /trip"* ]]
}

@test "the filter names paths relative to the source, not absolute" {
  make_file two/b.jpg
  with_script "generate_protection_filter '$BATS_TEST_TMPDIR/f.rules' '$TWO' >/dev/null; cat '$BATS_TEST_TMPDIR/f.rules'"
  [[ "$output" != *"$TWO/b.jpg"* ]]
}

@test "the filter covers every other source when there are three" {
  make_file two/b.jpg
  make_file three/c.jpg
  with_script "generate_protection_filter '$BATS_TEST_TMPDIR/f.rules' '$TWO' '$BATS_TEST_TMPDIR/three' >/dev/null; cat '$BATS_TEST_TMPDIR/f.rules'"
  [[ "$output" == *"P /b.jpg"* ]]
  [[ "$output" == *"P /c.jpg"* ]]
}

@test "the filter file is rewritten rather than appended to across runs" {
  make_file two/b.jpg
  printf 'P /stale\n' > "$BATS_TEST_TMPDIR/f.rules"
  with_script "generate_protection_filter '$BATS_TEST_TMPDIR/f.rules' '$TWO' >/dev/null; cat '$BATS_TEST_TMPDIR/f.rules'"
  [[ "$output" != *"stale"* ]]
}

# A filter that failed to generate would let rsync --delete run unprotected, so an absent or empty one
# has to stop the run rather than be treated as "nothing to protect".
@test "a missing filter file is fatal" {
  with_script "validate_filter_file '$BATS_TEST_TMPDIR/never-written'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"was not created"* ]]
}

@test "an empty filter file is fatal, naming the risk" {
  : > "$BATS_TEST_TMPDIR/empty.rules"
  with_script "validate_filter_file '$BATS_TEST_TMPDIR/empty.rules'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is empty"* ]]
  [[ "$output" == *"prevent data loss"* ]]
}

# A source holding nothing but metadata passes the non-empty check and is then emptied by the cleaning
# step, so its protection filter comes out empty. That is indistinguishable from a filter that failed to
# generate, and rsync would treat it as "protect nothing" -- hence the refusal, reached here through the
# command line rather than by calling the validator directly.
@test "a source emptied by cleaning makes the filter empty, and that stops the run" {
  make_file one/photo.jpg
  make_file two/.DS_Store
  backup_run -s "$ONE" -s "$TWO" -H server -p /backups
  [ "$status" -eq 1 ]
  [[ "$output" == *"is empty"* ]]
  [[ "$output" == *"prevent data loss"* ]]
  [ "$(stub_calls rsync)" -eq 0 ]
}

@test "a populated filter file passes validation" {
  printf 'P /a.jpg\n' > "$BATS_TEST_TMPDIR/ok.rules"
  with_script "validate_filter_file '$BATS_TEST_TMPDIR/ok.rules'; echo accepted"
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted"* ]]
}

# --- Logging -----------------------------------------------------------------------------------

@test "-l sends the command output to the named log file" {
  local log="$BATS_TEST_TMPDIR/backup.log"
  printf 'rsync said this\n' > "$STUB_FIXTURES/rsync.stdout"
  backup_one -l "$log"
  [[ "$output" == *"Logging to: $log"* ]]
  run cat "$log"
  [[ "$output" == *"rsync said this"* ]]
}

@test "without a log file the run still succeeds" {
  backup_one
  [ "$status" -eq 0 ]
  [[ "$output" != *"Logging to:"* ]]
}

@test "-d reports the commands as they run" {
  backup_one -d
  [[ "$output" == *"Running command: rsync"* ]]
}

@test "without -d the commands are not echoed" {
  backup_one
  [[ "$output" != *"Running command:"* ]]
}

# --- Safety ------------------------------------------------------------------------------------

@test "no recorded call names a path outside the test directory" {
  make_file one/a.jpg
  make_file two/b.jpg
  backup_run -s "$ONE" -s "$TWO" -H server -p /backups
  run bash -c "grep -c '^rsync' '$STUB_CALLS' || true"
  [ "$output" = "2" ]
  # Every rsync names a source inside the temp tree; the destination is a fake host, never a local path.
  run bash -c "grep '^rsync' '$STUB_CALLS' | grep -vc '$BATS_TEST_TMPDIR' || true"
  [ "$output" = "0" ]
}

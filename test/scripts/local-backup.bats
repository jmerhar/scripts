#!/usr/bin/env bats
#
# local-backup runs `rsync -ax --delete` from a source into a dated directory and then deletes the oldest
# directories under the backup root, so the failures that matter are: pruning more than the retention
# policy allows, treating something that is not a backup as one, updating the "latest" link after a failed
# transfer (which would make the next incremental hard-link against a broken tree), and running twice at
# once.
#
# This script logs for cron rather than for a terminal: it sets _LOG_QUIET before sourcing the library, so
# log_info writes nothing to stdout and only reaches LOG_FILE. Assertions therefore read the log file, the
# stub call log, or the filesystem -- never stdout for an informational message.
#
# flock and ionice are stubbed because they exist on Linux and not on macOS; without stubs each CI runner
# would take a different branch and one of them would prove nothing. The cost is that the two
# "command not found, skipping" paths are never exercised, and they only log.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/local-backup/local-backup.sh"
  SRC="$BATS_TEST_TMPDIR/src"
  DEST="$BATS_TEST_TMPDIR/backups"
  LOG="$BATS_TEST_TMPDIR/backup.log"
  mkdir -p "$SRC" "$DEST"
  printf 'data' > "$SRC/file.txt"
  CONF="$BATS_TEST_TMPDIR/local-backup.conf"
  write_conf
}

########################################
# Writes the fixture config. Extra lines are appended, so a test can override a setting.
# Arguments:
#   Additional config lines.
########################################
write_conf() {
  {
    printf 'SOURCE_DIR="%s"\n' "$SRC"
    printf 'BACKUP_DIR="%s"\n' "$DEST"
    printf 'KEEP_BACKUPS=3\n'
    printf 'EXCLUDES=("/tmp" "*.cache")\n'
    printf 'LOG_FILE="%s"\n' "$LOG"
    local line
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$CONF"
}

########################################
# Runs the script with the fixture config and no RAID file to wait on.
########################################
backup_run() {
  CONFIG_FILE="$CONF" MDSTAT="$BATS_TEST_TMPDIR/no-mdstat" run_script "$SCRIPT" "$@"
}

########################################
# Creates dated backup directories under the backup root, oldest first.
# Arguments:
#   Directory names.
########################################
make_backups() {
  local name
  for name in "$@"; do
    mkdir -p "$DEST/$name"
    printf 'old' > "$DEST/$name/content"
  done
}

########################################
# Lists the dated backup directories that survive, one per line.
########################################
surviving_backups() {
  find "$DEST" -maxdepth 1 -mindepth 1 -type d -name '[0-9][0-9][0-9][0-9]-*' -exec basename {} \; | sort
}

########################################
# Writes a fixture /proc/mdstat in the kernel's real format. Copied from live output rather than invented,
# because the format is the whole point: the operation name sits after the progress bar, not inside it, and
# a fixture that put it elsewhere would agree with a matcher that never fires on a real machine.
# Arguments:
#   state: idle, resync, check, recovery, reshape, or pending.
########################################
write_mdstat() {
  local mdstat="$BATS_TEST_TMPDIR/mdstat"
  {
    printf 'Personalities : [raid1] [raid6]\n'
    printf 'md0 : active raid1 sdb1[1] sda1[0]\n'
    printf '      1953382464 blocks super 1.2 [2/2] [UU]\n'
    case "$1" in
      resync)   printf '      [=>...................]  resync = 6.8%% (133772864/1953382464) finish=254.9min speed=110000K/sec\n' ;;
      check)    printf '      [>....................]  check =  0.4%% (8388608/1953382464) finish=300.0min speed=100000K/sec\n' ;;
      recovery) printf '      [===>.................]  recovery = 18.2%% (355000000/1953382464) finish=180.0min speed=110000K/sec\n' ;;
      reshape)  printf '      [>....................]  reshape =  0.1%% (1953382/1953382464) finish=999.9min speed=90000K/sec\n' ;;
      pending)  printf '      \tresync=PENDING\n' ;;
      idle)     : ;;
    esac
    printf 'unused devices: <none>\n'
  } > "$mdstat"
}

########################################
# Evaluates a snippet inside the script with the fixture config loaded.
########################################
with_conf() {
  CONFIG_FILE="$CONF" run_snippet "$SCRIPT" "load_config >/dev/null; $1"
}

# --- Options and configuration -----------------------------------------------------------------

@test "-h prints the usage" {
  backup_run -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Creates an incremental rsync backup"* ]]
}

@test "an invalid option is refused" {
  backup_run -Z
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid option"* ]]
}

@test "an unexpected argument is refused" {
  backup_run stray
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected arguments: stray"* ]]
}

# The run must stop at the config, before the settings are checked: reaching the settings check means it
# carried on without a config and is only refusing because the values happen to be empty.
@test "a missing configuration file is refused before the settings are checked" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(stub_calls rsync)" -eq 0 ]
  [[ "$output" == *"CONFIG_FILE is set to"* ]]
  [[ "$output" != *"Required setting"* ]]
}

@test "every required setting is checked" {
  local setting
  for setting in SOURCE_DIR BACKUP_DIR KEEP_BACKUPS EXCLUDES; do
    write_conf
    # Drop the one setting under test, leaving the rest intact.
    grep -v "^${setting}" "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    backup_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"${setting}"* ]]
    [ "$(stub_calls rsync)" -eq 0 ]
  done
}

@test "a non-numeric retention count is refused" {
  write_conf 'KEEP_BACKUPS="many"'
  backup_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"KEEP_BACKUPS"* ]]
}

@test "an empty exclude list is refused" {
  write_conf 'EXCLUDES=()'
  backup_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"EXCLUDES"* ]]
}

# --- The lock ----------------------------------------------------------------------------------

@test "the lock is taken inside the backup directory" {
  backup_run
  [ "$status" -eq 0 ]
  [ -e "$DEST/.local-backup.lock" ]
  stub_called 'flock -n 9'
}

# Two concurrent runs would rsync into two directories from the same source and prune against a moving
# set, so a held lock has to stop the second one before it touches anything.
@test "a lock held elsewhere stops the run before rsync" {
  stub_fails flock
  backup_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Another backup is already running"* ]]
  [ "$(stub_calls rsync)" -eq 0 ]
}

@test "a backup directory that does not exist stops the run" {
  write_conf
  printf 'BACKUP_DIR="%s"\n' "$BATS_TEST_TMPDIR/absent-root" >> "$CONF"
  backup_run
  [ "$status" -ne 0 ]
  [ "$(stub_calls rsync)" -eq 0 ]
}

# --- I/O priority and the RAID wait ------------------------------------------------------------

@test "the process lowers its own I/O priority to idle" {
  backup_run
  stub_called 'ionice -c3 -p'
}

@test "a system with no RAID status file is not waited on" {
  backup_run -d
  [[ "$output" == *"not found, skipping RAID check"* ]]
  [ "$(stub_calls rsync)" -eq 1 ]
}

@test "an idle RAID array is not waited on" {
  local mdstat="$BATS_TEST_TMPDIR/mdstat"
  write_mdstat idle
  CONFIG_FILE="$CONF" MDSTAT="$BATS_TEST_TMPDIR/mdstat" run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(stub_calls rsync)" -eq 1 ]
}

# A backup during a resync competes for the same disks and slows both, so the run waits rather than
# proceeding. The waiting notice goes through log_info, which this script silences on stdout, so the log
# file is the only place it appears. Bounded by killing the call, since waiting is the behaviour tested.
@test "a resyncing RAID array is waited on rather than backed up" {
  write_mdstat resync
  : > "$LOG"
  LOG_FILE="$LOG" MDSTAT="$BATS_TEST_TMPDIR/mdstat" MDSTAT_CHECK_INTERVAL=1 run_snippet "$SCRIPT" \
    'wait_for_raid & p=$!; sleep 2; kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; echo "was still waiting"'
  [[ "$output" == *"was still waiting"* ]]
  run cat "$LOG"
  [[ "$output" == *"RAID operation in progress"* ]]
}

# Every operation the kernel can report has to count as busy. "recovery" is the name used for a rebuild,
# which is the case where a backup competing for I/O hurts most.
@test "every RAID operation the kernel reports counts as busy" {
  local state
  for state in resync check recovery reshape pending; do
    write_mdstat "$state"
    : > "$LOG"
    LOG_FILE="$LOG" MDSTAT="$BATS_TEST_TMPDIR/mdstat" MDSTAT_CHECK_INTERVAL=1 run_snippet "$SCRIPT" \
      'wait_for_raid & p=$!; sleep 1; kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true'
    run cat "$LOG"
    [[ "$output" == *"RAID operation in progress"* ]] || {
      printf 'state %s was not detected as busy\n' "$state" >&2
      return 1
    }
  done
}

# An idle array must not be waited on, or every backup would block forever.
@test "an idle array is not waited on at all" {
  write_mdstat idle
  : > "$LOG"
  LOG_FILE="$LOG" MDSTAT="$BATS_TEST_TMPDIR/mdstat" MDSTAT_CHECK_INTERVAL=1 \
    run_snippet "$SCRIPT" 'wait_for_raid; echo returned'
  [[ "$output" == *"returned"* ]]
  run grep -c 'RAID operation in progress' "$LOG"
  [ "$output" = "0" ]
}

# --- The rsync invocation ----------------------------------------------------------------------

@test "a dated backup directory is created" {
  backup_run
  [ "$status" -eq 0 ]
  [ "$(surviving_backups | wc -l | tr -d ' ')" -eq 1 ]
  surviving_backups | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}:[0-9]{2}$'
}

@test "rsync is asked to stay on one filesystem and to delete" {
  backup_run
  stub_called 'rsync -ax --delete'
}

@test "the configured excludes are passed as rsync excludes" {
  backup_run
  stub_called 'rsync .*--exclude=/tmp'
  stub_called 'rsync .*--exclude=\*\.cache'
}

# The trailing slash copies the source's contents; without it rsync would nest the source directory
# inside every backup.
@test "the source is passed with a trailing slash" {
  backup_run
  stub_called "rsync .*${SRC}/ "
}

# --link-dest is what makes the backup incremental: unchanged files become hard links into the previous
# run instead of copies.
@test "the previous backup is offered as the hard-link source" {
  backup_run
  stub_called "rsync .*--link-dest ${DEST}/latest"
}

@test "progress output is not requested when not on a terminal" {
  backup_run
  run bash -c "grep -c 'info=progress2' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "the latest link points at the new backup" {
  backup_run
  [ -L "$DEST/latest" ]
  local target newest
  target=$(readlink "$DEST/latest")
  newest=$(surviving_backups | tail -1)
  [ "$(basename "$target")" = "$newest" ]
}

# An existing link has to be replaced, not left alone: pointing at an old backup would make the next run
# hard-link against the wrong tree, and `ln -s` without -f silently fails when the name is taken.
@test "an existing latest link is repointed at the new backup" {
  make_backups 2026-01-01_00:00:00
  ln -sfn "$DEST/2026-01-01_00:00:00" "$DEST/latest"
  backup_run
  [ "$status" -eq 0 ]
  local target
  target=$(readlink "$DEST/latest")
  [ "$(basename "$target")" != "2026-01-01_00:00:00" ]
  [ "$(basename "$target")" = "$(surviving_backups | tail -1)" ]
}

# rsync's code 24 means files vanished mid-transfer, which happens routinely with temp files and does not
# invalidate the backup.
@test "rsync code 24 is treated as a successful backup" {
  stub_fails rsync 24
  backup_run
  [ "$status" -eq 0 ]
  [ -L "$DEST/latest" ]
  run cat "$LOG"
  [[ "$output" == *"non-fatal warning (code 24)"* ]]
}

# Any other failure leaves an incomplete directory, so the link must keep pointing at the last good
# backup or the next incremental would hard-link against a broken tree.
@test "a real rsync failure exits with its code and leaves the latest link alone" {
  stub_fails rsync 23
  backup_run
  [ "$status" -eq 23 ]
  [ ! -e "$DEST/latest" ]
  [[ "$output" == *"Rsync failed with a critical error (code 23)"* ]]
}

# The retention count is 3 and there are four backups, so a run that reached the pruning step would have
# deleted one. All four surviving proves it stopped at the failure. The incomplete directory the failed
# run created is still there -- rsync is invoked after it is made -- so the count is five, not four.
@test "a failed backup does not go on to prune" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00 2026-01-04_00:00:00
  stub_fails rsync 23
  backup_run
  [ "$status" -eq 23 ]
  local name
  for name in 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00 2026-01-04_00:00:00; do
    [ -d "$DEST/$name" ]
  done
  [ "$(surviving_backups | wc -l | tr -d ' ')" -eq 5 ]
}

# --- Logging -----------------------------------------------------------------------------------

# Informational output is suppressed on stdout by design; the log file is where a cron run leaves its
# trace, so that is what has to contain it.
@test "the log file records the run while stdout stays quiet" {
  backup_run
  [ -f "$LOG" ]
  run cat "$LOG"
  [[ "$output" == *"Starting backup"* ]]
  [[ "$output" == *"Backup operation completed"* ]]
  backup_run
  [[ "$output" != *"Starting backup"* ]]
}

@test "-d reports the command that was run" {
  backup_run -d
  [[ "$output" == *"rsync command: rsync -ax --delete"* ]]
}

@test "the log file is named in the run when configured" {
  backup_run
  run cat "$LOG"
  [[ "$output" == *"Logging to: $LOG"* ]]
}

# --- Pruning -----------------------------------------------------------------------------------

@test "fewer backups than the retention count prunes nothing" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00
  with_conf "run_prune"
  [ "$(surviving_backups | wc -l | tr -d ' ')" -eq 2 ]
}

@test "exactly the retention count prunes nothing" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00
  with_conf "run_prune"
  [ "$(surviving_backups | wc -l | tr -d ' ')" -eq 3 ]
}

@test "the oldest backups beyond the retention count are deleted" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00 \
    2026-01-04_00:00:00 2026-01-05_00:00:00
  with_conf "run_prune"
  run surviving_backups
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "2026-01-03_00:00:00" ]
  [ "${lines[2]}" = "2026-01-05_00:00:00" ]
}

@test "the retention count comes from the configuration" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00 2026-01-04_00:00:00
  write_conf 'KEEP_BACKUPS=1'
  with_conf "run_prune"
  run surviving_backups
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "2026-01-04_00:00:00" ]
}

# Only dated directories are backups. Anything else under the root -- the latest symlink, a lock file,
# somebody's notes -- must survive pruning.
@test "directories that are not dated backups are never pruned" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00 2026-01-04_00:00:00
  mkdir -p "$DEST/keep-me" "$DEST/archive"
  printf 'x' > "$DEST/notes.txt"
  with_conf "run_prune"
  [ -d "$DEST/keep-me" ]
  [ -d "$DEST/archive" ]
  [ -f "$DEST/notes.txt" ]
}

@test "a file whose name looks like a backup is not deleted" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00 2026-01-04_00:00:00
  printf 'x' > "$DEST/2026-01-00_00:00:00"
  with_conf "run_prune"
  [ -f "$DEST/2026-01-00_00:00:00" ]
}

# The nested directory goes inside the *newest* backup on purpose. Nested inside the oldest, a search that
# wrongly descended would delete that backup and its child and arrive at the same surviving set by
# coincidence; inside the newest, it deletes one backup too many and the difference shows.
@test "nested directories inside a backup are not mistaken for backups" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00 2026-01-04_00:00:00
  mkdir -p "$DEST/2026-01-04_00:00:00/2026-09-09_00:00:00"
  with_conf "run_prune"
  run surviving_backups
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "2026-01-02_00:00:00" ]
  [ -d "$DEST/2026-01-04_00:00:00/2026-09-09_00:00:00" ]
}

@test "pruning is recorded in the log" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00 2026-01-04_00:00:00
  with_conf "run_prune"
  run cat "$LOG"
  [[ "$output" == *"Deleting: 2026-01-01_00:00:00"* ]]
  [[ "$output" == *"Pruning complete"* ]]
}

@test "an empty backup root prunes nothing and does not fail" {
  with_conf "run_prune; echo ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "a full run backs up and then prunes in one pass" {
  make_backups 2026-01-01_00:00:00 2026-01-02_00:00:00 2026-01-03_00:00:00
  backup_run
  [ "$status" -eq 0 ]
  # Three old plus the new one, pruned back to the retention count of three.
  [ "$(surviving_backups | wc -l | tr -d ' ')" -eq 3 ]
  run surviving_backups
  [ "${lines[0]}" = "2026-01-02_00:00:00" ]
}

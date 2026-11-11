#!/usr/bin/env bats
#
# pg-backup replaces a database's backup with a new dump and then deletes old ones, so the failures that
# matter are losing a good dump: replacing it with a failed or malformed one, pruning after a failure,
# pruning more than the retention allows or something that is not a dump, and a weekly or monthly copy
# changing after the fact. One database failing must also not stop the others.
#
# The docker double is reached through DOCKER_BIN and named docker-cli, for the reason given in
# ufw-docker-expose.bats, and answers each database's pg_dump from docker-cli.pg_dump.<database>.*
# fixtures. Every run names its own CONFIG_FILE and fixes the day with PG_BACKUP_NOW under TZ=UTC, so the
# day, ISO week and month a run computes are the same on every machine.

load ../test_helper

# Noon UTC on the days the tests need.
WED=1794398400   # 2026-11-11, 2026-W46
THU=1794484800   # 2026-11-12, 2026-W46
MON=1794830400   # 2026-11-16, 2026-W47
DEC1=1796126400  # 2026-12-01, 2026-W49

setup() {
  setup_common
  export TZ=UTC
  SCRIPT="$REPO_ROOT/scripts/system/pg-backup/pg-backup.sh"
  ROOT="$BATS_TEST_TMPDIR/backup"
  CONF="$BATS_TEST_TMPDIR/pg-backup.conf"
  LOG="$BATS_TEST_TMPDIR/pg-backup.log"
  write_conf '"joplin joplin-db joplin joplindb"'
  dump_answers joplindb 'PGDMP joplin dump'
}

########################################
# Writes the fixture config with the given DATABASES entries. Extra settings can follow in EXTRA.
# Arguments:
#   DATABASES entries, each already quoted.
########################################
write_conf() {
  {
    printf 'BACKUP_DIR="%s"\n' "$ROOT"
    printf 'LOG_FILE="%s"\n' "$LOG"
    printf 'DATABASES=(%s)\n' "$*"
    printf '%s\n' "${EXTRA:-}"
  } > "$CONF"
}

########################################
# Sets what pg_dump prints for a database.
# Arguments:
#   database: The database name, as pg_dump's -d receives it.
#   body:     The dump it writes.
########################################
dump_answers() {
  printf '%s\n' "$2" > "$STUB_FIXTURES/docker-cli.pg_dump.$1.stdout"
}

########################################
# Makes pg_dump fail for a database, saying something on stderr.
# Arguments:
#   database: The database name.
########################################
dump_fails() {
  printf '1' > "$STUB_FIXTURES/docker-cli.pg_dump.$1.fail"
  printf 'pg_dump: error: connection to server failed\n' > "$STUB_FIXTURES/docker-cli.pg_dump.$1.stderr"
}

########################################
# Runs the script on a given day.
# Arguments:
#   epoch: The moment the run treats as now.
#   The script's own arguments.
########################################
backup_at() {
  local epoch="$1"
  shift
  CONFIG_FILE="$CONF" DOCKER_BIN=docker-cli PG_BACKUP_NOW="$epoch" run_script "$SCRIPT" "$@"
}

########################################
# Creates dumps in a tier as earlier runs would have left them.
# Arguments:
#   tier: daily, weekly or monthly.
#   The period stamps to create, e.g. 2026-11-01.
########################################
seed() {
  local tier="$1" stamp
  shift
  mkdir -p "$ROOT/joplin/$tier"
  for stamp in "$@"; do
    printf 'PGDMP old %s\n' "$stamp" > "$ROOT/joplin/$tier/joplin-$stamp.dump"
  done
}

########################################
# Prints a file's inode number.
########################################
inode() {
  ls -i "$1" | awk '{print $1}'
}

########################################
# Prints a file's permission bits, on either platform.
########################################
mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

########################################
# Lists a directory's entries, one per line, hidden ones included.
########################################
entries() {
  ls -A "$1"
}

# --- Dumping -----------------------------------------------------------------------------------

@test "dumps a database in custom format inside its container" {
  backup_at "$WED"
  [ "$status" -eq 0 ]
  stub_called 'docker-cli exec joplin-db pg_dump -U joplin -d joplindb -Fc'
  [ "$(cat "$ROOT/joplin/daily/joplin-2026-11-11.dump")" = "PGDMP joplin dump" ]
}

@test "dumps every listed database" {
  write_conf '"joplin joplin-db joplin joplindb"' '"idealista ideal-db ideal idealdb"'
  dump_answers idealdb 'PGDMP idealista dump'
  backup_at "$WED"
  [ "$status" -eq 0 ]
  [ -f "$ROOT/joplin/daily/joplin-2026-11-11.dump" ]
  [ "$(cat "$ROOT/idealista/daily/idealista-2026-11-11.dump")" = "PGDMP idealista dump" ]
  [[ "$output" == *"Backed up 2 database(s)."* ]]
}

@test "naming an entry backs up only that one" {
  write_conf '"joplin joplin-db joplin joplindb"' '"idealista ideal-db ideal idealdb"'
  dump_answers idealdb 'PGDMP idealista dump'
  backup_at "$WED" idealista
  [ "$status" -eq 0 ]
  [ -f "$ROOT/idealista/daily/idealista-2026-11-11.dump" ]
  [ ! -e "$ROOT/joplin" ]
}

@test "naming an entry that does not exist dumps nothing" {
  backup_at "$WED" joplin nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"No DATABASES entry is named 'nope'."* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "the dump and its directories are not readable by others" {
  backup_at "$WED"
  [ "$(mode_of "$ROOT/joplin/daily/joplin-2026-11-11.dump")" = "640" ]
  [ "$(mode_of "$ROOT/joplin/daily")" = "750" ]
}

@test "warnings pg_dump prints on a successful dump are logged" {
  printf 'pg_dump: warning: something minor\n' > "$STUB_FIXTURES/docker-cli.pg_dump.joplindb.stderr"
  backup_at "$WED"
  [ "$status" -eq 0 ]
  grep -q '\[WARN\]: joplin: pg_dump: pg_dump: warning: something minor' "$LOG"
}

# --- The tiers ---------------------------------------------------------------------------------

@test "the first dump of a week and of a month is kept in those tiers as the same file" {
  backup_at "$WED"
  local daily="$ROOT/joplin/daily/joplin-2026-11-11.dump"
  [ "$(inode "$ROOT/joplin/weekly/joplin-2026-W46.dump")" = "$(inode "$daily")" ]
  [ "$(inode "$ROOT/joplin/monthly/joplin-2026-11.dump")" = "$(inode "$daily")" ]
}

# Promotion goes by whether the period has a copy, not by the weekday, so a later dump in the same week
# leaves the week's copy alone.
@test "a later dump in the same week and month is kept only as a daily" {
  backup_at "$WED"
  dump_answers joplindb 'PGDMP thursday'
  backup_at "$THU"
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/joplin/weekly/joplin-2026-W46.dump")" = "PGDMP joplin dump" ]
  [ "$(entries "$ROOT/joplin/weekly")" = "joplin-2026-W46.dump" ]
  [ "$(entries "$ROOT/joplin/monthly")" = "joplin-2026-11.dump" ]
}

@test "the first dump of a new week starts that week's copy" {
  backup_at "$WED"
  backup_at "$MON"
  [ "$status" -eq 0 ]
  [ "$(entries "$ROOT/joplin/weekly")" = $'joplin-2026-W46.dump\njoplin-2026-W47.dump' ]
}

@test "the first dump of a new month starts that month's copy" {
  backup_at "$WED"
  backup_at "$DEC1"
  [ "$(entries "$ROOT/joplin/monthly")" = $'joplin-2026-11.dump\njoplin-2026-12.dump' ]
}

# The day's file is replaced by a rename, so the week's copy keeps the first dump's content.
@test "a second run on the same day replaces the daily without changing the kept copies" {
  backup_at "$WED"
  dump_answers joplindb 'PGDMP second run'
  backup_at "$WED"
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/joplin/daily/joplin-2026-11-11.dump")" = "PGDMP second run" ]
  [ "$(cat "$ROOT/joplin/weekly/joplin-2026-W46.dump")" = "PGDMP joplin dump" ]
}

# --- Pruning -----------------------------------------------------------------------------------

@test "each tier is pruned to its newest files, today's included" {
  EXTRA=$'KEEP_DAILY=3\nKEEP_WEEKLY=2\nKEEP_MONTHLY=2' write_conf '"joplin joplin-db joplin joplindb"'
  seed daily 2026-11-07 2026-11-08 2026-11-09 2026-11-10
  seed weekly 2026-W43 2026-W44 2026-W45
  seed monthly 2026-08 2026-09 2026-10
  backup_at "$WED"
  [ "$status" -eq 0 ]
  [ "$(entries "$ROOT/joplin/daily")" = $'joplin-2026-11-09.dump\njoplin-2026-11-10.dump\njoplin-2026-11-11.dump' ]
  [ "$(entries "$ROOT/joplin/weekly")" = $'joplin-2026-W45.dump\njoplin-2026-W46.dump' ]
  [ "$(entries "$ROOT/joplin/monthly")" = $'joplin-2026-10.dump\njoplin-2026-11.dump' ]
}

@test "pruning leaves alone what is not one of this entry's dumps" {
  EXTRA='KEEP_DAILY=1' write_conf '"joplin joplin-db joplin joplindb"'
  seed daily 2026-11-10
  touch "$ROOT/joplin/daily/notes.txt" "$ROOT/joplin/daily/other-2026-11-01.dump" "$ROOT/joplin/daily/joplin-latest.dump"
  backup_at "$WED"
  [ "$status" -eq 0 ]
  [ "$(entries "$ROOT/joplin/daily")" = $'joplin-2026-11-11.dump\njoplin-latest.dump\nnotes.txt\nother-2026-11-01.dump' ]
}

@test "the defaults keep 14 daily dumps" {
  seed daily 2026-10-27 2026-10-28 2026-10-29 2026-10-30 2026-10-31 2026-11-01 2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06 2026-11-07 2026-11-08 2026-11-09 2026-11-10
  backup_at "$WED"
  [ "$(entries "$ROOT/joplin/daily" | wc -l | tr -d ' ')" = "14" ]
  [ ! -e "$ROOT/joplin/daily/joplin-2026-10-28.dump" ]
  [ -e "$ROOT/joplin/daily/joplin-2026-10-29.dump" ]
}

# --- Failures ----------------------------------------------------------------------------------

# Today's dump is seeded too, as a good run earlier in the day would leave it: a failure must not be
# followed by keeping or pruning around the file that run left.
@test "a failed pg_dump keeps every earlier dump, prunes nothing, and says why" {
  EXTRA='KEEP_DAILY=1' write_conf '"joplin joplin-db joplin joplindb"'
  seed daily 2026-11-09 2026-11-10 2026-11-11
  dump_fails joplindb
  backup_at "$WED"
  [ "$status" -eq 1 ]
  [ "$(entries "$ROOT/joplin/daily")" = $'joplin-2026-11-09.dump\njoplin-2026-11-10.dump\njoplin-2026-11-11.dump' ]
  [ "$(cat "$ROOT/joplin/daily/joplin-2026-11-11.dump")" = "PGDMP old 2026-11-11" ]
  [ -z "$(entries "$ROOT/joplin/weekly")" ]
  grep -q '\[ERROR\]: joplin: pg_dump: pg_dump: error: connection to server failed' "$LOG"
  grep -q 'exited 1; earlier dumps kept' "$LOG"
}

@test "output that is not a custom-format dump is refused" {
  dump_answers joplindb '-- PostgreSQL plain-text dump'
  backup_at "$WED"
  [ "$status" -eq 1 ]
  [ -z "$(entries "$ROOT/joplin/daily")" ]
  [[ "$output" == *"not in pg_dump's custom format"* ]]
}

@test "--debug logs the pg_dump command" {
  backup_at "$WED" --debug
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running: docker-cli exec joplin-db pg_dump -U joplin -d joplindb -Fc"* ]]
}

@test "one database failing does not stop the others" {
  write_conf '"broken broken-db u brokendb"' '"joplin joplin-db joplin joplindb"'
  dump_fails brokendb
  backup_at "$WED"
  [ "$status" -eq 1 ]
  [ -f "$ROOT/joplin/daily/joplin-2026-11-11.dump" ]
  [[ "$output" == *"Backed up 1 of 2 database(s); failed: broken."* ]]
}

@test "a link that cannot be made fails the run" {
  mkdir -p "$ROOT/joplin/weekly"
  ln -s "$BATS_TEST_TMPDIR/nowhere" "$ROOT/joplin/weekly/joplin-2026-W46.dump"
  backup_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed: joplin."* ]]
}

@test "a tier directory that cannot be created fails the run" {
  mkdir -p "$ROOT/joplin"
  touch "$ROOT/joplin/monthly"
  backup_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed: joplin."* ]]
}

# --- Configuration -----------------------------------------------------------------------------

@test "an entry without four fields is refused before anything is dumped" {
  write_conf '"joplin joplin-db joplin"'
  backup_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must have four fields"* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "a name that could leave the backup directory is refused" {
  local bad
  for bad in ../escape .hidden -dash 'a/b'; do
    write_conf "\"$bad joplin-db joplin joplindb\""
    backup_at "$WED"
    [ "$status" -eq 1 ] || { echo "accepted: $bad" >&2; return 1; }
    [[ "$output" == *"the name may hold only"* ]]
  done
  [ ! -s "$STUB_CALLS" ]
}

@test "an empty database list is refused" {
  write_conf ''
  backup_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DATABASES"* ]]
}

@test "a retention that is not a positive whole number is refused" {
  EXTRA='KEEP_WEEKLY=0' write_conf '"joplin joplin-db joplin joplindb"'
  backup_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"KEEP_WEEKLY"* ]]
}

@test "a missing docker client is reported" {
  CONFIG_FILE="$CONF" DOCKER_BIN=no-such-docker run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'no-such-docker' was not found"* ]]
}

@test "an unreadable named config is an error" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" DOCKER_BIN=docker-cli run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_CALLS" ]
}

@test "an unknown option is a usage error" {
  run_script "$SCRIPT" --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nope'."* ]]
}

@test "arguments after -- are entry names" {
  backup_at "$WED" -- joplin
  [ "$status" -eq 0 ]
  [ -f "$ROOT/joplin/daily/joplin-2026-11-11.dump" ]
}

@test "the clock is read when no moment is given" {
  CONFIG_FILE="$CONF" DOCKER_BIN=docker-cli run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$ROOT/joplin/daily/joplin-$(date -u +%F).dump" ]
}

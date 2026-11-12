#!/usr/bin/env bats
#
# db-backup replaces a database's backup with a new dump and deletes old ones, and can replace the
# database itself, so the failures that matter are losing good data: keeping a failed or incomplete dump,
# pruning after a failure or more than the retention allows, a weekly or monthly copy changing after the
# fact, restoring without warning or confirmation, and restoring a dump that is not one. One entry
# failing must also not stop the others.
#
# The docker double is reached through DOCKER_BIN and named docker-cli, for the reason given in
# ufw-docker-expose.bats; it answers each call from docker-cli.<tool>[.<database>].* fixtures and saves
# what a restore feeds it. SQLite runs for real, through the sqlite3 on PATH, since what is tested there
# is the file format itself. Every run names its own CONFIG_FILE and fixes the day with DB_BACKUP_NOW
# under TZ=UTC, so the day, ISO week and month a run computes are the same on every machine.

load ../test_helper

# Noon UTC on the days the tests need.
WED=1794398400   # 2026-11-11, 2026-W46
THU=1794484800   # 2026-11-12, 2026-W46
MON=1794830400   # 2026-11-16, 2026-W47
DEC1=1796126400  # 2026-12-01, 2026-W49

setup() {
  setup_common
  export TZ=UTC
  SCRIPT="$REPO_ROOT/scripts/system/db-backup/db-backup.sh"
  ROOT="$BATS_TEST_TMPDIR/backup"
  CONF="$BATS_TEST_TMPDIR/db-backup.conf"
  LOG="$BATS_TEST_TMPDIR/db-backup.log"
  write_conf '"postgres app app-pg app appdb"'
  pg_answers appdb 'PGDMP app dump'
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
pg_answers() {
  printf '%s\n' "$2" > "$STUB_FIXTURES/docker-cli.pg_dump.$1.stdout"
}

########################################
# Sets what mariadb-dump prints for a database: a complete dump unless a body is given.
# Arguments:
#   database: The database name.
#   body:     Optional dump text.
########################################
mariadb_answers() {
  local body="${2:-$'-- MariaDB dump\nCREATE DATABASE books;\n-- Dump completed on 2026-11-11  3:17:00'}"
  printf '%s\n' "$body" > "$STUB_FIXTURES/docker-cli.mariadb-dump.$1.stdout"
}

########################################
# Sets what mongodump prints for a database: a gzipped archive starting with the format's magic number.
# Arguments:
#   database: The database name.
########################################
mongo_answers() {
  printf '\x6d\xe2\x99\x81archive body' | gzip > "$STUB_FIXTURES/docker-cli.mongodump.$1.stdout"
}

########################################
# Makes a tool fail for a database, saying something on stderr.
# Arguments:
#   tool:     The tool run in the container.
#   database: The database name.
########################################
tool_fails() {
  printf '1' > "$STUB_FIXTURES/docker-cli.$1.$2.fail"
  printf '%s: error: connection to server failed\n' "$1" > "$STUB_FIXTURES/docker-cli.$1.$2.stderr"
}

########################################
# Creates a SQLite database in WAL mode holding one row.
# Arguments:
#   path:  Where to create it.
#   value: The row's value.
########################################
make_sqlite() {
  mkdir -p "$(dirname "$1")"
  sqlite3 "$1" "PRAGMA journal_mode=WAL; CREATE TABLE t(v); INSERT INTO t VALUES ('$2');" >/dev/null
}

########################################
# Runs the script on a given day.
# Arguments:
#   epoch: The moment the run treats as now.
#   The script's own arguments.
########################################
run_at() {
  local epoch="$1"
  shift
  CONFIG_FILE="$CONF" DOCKER_BIN=docker-cli DB_BACKUP_NOW="$epoch" VERIFY_TIMEOUT=1 VERIFY_POLL=1 run_script "$SCRIPT" "$@"
}

########################################
# Runs the script on 2026-11-11 with the given text on stdin, which is what a restore prompt reads.
# Arguments:
#   input: The text to feed it.
#   The script's own arguments.
########################################
run_script_input() {
  local input="$1"
  shift
  CONFIG_FILE="$CONF" DOCKER_BIN=docker-cli DB_BACKUP_NOW="$WED" run_snippet "$SCRIPT" "main $(printf '%q ' "$@") <<< $(printf '%q' "$input")"
}

########################################
# Creates dumps in a tier as earlier runs would have left them.
# Arguments:
#   name, ext: The entry and its extension.
#   tier:      daily, weekly or monthly.
#   The period stamps to create, e.g. 2026-11-01.
########################################
seed() {
  local name="$1" ext="$2" tier="$3" stamp
  shift 3
  mkdir -p "$ROOT/$name/$tier"
  for stamp in "$@"; do
    printf 'PGDMP old %s\n' "$stamp" > "$ROOT/$name/$tier/$name-$stamp$ext"
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

# --- Backing up each engine --------------------------------------------------------------------

@test "postgres is dumped in custom format inside its container" {
  run_at "$WED"
  [ "$status" -eq 0 ]
  stub_called 'docker-cli exec app-pg pg_dump -U app -d appdb -Fc'
  [ "$(cat "$ROOT/app/daily/app-2026-11-11.dump")" = "PGDMP app dump" ]
}

@test "mariadb is dumped as root with the container's own password, and gzipped" {
  write_conf '"mariadb books books-db booksdb"'
  mariadb_answers booksdb
  run_at "$WED"
  [ "$status" -eq 0 ]
  stub_called 'docker-cli exec books-db sh -c'
  grep -q 'MARIADB_ROOT_PASSWORD' "$STUB_CALLS"
  grep -q -- '--single-transaction --routines --triggers --databases "\$1" sh booksdb$' "$STUB_CALLS"
  [[ "$(gzip -dc "$ROOT/books/daily/books-2026-11-11.sql.gz")" == *"CREATE DATABASE books;"* ]]
}

@test "mongodb is dumped as a gzipped archive" {
  write_conf '"mongodb media media-mongo mediadb"'
  mongo_answers mediadb
  run_at "$WED"
  [ "$status" -eq 0 ]
  stub_called 'docker-cli exec media-mongo mongodump --quiet --archive --gzip --db mediadb'
  [ -f "$ROOT/media/daily/media-2026-11-11.archive.gz" ]
}

@test "sqlite is copied from the host, consistently, and gzipped" {
  make_sqlite "$BATS_TEST_TMPDIR/data dir/wiki.db" original
  write_conf "\"sqlite wiki $BATS_TEST_TMPDIR/data dir/wiki.db\""
  run_at "$WED"
  [ "$status" -eq 0 ]
  gzip -dc "$ROOT/wiki/daily/wiki-2026-11-11.sqlite.gz" > "$BATS_TEST_TMPDIR/copy.db"
  [ "$(sqlite3 "$BATS_TEST_TMPDIR/copy.db" 'SELECT v FROM t')" = "original" ]
}

@test "every listed entry is backed up" {
  make_sqlite "$BATS_TEST_TMPDIR/wiki.db" x
  write_conf '"postgres app app-pg app appdb"' "\"sqlite wiki $BATS_TEST_TMPDIR/wiki.db\""
  run_at "$WED"
  [ "$status" -eq 0 ]
  [ -f "$ROOT/app/daily/app-2026-11-11.dump" ]
  [ -f "$ROOT/wiki/daily/wiki-2026-11-11.sqlite.gz" ]
  [[ "$output" == *"Backed up 2 database(s)."* ]]
}

@test "naming an entry backs up only that one, with or without the backup command" {
  make_sqlite "$BATS_TEST_TMPDIR/wiki.db" x
  write_conf '"postgres app app-pg app appdb"' "\"sqlite wiki $BATS_TEST_TMPDIR/wiki.db\""
  run_at "$WED" wiki
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/app" ]
  run_at "$WED" backup app
  [ "$status" -eq 0 ]
  [ -f "$ROOT/app/daily/app-2026-11-11.dump" ]
}

@test "naming an entry that does not exist does nothing" {
  run_at "$WED" app nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"No DATABASES entry is named 'nope'."* ]]
  [ ! -s "$STUB_CALLS" ]
}

@test "the dump and its directories are not readable by others" {
  run_at "$WED"
  [ "$(mode_of "$ROOT/app/daily/app-2026-11-11.dump")" = "640" ]
  [ "$(mode_of "$ROOT/app/daily")" = "750" ]
}

@test "warnings a tool prints on a successful dump are logged" {
  printf 'pg_dump: warning: something minor\n' > "$STUB_FIXTURES/docker-cli.pg_dump.appdb.stderr"
  run_at "$WED"
  [ "$status" -eq 0 ]
  grep -q '\[WARN\]: app: pg_dump: warning: something minor' "$LOG"
}

@test "--debug logs which entry is being dumped" {
  run_at "$WED" --debug
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dumping app (postgres)."* ]]
}

# --- Checking a dump ---------------------------------------------------------------------------

@test "postgres output that is not a custom-format dump is refused" {
  pg_answers appdb '-- PostgreSQL plain-text dump'
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a pg_dump custom-format dump"* ]]
}

# An empty file would otherwise replace the day's dump and be kept in the tiers.
@test "an empty dump from a tool that exited 0 is refused" {
  seed app .dump daily 2026-11-11
  rm "$STUB_FIXTURES/docker-cli.pg_dump.appdb.stdout"
  run_at "$WED"
  [ "$status" -eq 1 ]
  [ "$(cat "$ROOT/app/daily/app-2026-11-11.dump")" = "PGDMP old 2026-11-11" ]
  [ ! -e "$ROOT/app/weekly" ]
}

# mysqldump writes its completion line last, so a dump cut short by a dying server lacks it.
@test "a mariadb dump without its completion line is refused" {
  write_conf '"mariadb books books-db booksdb"'
  mariadb_answers booksdb $'-- MariaDB dump\nCREATE DATABASE books;'
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a complete MariaDB dump"* ]]
}

@test "a mongodb archive without the format's magic number is refused" {
  write_conf '"mongodb media media-mongo mediadb"'
  printf 'not an archive' | gzip > "$STUB_FIXTURES/docker-cli.mongodump.mediadb.stdout"
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a mongodump archive"* ]]
}

@test "a sqlite file that is not a database is refused" {
  printf 'not a database at all, but long enough to have a header' > "$BATS_TEST_TMPDIR/wiki.db"
  write_conf "\"sqlite wiki $BATS_TEST_TMPDIR/wiki.db\""
  run_at "$WED"
  [ "$status" -eq 1 ]
  [ ! -e "$ROOT/wiki" ]
}

# --- The tiers ---------------------------------------------------------------------------------

@test "the first dump of a week and of a month is kept in those tiers as the same file" {
  run_at "$WED"
  local daily="$ROOT/app/daily/app-2026-11-11.dump"
  [ "$(inode "$ROOT/app/weekly/app-2026-W46.dump")" = "$(inode "$daily")" ]
  [ "$(inode "$ROOT/app/monthly/app-2026-11.dump")" = "$(inode "$daily")" ]
}

# Promotion goes by whether the period has a copy, not by the weekday, so a later dump in the same week
# leaves the week's copy alone.
@test "a later dump in the same week and month is kept only as a daily" {
  run_at "$WED"
  pg_answers appdb 'PGDMP thursday'
  run_at "$THU"
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/app/weekly/app-2026-W46.dump")" = "PGDMP app dump" ]
  [ "$(entries "$ROOT/app/weekly")" = "app-2026-W46.dump" ]
  [ "$(entries "$ROOT/app/monthly")" = "app-2026-11.dump" ]
}

@test "the first dump of a new week or month starts that period's copy" {
  run_at "$WED"
  run_at "$MON"
  [ "$(entries "$ROOT/app/weekly")" = $'app-2026-W46.dump\napp-2026-W47.dump' ]
  run_at "$DEC1"
  [ "$(entries "$ROOT/app/monthly")" = $'app-2026-11.dump\napp-2026-12.dump' ]
}

# The day's file is replaced by a rename, so the week's copy keeps the first dump's content.
@test "a second run on the same day replaces the daily without changing the kept copies" {
  run_at "$WED"
  pg_answers appdb 'PGDMP second run'
  run_at "$WED"
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/app/daily/app-2026-11-11.dump")" = "PGDMP second run" ]
  [ "$(cat "$ROOT/app/weekly/app-2026-W46.dump")" = "PGDMP app dump" ]
}

# Two runs can both find a period uncovered; the one whose ln loses finds the other's link in place.
@test "a link made by an overlapping run between the check and ln counts as kept" {
  local file="$BATS_TEST_TMPDIR/d.dump" tier="$BATS_TEST_TMPDIR/w.dump"
  printf 'PGDMP x\n' > "$file"
  run_snippet "$SCRIPT" "ln() { command ln \"\$@\"; return 1; }; promote '$file' '$tier' weekly && echo kept"
  [ "$status" -eq 0 ]
  [ "$output" = "kept" ]
}

# --- Pruning -----------------------------------------------------------------------------------

@test "each tier is pruned to its newest files, today's included" {
  EXTRA=$'KEEP_DAILY=3\nKEEP_WEEKLY=2\nKEEP_MONTHLY=2' write_conf '"postgres app app-pg app appdb"'
  seed app .dump daily 2026-11-07 2026-11-08 2026-11-09 2026-11-10
  seed app .dump weekly 2026-W43 2026-W44 2026-W45
  seed app .dump monthly 2026-08 2026-09 2026-10
  run_at "$WED"
  [ "$status" -eq 0 ]
  [ "$(entries "$ROOT/app/daily")" = $'app-2026-11-09.dump\napp-2026-11-10.dump\napp-2026-11-11.dump' ]
  [ "$(entries "$ROOT/app/weekly")" = $'app-2026-W45.dump\napp-2026-W46.dump' ]
  [ "$(entries "$ROOT/app/monthly")" = $'app-2026-10.dump\napp-2026-11.dump' ]
}

@test "pruning leaves alone what is not one of this entry's dumps" {
  EXTRA='KEEP_DAILY=1' write_conf '"postgres app app-pg app appdb"'
  seed app .dump daily 2026-11-10
  touch "$ROOT/app/daily/notes.txt" "$ROOT/app/daily/other-2026-11-01.dump" "$ROOT/app/daily/app-latest.dump" "$ROOT/app/daily/app-2026-11-01.sql.gz"
  run_at "$WED"
  [ "$status" -eq 0 ]
  [ "$(entries "$ROOT/app/daily")" = $'app-2026-11-01.sql.gz\napp-2026-11-11.dump\napp-latest.dump\nnotes.txt\nother-2026-11-01.dump' ]
}

@test "the defaults keep 14 daily dumps" {
  seed app .dump daily 2026-10-27 2026-10-28 2026-10-29 2026-10-30 2026-10-31 2026-11-01 2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06 2026-11-07 2026-11-08 2026-11-09 2026-11-10
  run_at "$WED"
  [ "$(entries "$ROOT/app/daily" | wc -l | tr -d ' ')" = "14" ]
  [ ! -e "$ROOT/app/daily/app-2026-10-28.dump" ]
  [ -e "$ROOT/app/daily/app-2026-10-29.dump" ]
}

# --- Failures ----------------------------------------------------------------------------------

# Today's dump is seeded too, as a good run earlier in the day would leave it: a failure must not be
# followed by keeping or pruning around the file that run left.
@test "a failed dump keeps every earlier dump, prunes nothing, and says why" {
  EXTRA='KEEP_DAILY=1' write_conf '"postgres app app-pg app appdb"'
  seed app .dump daily 2026-11-09 2026-11-10 2026-11-11
  tool_fails pg_dump appdb
  run_at "$WED"
  [ "$status" -eq 1 ]
  [ "$(entries "$ROOT/app/daily")" = $'app-2026-11-09.dump\napp-2026-11-10.dump\napp-2026-11-11.dump' ]
  [ "$(cat "$ROOT/app/daily/app-2026-11-11.dump")" = "PGDMP old 2026-11-11" ]
  [ ! -e "$ROOT/app/weekly" ]
  grep -q '\[ERROR\]: app: pg_dump: error: connection to server failed' "$LOG"
  grep -q 'the postgres dump failed (exit 1); earlier dumps kept' "$LOG"
}

@test "a failed mariadb dump is caught through the pipe into gzip" {
  write_conf '"mariadb books books-db booksdb"'
  mariadb_answers booksdb
  tool_fails mariadb-dump booksdb
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the mariadb dump failed"* ]]
}

@test "an entry that never dumped leaves no directories behind" {
  tool_fails pg_dump appdb
  run_at "$WED"
  [ "$status" -eq 1 ]
  [ ! -e "$ROOT/app" ]
}

@test "one entry failing does not stop the others" {
  write_conf '"postgres broken broken-pg u brokendb"' '"postgres app app-pg app appdb"'
  tool_fails pg_dump brokendb
  run_at "$WED"
  [ "$status" -eq 1 ]
  [ -f "$ROOT/app/daily/app-2026-11-11.dump" ]
  [[ "$output" == *"Backed up 1 of 2 database(s); failed: broken."* ]]
}

@test "a link that cannot be made fails the run" {
  mkdir -p "$ROOT/app/weekly"
  ln -s "$BATS_TEST_TMPDIR/nowhere" "$ROOT/app/weekly/app-2026-W46.dump"
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not link"*"into the weekly tier"* ]]
  [[ "$output" == *"failed: app."* ]]
}

@test "a tier directory that cannot be created fails the run" {
  mkdir -p "$ROOT/app"
  touch "$ROOT/app/monthly"
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed: app."* ]]
}

@test "an interrupted dump's leftovers are removed once a day old, and only this entry's" {
  local d="$ROOT/app/daily"
  mkdir -p "$d"
  touch "$d/.app.old111" "$d/.app.err.old222" "$d/.app.fresh333" "$d/.other.old444"
  touch -t 202611090000 "$d/.app.old111" "$d/.app.err.old222" "$d/.other.old444"
  run_at "$WED"
  [ "$status" -eq 0 ]
  [ ! -e "$d/.app.old111" ]
  [ ! -e "$d/.app.err.old222" ]
  [ -e "$d/.app.fresh333" ]
  [ -e "$d/.other.old444" ]
  grep -q "Removed an interrupted dump's leftover: .*/.app.old111" "$LOG"
}

# --- list --------------------------------------------------------------------------------------

@test "list shows each entry's dumps, newest first, tier by tier" {
  seed app .dump daily 2026-11-09 2026-11-10
  seed app .dump weekly 2026-W45
  run_at "$WED" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"app (postgres)"* ]]
  local daily_new daily_old weekly
  daily_new=$(grep -n 'app-2026-11-10.dump' <<<"$output" | cut -d: -f1)
  daily_old=$(grep -n 'app-2026-11-09.dump' <<<"$output" | cut -d: -f1)
  weekly=$(grep -n 'weekly.*app-2026-W45.dump' <<<"$output" | cut -d: -f1)
  (( daily_new < daily_old && daily_old < weekly ))
  [ ! -s "$STUB_CALLS" ]
}

# --- Configuration -----------------------------------------------------------------------------

@test "an entry with the wrong number of fields for its engine is refused before anything runs" {
  local bad
  for bad in "postgres app app-pg app" "mariadb books books-db" "mongodb media m db extra"; do
    write_conf "\"$bad\""
    run_at "$WED"
    [ "$status" -eq 1 ] || { echo "accepted: $bad" >&2; return 1; }
    [[ "$output" == *"takes NAME CONTAINER"* ]]
  done
  [ ! -s "$STUB_CALLS" ]
}

@test "an unknown engine is refused" {
  write_conf '"influxdb metrics influx x"'
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the engine must be postgres, mariadb, mongodb or sqlite"* ]]
}

@test "a sqlite entry needs an absolute path" {
  write_conf '"sqlite wiki data/wiki.db"'
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"with an absolute path"* ]]
}

@test "a field that could leave the backup directory or read as an option is refused" {
  local bad
  for bad in "postgres ../escape c u d" "postgres .hidden c u d" "postgres app -c u d" "postgres app c u d;x" "sqlite a/b /x.db"; do
    write_conf "\"$bad\""
    run_at "$WED"
    [ "$status" -eq 1 ] || { echo "accepted: $bad" >&2; return 1; }
    [[ "$output" == *"may hold only letters, digits"* ]]
  done
  [ ! -s "$STUB_CALLS" ]
}

@test "an empty database list is refused" {
  write_conf ''
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DATABASES"* ]]
}

@test "a retention that is not a positive whole number is refused" {
  EXTRA='KEEP_WEEKLY=0' write_conf '"postgres app app-pg app appdb"'
  run_at "$WED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"KEEP_WEEKLY"* ]]
}

@test "a missing docker client is reported when a server engine needs it" {
  CONFIG_FILE="$CONF" DOCKER_BIN=no-such-docker run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'no-such-docker' was not found"* ]]
}

@test "sqlite entries need no docker client, but do need sqlite3" {
  make_sqlite "$BATS_TEST_TMPDIR/wiki.db" x
  write_conf "\"sqlite wiki $BATS_TEST_TMPDIR/wiki.db\""
  CONFIG_FILE="$CONF" DOCKER_BIN=no-such-docker run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  CONFIG_FILE="$CONF" SQLITE_BIN=no-such-sqlite3 run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'no-such-sqlite3' was not found"* ]]
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

@test "restore needs an entry name and at most one dump" {
  run_script "$SCRIPT" restore
  [ "$status" -eq 1 ]
  [[ "$output" == *"restore takes an entry name"* ]]
  run_script "$SCRIPT" restore app one two
  [ "$status" -eq 1 ]
}

@test "arguments after -- are entry names" {
  run_at "$WED" -- app
  [ "$status" -eq 0 ]
  [ -f "$ROOT/app/daily/app-2026-11-11.dump" ]
}

@test "the clock is read when no moment is given" {
  CONFIG_FILE="$CONF" DOCKER_BIN=docker-cli run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$ROOT/app/daily/app-$(date -u +%F).dump" ]
}

# --- restore -----------------------------------------------------------------------------------

@test "restore warns to stop the applications, and does nothing unless confirmed" {
  run_at "$WED"
  : > "$STUB_CALLS"
  run_script_input "n" restore app
  [ "$status" -eq 1 ]
  [[ "$output" == *"STOP EVERY APPLICATION THAT USES THIS DATABASE FIRST."* ]]
  [[ "$output" == *"database appdb in container app-pg"* ]]
  [[ "$output" == *"restore cancelled; nothing was changed"* ]]
  ! grep -q pg_restore "$STUB_CALLS"
}

@test "restore with no answer at all does nothing" {
  run_at "$WED"
  : > "$STUB_CALLS"
  run_script_input "" restore app
  [ "$status" -eq 1 ]
  ! grep -q pg_restore "$STUB_CALLS"
}

@test "a confirmed postgres restore feeds the newest dump to pg_restore in one transaction" {
  run_at "$WED"
  run_script_input "y" restore app
  [ "$status" -eq 0 ]
  stub_called 'docker-cli exec -i app-pg pg_restore -U app -d appdb --clean --if-exists --single-transaction'
  [ "$(cat "$STUB_FIXTURES/docker-cli.pg_restore.stdin")" = "PGDMP app dump" ]
}

@test "--yes restores without asking, but still warns" {
  run_at "$WED"
  run_at "$WED" --yes restore app
  [ "$status" -eq 0 ]
  [[ "$output" == *"STOP EVERY APPLICATION"* ]]
  [[ "$output" != *"[y/N]"* ]]
  stub_called 'docker-cli exec -i app-pg pg_restore -U app -d appdb --clean --if-exists --single-transaction'
}

@test "restore picks a period's dump from whichever tier holds it" {
  seed app .dump monthly 2026-09
  run_at "$WED" -y restore app 2026-09
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_FIXTURES/docker-cli.pg_restore.stdin")" = "PGDMP old 2026-09" ]
}

@test "restore takes a path, but only to a dump of the entry's engine" {
  printf 'PGDMP elsewhere\n' > "$BATS_TEST_TMPDIR/copy.dump"
  run_at "$WED" -y restore app "$BATS_TEST_TMPDIR/copy.dump"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_FIXTURES/docker-cli.pg_restore.stdin")" = "PGDMP elsewhere" ]
  run_at "$WED" -y restore app "$BATS_TEST_TMPDIR/copy.sql.gz"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a postgres dump; its name must end in .dump"* ]]
  run_at "$WED" -y restore app "$BATS_TEST_TMPDIR/absent.dump"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "restore refuses a period with no dump, or an entry with none at all" {
  run_at "$WED" -y restore app 2026-01
  [ "$status" -eq 1 ]
  [[ "$output" == *"there is no dump for 2026-01"* ]]
  run_at "$WED" -y restore app
  [ "$status" -eq 1 ]
  [[ "$output" == *"there are no daily dumps"* ]]
}

@test "restore refuses a dump that fails its check, before asking" {
  mkdir -p "$ROOT/app/daily"
  printf 'garbage\n' > "$ROOT/app/daily/app-2026-11-10.dump"
  run_at "$WED" -y restore app
  [ "$status" -eq 1 ]
  [[ "$output" == *"not restoring from a dump that fails its check"* ]]
  [[ "$output" != *"STOP EVERY APPLICATION"* ]]
  ! grep -q pg_restore "$STUB_CALLS"
}

@test "a failed restore says so, with the tool's own words" {
  run_at "$WED"
  tool_fails pg_restore appdb
  run_at "$WED" -y restore app
  [ "$status" -eq 1 ]
  [[ "$output" == *"pg_restore: error: connection to server failed"* ]]
  [[ "$output" == *"app: the restore failed."* ]]
}

@test "a mariadb restore pipes the decompressed dump into the client" {
  write_conf '"mariadb books books-db booksdb"'
  mariadb_answers booksdb
  run_at "$WED"
  run_at "$WED" -y restore books
  [ "$status" -eq 0 ]
  stub_called 'docker-cli exec -i books-db sh -c'
  [[ "$(cat "$STUB_FIXTURES/docker-cli.mariadb.stdin")" == *"CREATE DATABASE books;"* ]]
}

@test "a mongodb restore drops and replaces only the entry's database" {
  write_conf '"mongodb media media-mongo mediadb"'
  mongo_answers mediadb
  run_at "$WED"
  run_at "$WED" -y restore media
  [ "$status" -eq 0 ]
  stub_called 'docker-cli exec -i media-mongo mongorestore --quiet --archive --gzip --drop --nsInclude mediadb.*'
}

@test "a sqlite restore replaces the file, keeps its mode, and deletes the stale -wal and -shm" {
  local db="$BATS_TEST_TMPDIR/wiki.db"
  make_sqlite "$db" original
  write_conf "\"sqlite wiki $db\""
  run_at "$WED"
  sqlite3 "$db" "UPDATE t SET v = 'changed'; PRAGMA wal_checkpoint;" >/dev/null
  # Not 600, which is what a new temporary file gets anyway.
  chmod 644 "$db"
  printf 'stale' > "$db-wal"
  printf 'stale' > "$db-shm"
  run_at "$WED" -y restore wiki
  [ "$status" -eq 0 ]
  [[ "$output" == *"the file $db (its -wal and -shm files are deleted)"* ]]
  [ ! -e "$db-wal" ]
  [ ! -e "$db-shm" ]
  [ "$(mode_of "$db")" = "644" ]
  [ "$(sqlite3 "$db" 'SELECT v FROM t')" = "original" ]
}

@test "a sqlite restore whose directory is gone is refused" {
  local db="$BATS_TEST_TMPDIR/gone/wiki.db"
  make_sqlite "$db" original
  write_conf "\"sqlite wiki $db\""
  run_at "$WED"
  rm -rf "$BATS_TEST_TMPDIR/gone"
  run_at "$WED" -y restore wiki
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

# --- verify ------------------------------------------------------------------------------------

########################################
# Sets up the throwaway server the double pretends to run, with the given counts.
# Arguments:
#   client: The tool that reports the counts (psql, mariadb or mongosh).
#   counts: What it reports: "TABLES ROWS".
########################################
throwaway_answers() {
  printf 'example/image:1\n' > "$STUB_FIXTURES/docker-cli.inspect.stdout"
  printf 'c0ffee\n' > "$STUB_FIXTURES/docker-cli.run.stdout"
  printf '%s\n' "$2" > "$STUB_FIXTURES/docker-cli.$1.stdout"
}

@test "verify restores a postgres dump into a throwaway container from the same image" {
  run_at "$WED"
  throwaway_answers psql '27 149327'
  run_at "$WED" verify
  [ "$status" -eq 0 ]
  grep -q '^docker-cli run -d --rm --name db-backup-verify-app-[0-9]* --network none .* example/image:1$' "$STUB_CALLS"
  grep -q '^docker-cli exec -i db-backup-verify-app-[0-9]* pg_restore -U postgres -d verify --no-owner --exit-on-error$' "$STUB_CALLS"
  grep -q '^docker-cli rm -f db-backup-verify-app-[0-9]*$' "$STUB_CALLS"
  [[ "$output" == *"restores, with 27 tables and 149327 rows"* ]]
  grep -q "query_to_xml(format('SELECT count(\*) AS c FROM %I.%I'" "$STUB_CALLS"
  [ "$(cat "$STUB_FIXTURES/docker-cli.pg_restore.stdin")" = "PGDMP app dump" ]
}

@test "verify fails a dump that restores no tables, and still removes the container" {
  run_at "$WED"
  throwaway_answers psql '0 0'
  run_at "$WED" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"the restored database holds no tables (got '0 0')"* ]]
  grep -q '^docker-cli rm -f db-backup-verify-app-' "$STUB_CALLS"
  [[ "$output" == *"Verified 0 of 1 database(s); failed: app."* ]]
}

@test "verify gives up on a throwaway server that never becomes ready" {
  run_at "$WED"
  throwaway_answers psql '27 149327'
  printf '1' > "$STUB_FIXTURES/docker-cli.pg_isready.fail"
  run_at "$WED" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"was not ready after 1s"* ]]
  ! grep -q 'pg_restore' "$STUB_CALLS"
}

@test "verify reports a restore into the throwaway container that fails" {
  run_at "$WED"
  throwaway_answers psql '27 149327'
  printf '1' > "$STUB_FIXTURES/docker-cli.pg_restore.fail"
  printf 'pg_restore: error: bad archive\n' > "$STUB_FIXTURES/docker-cli.pg_restore.stderr"
  run_at "$WED" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"pg_restore: error: bad archive"* ]]
  [[ "$output" == *"did not restore into a throwaway container"* ]]
}

@test "verify restores mariadb and mongodb dumps the same way" {
  write_conf '"mariadb books books-db booksdb"' '"mongodb media media-mongo mediadb"'
  mariadb_answers booksdb
  mongo_answers mediadb
  run_at "$WED"
  throwaway_answers mariadb $'12\t3400'
  printf '3 10\n' > "$STUB_FIXTURES/docker-cli.mongosh.stdout"
  run_at "$WED" verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"books-2026-11-11.sql.gz restores, with 12 tables and 3400 rows"* ]]
  [[ "$output" == *"media-2026-11-11.archive.gz restores, with 3 collections and 10 documents"* ]]
  # The count queries name the entry's own database.
  grep -q 'table_schema = "booksdb"' "$STUB_CALLS"
  grep -q 'db.getSiblingDB("mediadb")' "$STUB_CALLS"
  grep -q 'MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1' "$STUB_CALLS"
  grep -q '^docker-cli exec -i db-backup-verify-media-[0-9]* mongorestore --quiet --archive --gzip$' "$STUB_CALLS"
  # Each throwaway container is gone before the next one starts, not left for the end of the run.
  local removed started
  removed=$(grep -n '^docker-cli rm -f db-backup-verify-books-' "$STUB_CALLS" | head -1 | cut -d: -f1)
  started=$(grep -n '^docker-cli run .*db-backup-verify-media-' "$STUB_CALLS" | cut -d: -f1)
  (( removed < started ))
}

@test "verify checks a sqlite copy's integrity without docker" {
  make_sqlite "$BATS_TEST_TMPDIR/wiki.db" x
  write_conf "\"sqlite wiki $BATS_TEST_TMPDIR/wiki.db\""
  run_at "$WED"
  CONFIG_FILE="$CONF" DOCKER_BIN=no-such-docker run_script "$SCRIPT" verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"passes SQLite's integrity check, with 1 table and 1 row"* ]]
}

@test "verify fails a sqlite copy that is not a database" {
  make_sqlite "$BATS_TEST_TMPDIR/wiki.db" x
  write_conf "\"sqlite wiki $BATS_TEST_TMPDIR/wiki.db\""
  run_at "$WED"
  printf 'corrupt' | gzip > "$ROOT/wiki/daily/wiki-2026-11-11.sqlite.gz"
  run_at "$WED" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not hold a SQLite database"* ]]
}

# The header check on a stored copy reads only its first bytes, so a copy whose header is intact and
# whose body is not gets through it, and has to be caught by the full check verify and restore run.
@test "verify and restore catch a sqlite copy with a good header and a corrupt body" {
  local db="$BATS_TEST_TMPDIR/wiki.db"
  make_sqlite "$db" original
  write_conf "\"sqlite wiki $db\""
  { printf 'SQLite format 3\0'; head -c 4096 /dev/zero | tr '\0' 'x'; } | gzip > "$BATS_TEST_TMPDIR/bad.sqlite.gz"
  mkdir -p "$ROOT/wiki/daily"
  cp "$BATS_TEST_TMPDIR/bad.sqlite.gz" "$ROOT/wiki/daily/wiki-2026-11-11.sqlite.gz"
  run_at "$WED" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"SQLite integrity_check of"*"failed"* ]]
  run_at "$WED" -y restore wiki
  [ "$status" -eq 1 ]
  [ "$(sqlite3 "$db" 'SELECT v FROM t')" = "original" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name '.wiki.db.restore.*')" ]
}

# A file that is renamed into place is created beside its destination, since a rename is atomic only
# within one filesystem; everything that is only read and thrown away goes under TMPDIR. mktemp and mv are
# wrapped for the run to record where each file was made and what was renamed.
@test "only files renamed into place are made beside their destination; scratch goes under TMPDIR" {
  local db_dir="$BATS_TEST_TMPDIR/app data" scratch="$BATS_TEST_TMPDIR/scratch" log="$BATS_TEST_TMPDIR/files.log"
  local db="$db_dir/wiki.db"
  make_sqlite "$db" original
  mkdir -p "$scratch"
  write_conf "\"sqlite wiki $db\""
  local wrappers="
    mktemp() { local made; made=\$(command mktemp \"\$@\") || return; printf 'made %s\\n' \"\$made\" >> '$log'; printf '%s\\n' \"\$made\"; }
    mv() { printf 'renamed %s\\n' \"\$3\" >> '$log'; command mv \"\$@\"; }
  "
  local cmd
  for cmd in "" "verify" "-y restore wiki"; do
    TMPDIR="$scratch" CONFIG_FILE="$CONF" DB_BACKUP_NOW="$WED" run_snippet "$SCRIPT" "$wrappers main $cmd"
    [ "$status" -eq 0 ] || { echo "'$cmd' failed: $output" >&2; return 1; }
  done

  # Renamed into place: the in-progress dump, and the restored copy.
  grep -qx "renamed $ROOT/wiki/daily/\\.wiki\\.[A-Za-z0-9]\\{6\\}" "$log"
  grep -qx "renamed $db_dir/\\.wiki\\.db\\.restore\\.[A-Za-z0-9]\\{6\\}" "$log"
  [ "$(grep -c '^renamed ' "$log")" -eq 2 ]
  # Everything else was made under TMPDIR, and nothing is left there or beside the destinations.
  local made
  while read -r _ made; do
    case "$made" in
      "$ROOT/wiki/daily/.wiki."?????? | "$db_dir/.wiki.db.restore."?????? | "$scratch/"*) ;;
      *) echo "made outside its place: $made" >&2; return 1 ;;
    esac
  done < <(grep '^made ' "$log")
  [ "$(grep -c "^made $scratch/" "$log")" -ge 4 ]
  [ -z "$(ls -A "$scratch")" ]
  [ -z "$(find "$ROOT/wiki" "$db_dir" -name '.wiki*')" ]
}

@test "verify counts every sqlite table's rows, whatever the table is called" {
  local db="$BATS_TEST_TMPDIR/wiki.db"
  sqlite3 "$db" "CREATE TABLE a(x); CREATE TABLE \"o\"\"dd name\"(y); INSERT INTO a VALUES (1), (2); INSERT INTO \"o\"\"dd name\" VALUES (3);" >/dev/null
  write_conf "\"sqlite wiki $db\""
  run_at "$WED"
  run_at "$WED" verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"with 2 tables and 3 rows"* ]]
}

@test "verify fails when the restored database's counts cannot be read" {
  run_at "$WED"
  throwaway_answers psql 'not a number'
  run_at "$WED" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds no tables (got 'not a number')"* ]]
}

@test "verify reads the counts from the client's last line" {
  run_at "$WED"
  throwaway_answers psql $'NOTICE: something\n5 42'
  run_at "$WED" verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"with 5 tables and 42 rows"* ]]
}

@test "verify of an entry with no dumps fails" {
  run_at "$WED" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"there are no daily dumps"* ]]
}

# --- Remaining branches ------------------------------------------------------------------------

@test "--no-color still backs up" {
  run_at "$WED" --no-color
  [ "$status" -eq 0 ]
  [ -f "$ROOT/app/daily/app-2026-11-11.dump" ]
}

@test "a sqlite dump that is not gzipped is refused before a restore" {
  local db="$BATS_TEST_TMPDIR/wiki.db"
  make_sqlite "$db" original
  write_conf "\"sqlite wiki $db\""
  mkdir -p "$ROOT/wiki/daily"
  printf 'plain text' > "$ROOT/wiki/daily/wiki-2026-11-10.sqlite.gz"
  run_at "$WED" -y restore wiki
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a gzipped SQLite copy"* ]]
  [ "$(sqlite3 "$db" 'SELECT v FROM t')" = "original" ]
}

# The owner is checked and set before the rename, so a restore that cannot give the file its owner
# leaves the database untouched. stat_owner and chown are replaced for the run, since whether a real
# chown can fail depends on whether the suite runs as root.
@test "a sqlite restore that cannot keep the file's owner leaves the file alone" {
  local db="$BATS_TEST_TMPDIR/wiki.db"
  make_sqlite "$db" original
  write_conf "\"sqlite wiki $db\""
  run_at "$WED"
  sqlite3 "$db" "UPDATE t SET v = 'current';" >/dev/null
  local dump="$ROOT/wiki/daily/wiki-2026-11-11.sqlite.gz"
  run_snippet "$SCRIPT" "
    stat_owner() { case \"\$1\" in *.restore.*) echo 1:1 ;; *) echo 0:0 ;; esac; }
    chown() { return 1; }
    restore_sqlite '$db' '$dump' '$BATS_TEST_TMPDIR/errors'
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot give the restored file the owner 0:0"* ]]
  [ "$(sqlite3 "$db" 'SELECT v FROM t')" = "current" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name '.wiki.db.restore.*')" ]
}

# The header checks read a few bytes from a decompressing pipe and close it. Under systemd, which starts
# services with SIGPIPE ignored, gzip then sees EPIPE instead of dying quietly, and complains on stderr on
# any copy larger than the pipe buffer. The complaint carries nothing, since gzip -t has already proven the
# stream. The runs ignore SIGPIPE the way systemd does, which children inherit across exec.
########################################
# Runs the script on 2026-11-11 with SIGPIPE ignored, as systemd runs a service.
# Arguments:
#   The script's own arguments.
########################################
run_as_service() {
  CONFIG_FILE="$CONF" DOCKER_BIN=docker-cli DB_BACKUP_NOW="$WED" run_snippet "$SCRIPT" "trap '' PIPE; main $*"
}

@test "checking a large sqlite copy under systemd prints no broken-pipe complaint" {
  local db="$BATS_TEST_TMPDIR/big.db"
  sqlite3 "$db" "CREATE TABLE t(v); WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 400) INSERT INTO t SELECT randomblob(4096) FROM n;" >/dev/null
  write_conf "\"sqlite big $db\""
  run_as_service
  [ "$status" -eq 0 ]
  [[ "$output" != *"Broken pipe"* ]]
  run_as_service verify
  [ "$status" -eq 0 ]
  [[ "$output" != *"Broken pipe"* ]]
}

@test "checking a large mongodb archive under systemd prints no broken-pipe complaint" {
  write_conf '"mongodb media media-mongo mediadb"'
  { printf '\x6d\xe2\x99\x81'; head -c 1048576 /dev/urandom; } | gzip > "$STUB_FIXTURES/docker-cli.mongodump.mediadb.stdout"
  run_as_service
  [ "$status" -eq 0 ]
  [[ "$output" != *"Broken pipe"* ]]
}

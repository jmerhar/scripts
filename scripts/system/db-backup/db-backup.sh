#!/usr/bin/env bash
#
# Backs up databases with a daily, weekly and monthly rotation, and verifies and restores the backups.
#
# Four engines: Postgres, MariaDB and MongoDB are dumped inside their Docker containers with the tools the
# images ship, and SQLite files are copied on the host. Each entry in the configuration is dumped to
# <BACKUP_DIR>/<name>/daily/<name>-YYYY-MM-DD.<ext>. The first successful dump of an ISO week is also kept
# as weekly/<name>-YYYY-Www.<ext>, and the first of a month as monthly/<name>-YYYY-MM.<ext>; those are
# hard links, so a dump kept in several tiers takes its space once. Each tier is then pruned to its newest
# KEEP_* files.

set -o errexit
set -o nounset
set -o pipefail

# The docker client and sqlite3, the moment the run treats as now (epoch seconds), and how long verify
# waits for a throwaway server and between its checks. All are read from the environment so a test can
# supply doubles, choose the day and keep the wait short; unset, they are the real tools, the clock and
# two minutes polled every two seconds.
: "${DOCKER_BIN:=docker}"
: "${SQLITE_BIN:=sqlite3}"
: "${DB_BACKUP_NOW:=}"
: "${VERIFY_TIMEOUT:=120}"
: "${VERIFY_POLL:=2}"
readonly DOCKER_BIN SQLITE_BIN DB_BACKUP_NOW VERIFY_TIMEOUT VERIFY_POLL

# --- Shared Library ---
# shellcheck source=../../lib/cli.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/cli.sh"
# @include ../../lib/cli.sh
# shellcheck source=../../lib/colors.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/colors.sh"
# @include ../../lib/colors.sh
# shellcheck source=../../lib/config.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/config.sh"
# @include ../../lib/config.sh
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
# shellcheck source=../../lib/platform.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/platform.sh"
# @include ../../lib/platform.sh
# shellcheck source=../../lib/prompt.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/prompt.sh"
# @include ../../lib/prompt.sh

# The scripts run inside the containers. Each reads its arguments as "$1"…, so no value from the
# configuration is ever spliced into shell code. Credentials come from the container's own environment,
# which is where the official images keep them, so the configuration holds none. The MariaDB client reads
# its password from MYSQL_PWD rather than from -p, which keeps it out of the container's process list.
# shellcheck disable=SC2016  # expanded by the shell inside the container, not here
readonly MARIADB_DUMP_SCRIPT='tool=$(command -v mariadb-dump || command -v mysqldump) && MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}" exec "$tool" -uroot --single-transaction --routines --triggers --databases "$1"'
# shellcheck disable=SC2016
readonly MARIADB_CLIENT_SCRIPT='tool=$(command -v mariadb || command -v mysql) && MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}" exec "$tool" -uroot "$@"'
# shellcheck disable=SC2016
readonly MARIADB_PING_SCRIPT='tool=$(command -v mariadb-admin || command -v mysqladmin) && exec "$tool" ping -h 127.0.0.1 --silent'

# Retention defaults, which the configuration may override.
KEEP_DAILY=14
KEEP_WEEKLY=4
KEEP_MONTHLY=12

# The command and its arguments.
_command=backup
_args=()
_assume_yes=false
_no_color=false
# Holds the most recent line entered by the user (set by prompt_line).
_answer=""
# Temporary files and throwaway containers, removed on exit however the run ends.
_tmp_files=()
_tmp_dirs=()
_verify_containers=()

#######################################
# Prints the usage.
# Globals:
#   SCRIPT_NAME
# Outputs:
#   The usage text on stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [backup] [NAME...]
       ${SCRIPT_NAME} [OPTIONS] list [NAME...]
       ${SCRIPT_NAME} [OPTIONS] verify [NAME...]
       ${SCRIPT_NAME} [OPTIONS] restore NAME [DUMP]

Backs up the databases listed in the configuration file with a daily, weekly and
monthly rotation, and verifies and restores the backups.

Commands:
  backup     Dump every entry, or the named ones (the default)
  list       Show each entry's dumps, newest first
  verify     Restore each entry's newest dump into a throwaway container, or check
             a SQLite copy's integrity, to prove it restores
  restore    Replace an entry's database with its newest dump, or with DUMP: a
             path, or a period such as 2026-11-11, 2026-W46 or 2026-11

Settings are read from a configuration file (e.g. /etc/${SCRIPT_NAME}.conf).

Options:
  -y, --yes       Restore without asking for confirmation
  -C, --no-color  Disable coloured output
  -d, --debug     Enable debug logging
  -h, --help      Show this help message
      --version   Show the version and exit
EOF
}

#######################################
# Parses the command line.
# Globals:
#   _command, _args, _assume_yes, _no_color
# Arguments:
#   The command-line arguments.
#######################################
parse_options() {
  local -a positional=()
  while (( $# > 0 )); do
    case "$1" in
      -y | --yes)      _assume_yes=true; shift ;;
      -C | --no-color) _no_color=true; shift ;;
      -d | --debug)    enable_debug_mode; shift ;;
      -h | --help)     show_usage; exit 0 ;;
      --version)       show_version; exit 0 ;;
      --)              shift; positional+=("$@"); break ;;
      -*)              die_usage "Unknown option '$1'." ;;
      *)               positional+=("$1"); shift ;;
    esac
  done

  if (( ${#positional[@]} > 0 )); then
    case "${positional[0]}" in
      backup | list | verify | restore)
        _command="${positional[0]}"
        positional=("${positional[@]:1}")
        ;;
    esac
  fi
  _args=("${positional[@]}")

  if [[ "${_command}" == restore ]] && (( ${#_args[@]} < 1 || ${#_args[@]} > 2 )); then
    die_usage "restore takes an entry name and, optionally, the dump to restore."
  fi
}

#######################################
# Removes temporary files and directories, and throwaway containers.
# Globals:
#   _tmp_files, _tmp_dirs, _verify_containers, DOCKER_BIN
#######################################
cleanup() {
  local f
  for f in "${_tmp_files[@]}"; do
    rm -f -- "${f}"
  done
  for f in "${_tmp_dirs[@]}"; do
    rm -rf -- "${f}"
  done
  for f in "${_verify_containers[@]}"; do
    "${DOCKER_BIN}" rm -f "${f}" >/dev/null 2>&1 || true
  done
}

#######################################
# Splits a DATABASES entry into its fields and checks them.
#
# Each engine takes a fixed set of fields, except sqlite, whose path is the rest of the line so it may
# hold spaces. Names, containers, users and databases are limited to characters that can neither reach
# outside the backup directory nor be read as an option or as shell syntax.
# Arguments:
#   entry: One DATABASES entry.
#   out:   Name of an array to receive: engine, name, then the engine's own fields. It must not be called
#          "parts" or "words".
# Returns:
#   1 when the entry is malformed.
#######################################
parse_entry() {
  local entry="$1"
  local -n out="$2"
  local engine name rest
  local -a words parts
  read -r engine name rest <<<"${entry}"
  read -r -a words <<<"${rest}"

  case "${engine}" in
    postgres) (( ${#words[@]} == 3 )) || { log_error "Entry '${entry}': postgres takes NAME CONTAINER USER DATABASE."; return 1; } ;;
    mariadb | mongodb) (( ${#words[@]} == 2 )) || { log_error "Entry '${entry}': ${engine} takes NAME CONTAINER DATABASE."; return 1; } ;;
    sqlite)
      if [[ "${rest}" != /* ]]; then
        log_error "Entry '${entry}': sqlite takes NAME PATH, with an absolute path."
        return 1
      fi
      ;;
    *) log_error "Entry '${entry}': the engine must be postgres, mariadb, mongodb or sqlite."; return 1 ;;
  esac

  local field
  for field in "${name}" "${words[@]}"; do
    [[ "${engine}" == sqlite && "${field}" != "${name}" ]] && break
    if [[ ! "${field}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      log_error "Entry '${entry}': '${field}' may hold only letters, digits and . _ - and may not start with a dot or dash."
      return 1
    fi
  done

  if [[ "${engine}" == sqlite ]]; then
    parts=(sqlite "${name}" "${rest}")
  else
    parts=("${engine}" "${name}" "${words[@]}")
  fi
  # shellcheck disable=SC2034  # out is a nameref, so this assigns the caller's array
  out=("${parts[@]}")
}

#######################################
# Prints the file extension an engine's dumps carry.
# Arguments:
#   engine: The entry's engine.
#######################################
dump_ext() {
  case "$1" in
    postgres) printf '.dump' ;;
    mariadb)  printf '.sql.gz' ;;
    mongodb)  printf '.archive.gz' ;;
    sqlite)   printf '.sqlite.gz' ;;
  esac
}

#######################################
# Checks a SQLite file with the given pragma.
# Arguments:
#   file:   The database file.
#   pragma: quick_check or integrity_check.
# Returns:
#   1 unless the check reports ok.
#######################################
sqlite_check() {
  local file="$1" pragma="$2" result
  result=$("${SQLITE_BIN}" -readonly "${file}" "PRAGMA ${pragma};" 2>&1) || true
  case "${result}" in
    ok) return 0 ;;
  esac
  log_error "SQLite ${pragma} of ${file} failed: ${result//$'\n'/; }"
  return 1
}

#######################################
# Checks that a stored dump is what its engine produces, before it is kept, verified or restored.
#
# Each check reads the format rather than trusting the exit status that produced it: a custom-format
# Postgres dump starts with PGDMP, a MariaDB dump ends with mysqldump's completion line, a MongoDB archive
# starts with its magic number, and a SQLite copy is an intact gzip stream holding a SQLite header. The
# SQLite check writes nothing: the full integrity checks run where a decompressed copy has to exist anyway,
# before gzip on backup and beside the target on restore, so a large database is not written out again
# just to be read. The MongoDB and SQLite checks read a few bytes and close the pipe, so gzip's stderr is
# discarded there: with SIGPIPE ignored, as systemd starts a service, gzip reports the closed pipe as an
# error, and gzip -t has already proven the stream intact.
# Arguments:
#   engine: The entry's engine.
#   file:   The dump.
# Returns:
#   1 when the file is not a complete dump for that engine.
#######################################
validate_dump() {
  local engine="$1" file="$2" probe
  case "${engine}" in
    postgres)
      probe=$(head -c 5 "${file}")
      case "${probe}" in
        PGDMP) return 0 ;;
      esac
      log_error "${file} is not a pg_dump custom-format dump."
      return 1
      ;;
    mariadb)
      if gzip -t "${file}" 2>/dev/null; then
        probe=$(gzip -dc "${file}" | tail -n 1)
        case "${probe}" in
          "-- Dump completed"*) return 0 ;;
        esac
      fi
      log_error "${file} is not a complete MariaDB dump."
      return 1
      ;;
    mongodb)
      if gzip -t "${file}" 2>/dev/null; then
        probe=$(gzip -dc "${file}" 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' \n') || true
        case "${probe}" in
          6de29981) return 0 ;;
        esac
      fi
      log_error "${file} is not a mongodump archive."
      return 1
      ;;
    sqlite)
      if ! gzip -t "${file}" 2>/dev/null; then
        log_error "${file} is not a gzipped SQLite copy."
        return 1
      fi
      probe=$(gzip -dc "${file}" 2>/dev/null | head -c 15) || true
      case "${probe}" in
        "SQLite format 3") return 0 ;;
      esac
      log_error "${file} does not hold a SQLite database."
      return 1
      ;;
  esac
}

#######################################
# Creates a scratch file under TMPDIR.
#
# Scratch is whatever is read and thrown away rather than renamed into place: a tool's captured stderr,
# and a decompressed SQLite copy that is only checked. It goes where TMPDIR says, so whoever deploys the
# script decides whether it lives in memory, on the system disk or somewhere larger. Files that end up
# renamed into place are created beside their destination instead, since a rename is atomic only within
# one filesystem.
# Arguments:
#   name:   The entry's name.
#   suffix: What the file is for, as part of its name.
# Outputs:
#   The file's path.
# Returns:
#   1 when it cannot be created.
#######################################
scratch_mktemp() {
  mktemp "${TMPDIR:-/tmp}/db-backup.$1.$2.XXXXXX"
}

#######################################
# Logs what a database tool wrote on stderr.
#
# The tool's own words are what say why a dump or a restore failed, so they are logged line by line
# rather than left on a stderr that only the journal sees: as errors when it failed, warnings otherwise.
# Arguments:
#   name:   The entry, as a prefix.
#   file:   The captured stderr.
#   failed: true when the tool failed.
#######################################
log_tool_output() {
  local name="$1" file="$2" failed="$3" line
  while IFS= read -r line; do
    if [[ "${failed}" == true ]]; then
      log_error "${name}: ${line}"
    else
      log_warn "${name}: ${line}"
    fi
  done < "${file}"
}

#######################################
# Runs an entry's dump tool, writing the dump to a file.
# Globals:
#   DOCKER_BIN, SQLITE_BIN, MARIADB_DUMP_SCRIPT, _tmp_dirs
# Arguments:
#   out:    Name of the entry's array, as parse_entry fills it.
#   tmp:    Where to write the dump.
#   errors: Where to write the tool's stderr.
# Returns:
#   The tool's exit status, or 1 when the copy fails a check.
#######################################
run_dump() {
  local -n e="$1"
  local tmp="$2" errors="$3" scratch raw
  case "${e[0]}" in
    postgres)
      "${DOCKER_BIN}" exec "${e[2]}" pg_dump -U "${e[3]}" -d "${e[4]}" -Fc > "${tmp}" 2> "${errors}"
      ;;
    mariadb)
      "${DOCKER_BIN}" exec "${e[2]}" sh -c "${MARIADB_DUMP_SCRIPT}" sh "${e[3]}" 2> "${errors}" | gzip > "${tmp}"
      ;;
    mongodb)
      "${DOCKER_BIN}" exec "${e[2]}" mongodump --quiet --archive --gzip --db "${e[3]}" > "${tmp}" 2> "${errors}"
      ;;
    sqlite)
      # VACUUM INTO on a read-only connection takes a consistent copy while the application keeps writing,
      # WAL included, and leaves the source untouched. The copy is scratch, so it goes under TMPDIR, in a
      # private directory because VACUUM INTO refuses a file that already exists. Its path is a SQL string
      # literal, so its quotes are doubled.
      scratch=$(mktemp -d "${TMPDIR:-/tmp}/db-backup.${e[1]}.copy.XXXXXX") || return 1
      _tmp_dirs+=("${scratch}")
      raw="${scratch}/copy.db"
      "${SQLITE_BIN}" -readonly "${e[2]}" "VACUUM INTO '${raw//\'/\'\'}';" 2> "${errors}" || return 1
      sqlite_check "${raw}" quick_check || return 1
      gzip -c "${raw}" > "${tmp}" || return 1
      rm -rf -- "${scratch}"
      ;;
  esac
}

#######################################
# Writes an entry's dump to a temporary file, checks it, and renames it over the day's file.
#
# Every step returns on failure explicitly, because the caller runs this as an `if` condition, where
# errexit does not apply.
# Arguments:
#   entry:  Name of the entry's array.
#   file:   The daily file to write.
#   tmp:    The temporary file to dump into.
#   errors: Where to write the tool's stderr.
# Returns:
#   1 when the dump fails or is not a complete dump.
#######################################
write_dump() {
  local -n en="$1"
  local file="$2" tmp="$3" errors="$4" status=0
  local name="${en[1]}"

  log_debug "Dumping ${name} (${en[0]})."
  run_dump "$1" "${tmp}" "${errors}" || status=$?
  if (( status == 0 )); then
    log_tool_output "${name}" "${errors}" false
  else
    log_tool_output "${name}" "${errors}" true
    log_error "${name}: the ${en[0]} dump failed (exit ${status}); earlier dumps kept."
    return 1
  fi

  if ! validate_dump "${en[0]}" "${tmp}"; then
    log_error "${name}: the new dump is incomplete; earlier dumps kept."
    return 1
  fi

  chmod 0640 "${tmp}" || return 1
  mv -f -- "${tmp}" "${file}" || return 1
  log_info "${name}: dumped to ${file} ($(( $(stat_size "${file}") / 1024 )) KiB)."
}

#######################################
# Dumps one entry into the day's daily file.
#
# The tool writes to a hidden temporary file beside the target, on the same filesystem so the final rename
# is atomic, and that file replaces the day's file only when the tool succeeded and the result passes
# validate_dump, so a failed dump leaves every earlier dump as it was. The replacement is a rename, so a
# second run on the same day puts a new file in place without touching the one a weekly or monthly link
# still holds. The tool's stderr is scratch, under TMPDIR. Both are removed as soon as the dump is done
# either way, rather than left for the EXIT trap, so the caller can tell an empty directory from one
# holding dumps.
# Globals:
#   _tmp_files
# Arguments:
#   entry: Name of the entry's array.
#   file:  The daily file to write.
# Returns:
#   1 when the dump fails or is not a complete dump.
#######################################
dump_entry() {
  local -n de="$1"
  local file="$2" tmp errors status=0
  local name="${de[1]}"
  tmp=$(mktemp "$(dirname "${file}")/.${name}.XXXXXX") || return 1
  errors=$(scratch_mktemp "${name}" err) || return 1
  _tmp_files+=("${tmp}" "${errors}")
  write_dump "$1" "${file}" "${tmp}" "${errors}" || status=1
  rm -f -- "${tmp}" "${errors}"
  return "${status}"
}

#######################################
# Keeps a dump in a weekly or monthly tier when that tier has nothing for the period yet.
#
# Promotion goes by whether the period is covered rather than by the day of the week or month, so a run
# missed on one particular day costs nothing: the next dump in the same week or month is kept instead.
# A link that appears between the check and ln was made by a run overlapping this one, and covers the
# period just the same.
# Arguments:
#   file:      The daily dump.
#   tier_file: Where the tier keeps its copy for the period.
#   tier:      The tier's name, for the log.
# Returns:
#   1 when the link cannot be made.
#######################################
promote() {
  local file="$1" tier_file="$2" tier="$3"
  if [[ -e "${tier_file}" ]]; then
    return 0
  fi
  if ! ln -- "${file}" "${tier_file}" 2>/dev/null; then
    if [[ -e "${tier_file}" ]]; then
      return 0
    fi
    log_error "Could not link ${file} into the ${tier} tier as ${tier_file}."
    return 1
  fi
  log_info "Kept as ${tier}: ${tier_file}"
}

#######################################
# Prints the glob matching an entry's dumps in a tier.
#
# The names carry their period, and each format sorts in date order, so the oldest are first in the glob.
# Arguments:
#   name, ext: The entry's name and dump extension.
#   tier:      daily, weekly or monthly.
#######################################
tier_glob() {
  local name="$1" ext="$2" tier="$3"
  case "${tier}" in
    daily)   printf '%s' "${name}-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]${ext}" ;;
    weekly)  printf '%s' "${name}-[0-9][0-9][0-9][0-9]-W[0-9][0-9]${ext}" ;;
    monthly) printf '%s' "${name}-[0-9][0-9][0-9][0-9]-[0-9][0-9]${ext}" ;;
  esac
}

#######################################
# Fills an array with an entry's dumps in a tier, oldest first.
# Arguments:
#   result: Name of the array to fill. It must not be called "found".
#   dir, name, ext, tier: Where to look and what for.
#######################################
tier_files() {
  local -n result="$1"
  local dir="$2" name="$3" ext="$4" tier="$5" pattern
  local -a found
  pattern=$(tier_glob "${name}" "${ext}" "${tier}")
  shopt -s nullglob
  # shellcheck disable=SC2206  # the pattern is meant to expand as a glob
  found=("${dir}"/${pattern})
  shopt -u nullglob
  # shellcheck disable=SC2034  # result is a nameref
  result=("${found[@]}")
}

#######################################
# Deletes all but the newest files in a tier.
# Arguments:
#   dir, name, ext, tier: The tier, and the entry whose dumps it holds.
#   keep: How many to keep.
# Returns:
#   1 when a file cannot be removed.
#######################################
prune() {
  local dir="$1" name="$2" ext="$3" tier="$4" keep="$5" i
  local -a files
  tier_files files "${dir}" "${name}" "${ext}" "${tier}"
  for (( i = 0; i < ${#files[@]} - keep; i++ )); do
    rm -f -- "${files[i]}" || return 1
    log_info "Pruned ${files[i]}"
  done
}

#######################################
# Removes an entry's temporary files that are more than a day old.
#
# The EXIT trap removes them on any exit bash sees, but a SIGKILL or a power cut mid-dump leaves them in
# daily/, where the prune glob never matches them. A day is far longer than any dump takes, so a run
# overlapping this one keeps its own.
# Arguments:
#   dir:  The entry's daily directory.
#   name: The entry's name.
#######################################
remove_stale_temps() {
  local dir="$1" name="$2" stale
  while IFS= read -r stale; do
    rm -f -- "${stale}"
    log_info "Removed an interrupted dump's leftover: ${stale}"
  done < <(find "${dir}" -maxdepth 1 -type f -name ".${name}.*" -mmin +1440)
}

#######################################
# Backs up one entry: dumps it, keeps it in the tiers, and prunes them.
#
# The tier directories are created only once a dump has succeeded, so an entry that never dumps leaves
# nothing behind but an empty daily/ that is removed again. Pruning follows a successful dump only, so a
# database that keeps failing never loses the dumps it has. Like dump_entry, it returns on each failure
# explicitly, since it runs as an `if` condition.
# Globals:
#   BACKUP_DIR, KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY
# Arguments:
#   entry: Name of the entry's array.
#   day, week, month: The period stamps of this run.
# Returns:
#   1 when the dump, a link or a prune failed.
#######################################
backup_entry() {
  local -n be="$1"
  local day="$2" week="$3" month="$4"
  local name="${be[1]}" ext
  ext=$(dump_ext "${be[0]}")
  local base="${BACKUP_DIR}/${name}"
  local file="${base}/daily/${name}-${day}${ext}"

  mkdir -p "${base}/daily" || return 1
  remove_stale_temps "${base}/daily" "${name}"
  if ! dump_entry "$1" "${file}"; then
    rmdir "${base}/daily" "${base}" 2>/dev/null || true
    return 1
  fi
  mkdir -p "${base}/weekly" "${base}/monthly" || return 1

  promote "${file}" "${base}/weekly/${name}-${week}${ext}" weekly || return 1
  promote "${file}" "${base}/monthly/${name}-${month}${ext}" monthly || return 1

  prune "${base}/daily" "${name}" "${ext}" daily "${KEEP_DAILY}" || return 1
  prune "${base}/weekly" "${name}" "${ext}" weekly "${KEEP_WEEKLY}" || return 1
  prune "${base}/monthly" "${name}" "${ext}" monthly "${KEEP_MONTHLY}" || return 1
}

#######################################
# Prints an entry's dumps, newest first, tier by tier.
# Globals:
#   BACKUP_DIR
# Arguments:
#   entry: Name of the entry's array.
# Outputs:
#   The entry's heading, then one line per dump: its tier, size and path.
#######################################
list_entry() {
  local -n le="$1"
  local name="${le[1]}" ext tier i size
  local -a files
  ext=$(dump_ext "${le[0]}")
  printf '%s\n' "${_C_BOLD}${name}${_C_RESET} (${le[0]})"
  for tier in daily weekly monthly; do
    tier_files files "${BACKUP_DIR}/${name}/${tier}" "${name}" "${ext}" "${tier}"
    for (( i = ${#files[@]} - 1; i >= 0; i-- )); do
      size=$(stat_size "${files[i]}")
      printf '  %-8s %10s KiB  %s\n' "${tier}" "$(( size / 1024 ))" "${files[i]}"
    done
  done
}

#######################################
# Finds the dump a restore or verify should use.
#
# With nothing named, the newest daily dump. A period stamp finds that period's dump in whichever tier
# holds it, and anything else is taken as a path, which must carry the entry's extension so a dump of
# another engine is never fed to the wrong tool.
# Globals:
#   BACKUP_DIR
# Arguments:
#   entry:  Name of the entry's array.
#   wanted: A period stamp, a path, or empty.
# Outputs:
#   The dump's path.
# Returns:
#   1 when there is no such dump.
#######################################
find_dump() {
  local -n fe="$1"
  local wanted="$2" name="${fe[1]}" ext tier candidate
  local -a files
  ext=$(dump_ext "${fe[0]}")

  if [[ -z "${wanted}" ]]; then
    tier_files files "${BACKUP_DIR}/${name}/daily" "${name}" "${ext}" daily
    if (( ${#files[@]} == 0 )); then
      log_error "${name}: there are no daily dumps in ${BACKUP_DIR}/${name}/daily."
      return 1
    fi
    printf '%s' "${files[-1]}"
    return 0
  fi

  if [[ "${wanted}" =~ ^[0-9]{4}-(W[0-9]{2}|[0-9]{2}(-[0-9]{2})?)$ ]]; then
    for tier in daily weekly monthly; do
      candidate="${BACKUP_DIR}/${name}/${tier}/${name}-${wanted}${ext}"
      if [[ -f "${candidate}" ]]; then
        printf '%s' "${candidate}"
        return 0
      fi
    done
    log_error "${name}: there is no dump for ${wanted}."
    return 1
  fi

  if [[ "${wanted}" != *"${ext}" ]]; then
    log_error "${name}: ${wanted} is not a ${fe[0]} dump; its name must end in ${ext}."
    return 1
  fi
  if [[ ! -f "${wanted}" ]]; then
    log_error "${name}: ${wanted} does not exist."
    return 1
  fi
  printf '%s' "${wanted}"
}

#######################################
# Prints the warning shown before a restore, and asks for confirmation unless --yes was given.
#
# The tool knows nothing about the applications behind a database, so it cannot stop them. A running one
# can write to the database mid-restore, or go on serving data it cached from the old contents, so the
# warning says to stop it, and the default answer is no.
# Globals:
#   _assume_yes, _answer
# Arguments:
#   entry: Name of the entry's array.
#   dump:  The dump about to be restored.
# Outputs:
#   The warning and the prompt on stderr.
# Returns:
#   1 when the restore is not confirmed.
#######################################
confirm_restore() {
  local -n ce="$1"
  local dump="$2" target
  case "${ce[0]}" in
    sqlite) target="the file ${ce[2]} (its -wal and -shm files are deleted)" ;;
    postgres) target="database ${ce[4]} in container ${ce[2]}" ;;
    *) target="database ${ce[3]} in container ${ce[2]}" ;;
  esac
  {
    printf '\n%s\n' "${_C_BOLD}${_C_RED}######################################################################${_C_RESET}"
    printf '%s\n' "${_C_BOLD}${_C_RED}  RESTORE: this replaces ${target}${_C_RESET}"
    printf '%s\n' "${_C_BOLD}${_C_RED}  with ${dump}${_C_RESET}"
    printf '\n%s\n' "${_C_BOLD}  STOP EVERY APPLICATION THAT USES THIS DATABASE FIRST.${_C_RESET}"
    printf '%s\n' "  One that keeps running can write to it mid-restore, or keep serving"
    printf '%s\n' "  data it cached from the old contents. Start it again afterwards."
    printf '%s\n\n' "${_C_BOLD}${_C_RED}######################################################################${_C_RESET}"
  } >&2

  if [[ "${_assume_yes}" == true ]]; then
    return 0
  fi
  printf '%s' "${_C_BOLD}Restore ${ce[1]} now? ${_C_RESET}[y/N] " >&2
  prompt_line
  [[ -t 0 ]] || printf '\n' >&2
  case "${_answer,,}" in
    y | yes) return 0 ;;
  esac
  log_error "${ce[1]}: restore cancelled; nothing was changed."
  return 1
}

#######################################
# Checks a decompressed SQLite copy, gives it the target's owner and mode, and renames it over the target.
#
# The target's -wal and -shm are deleted first: a write-ahead log left from the old database would be
# replayed onto the restored one. Every step returns on failure explicitly, before the target is touched.
# Arguments:
#   target: The database file.
#   tmp:    The decompressed copy, beside the target.
#   errors: Where to write a tool's stderr.
# Returns:
#   1 when any step fails.
#######################################
place_sqlite_copy() {
  local target="$1" tmp="$2" errors="$3" owner mode
  sqlite_check "${tmp}" integrity_check || return 1
  if [[ -e "${target}" ]]; then
    owner=$(stat_owner "${target}") || return 1
    mode=$(stat_mode "${target}") || return 1
    chmod "${mode}" "${tmp}" || return 1
    if [[ "$(stat_owner "${tmp}")" != "${owner}" ]] && ! chown "${owner}" "${tmp}" 2>> "${errors}"; then
      log_error "Cannot give the restored file the owner ${owner} that ${target} has; run as that user or as root."
      return 1
    fi
  fi
  rm -f -- "${target}-wal" "${target}-shm" "${target}-journal" || return 1
  mv -f -- "${tmp}" "${target}" || return 1
}

#######################################
# Replaces a SQLite file with a restored copy.
#
# The copy is decompressed beside the target, so the final rename stays on one filesystem, and placed by
# place_sqlite_copy. It sits in the application's own data directory, so a restore that fails removes it
# at once rather than leaving it for the EXIT trap.
# Globals:
#   _tmp_files
# Arguments:
#   target: The database file.
#   dump:   The gzipped copy.
#   errors: Where to write a tool's stderr.
# Returns:
#   1 when any step fails, before the target is touched.
#######################################
restore_sqlite() {
  local target="$1" dump="$2" errors="$3" tmp status=0
  if [[ ! -d "$(dirname "${target}")" ]]; then
    log_error "The directory of ${target} does not exist."
    return 1
  fi
  tmp=$(mktemp "$(dirname "${target}")/.$(basename "${target}").restore.XXXXXX") || return 1
  _tmp_files+=("${tmp}")
  if gzip -dc "${dump}" > "${tmp}" 2> "${errors}"; then
    place_sqlite_copy "${target}" "${tmp}" "${errors}" || status=1
  else
    status=1
  fi
  if (( status != 0 )); then
    rm -f -- "${tmp}"
  fi
  return "${status}"
}

#######################################
# Restores one entry from a dump.
#
# Postgres restores in a single transaction, so a failure leaves the database as it was. MariaDB and
# MongoDB replace the database as they go. Every step returns on failure explicitly.
# Globals:
#   DOCKER_BIN, MARIADB_CLIENT_SCRIPT, _tmp_files
# Arguments:
#   entry:  Name of the entry's array.
#   wanted: The dump to restore, as find_dump takes it.
# Returns:
#   1 when the restore is refused, cancelled or fails.
#######################################
restore_entry() {
  local -n re="$1"
  local wanted="$2" dump errors status=0
  local name="${re[1]}"
  dump=$(find_dump "$1" "${wanted}") || return 1
  validate_dump "${re[0]}" "${dump}" || { log_error "${name}: not restoring from a dump that fails its check."; return 1; }
  confirm_restore "$1" "${dump}" || return 1

  errors=$(scratch_mktemp "${name}" err) || return 1
  _tmp_files+=("${errors}")
  log_info "${name}: restoring from ${dump}."
  case "${re[0]}" in
    postgres)
      "${DOCKER_BIN}" exec -i "${re[2]}" pg_restore -U "${re[3]}" -d "${re[4]}" --clean --if-exists --single-transaction < "${dump}" 2> "${errors}" || status=$?
      ;;
    mariadb)
      gzip -dc "${dump}" | "${DOCKER_BIN}" exec -i "${re[2]}" sh -c "${MARIADB_CLIENT_SCRIPT}" sh 2> "${errors}" || status=$?
      ;;
    mongodb)
      "${DOCKER_BIN}" exec -i "${re[2]}" mongorestore --quiet --archive --gzip --drop --nsInclude "${re[3]}.*" < "${dump}" 2> "${errors}" || status=$?
      ;;
    sqlite)
      restore_sqlite "${re[2]}" "${dump}" "${errors}" || status=$?
      ;;
  esac

  if (( status != 0 )); then
    log_tool_output "${name}" "${errors}" true
    log_error "${name}: the restore failed."
    return 1
  fi
  log_tool_output "${name}" "${errors}" false
  log_info "${name}: restored from ${dump}. Start the applications that use it again."
}

#######################################
# Runs a command in a throwaway container until it succeeds or VERIFY_TIMEOUT passes.
# Globals:
#   DOCKER_BIN, VERIFY_TIMEOUT, VERIFY_POLL
# Arguments:
#   container: The throwaway container.
#   The command to run in it.
# Returns:
#   1 when the command never succeeded in time.
#######################################
wait_until_ready() {
  local container="$1" waited=0
  shift
  until "${DOCKER_BIN}" exec "${container}" "$@" >/dev/null 2>&1; do
    if (( waited >= VERIFY_TIMEOUT )); then
      log_error "The throwaway server in ${container} was not ready after ${VERIFY_TIMEOUT}s."
      return 1
    fi
    sleep "${VERIFY_POLL}"
    waited=$(( waited + VERIFY_POLL ))
  done
}

#######################################
# Restores a dump into a throwaway container started from the source container's image.
#
# The container has no network and is removed afterwards. The dump counts as restorable when the tool
# succeeds and the restored database holds at least one table or collection. The restore's own stdout is
# discarded, since this function's output is the count. Every step returns on failure explicitly.
# Globals:
#   DOCKER_BIN, MARIADB_CLIENT_SCRIPT, MARIADB_PING_SCRIPT
# Arguments:
#   entry:     Name of the entry's array.
#   dump:      The dump to restore.
#   errors:    Where to write the tools' stderr.
#   throwaway: The name to give the container, which the caller has registered for removal.
# Outputs:
#   The number of tables or collections restored.
# Returns:
#   1 when the throwaway server or the restore fails.
#######################################
verify_in_container() {
  local -n ve="$1"
  local dump="$2" errors="$3" throwaway="$4" image count
  image=$("${DOCKER_BIN}" inspect --format '{{.Config.Image}}' "${ve[2]}" 2>> "${errors}") || return 1

  case "${ve[0]}" in
    postgres)
      "${DOCKER_BIN}" run -d --rm --name "${throwaway}" --network none -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=verify "${image}" >/dev/null 2>> "${errors}" || return 1
      # Over TCP, because the image's initialisation server listens on the socket alone and would answer
      # before the real one has started.
      wait_until_ready "${throwaway}" pg_isready -h 127.0.0.1 -U postgres -q || return 1
      "${DOCKER_BIN}" exec -i "${throwaway}" pg_restore -U postgres -d verify --no-owner --exit-on-error < "${dump}" >/dev/null 2>> "${errors}" || return 1
      count=$("${DOCKER_BIN}" exec "${throwaway}" psql -U postgres -d verify -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema')" 2>> "${errors}") || return 1
      ;;
    mariadb)
      "${DOCKER_BIN}" run -d --rm --name "${throwaway}" --network none -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MYSQL_ALLOW_EMPTY_PASSWORD=yes "${image}" >/dev/null 2>> "${errors}" || return 1
      wait_until_ready "${throwaway}" sh -c "${MARIADB_PING_SCRIPT}" || return 1
      gzip -dc "${dump}" | "${DOCKER_BIN}" exec -i "${throwaway}" sh -c "${MARIADB_CLIENT_SCRIPT}" sh >/dev/null 2>> "${errors}" || return 1
      count=$("${DOCKER_BIN}" exec "${throwaway}" sh -c "${MARIADB_CLIENT_SCRIPT}" sh -N -e "SELECT count(*) FROM information_schema.tables WHERE table_schema = '${ve[3]}'" 2>> "${errors}") || return 1
      ;;
    mongodb)
      "${DOCKER_BIN}" run -d --rm --name "${throwaway}" --network none "${image}" >/dev/null 2>> "${errors}" || return 1
      wait_until_ready "${throwaway}" mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' || return 1
      "${DOCKER_BIN}" exec -i "${throwaway}" mongorestore --quiet --archive --gzip < "${dump}" >/dev/null 2>> "${errors}" || return 1
      count=$("${DOCKER_BIN}" exec "${throwaway}" mongosh --quiet --eval "db.getSiblingDB('${ve[3]}').getCollectionNames().length" 2>> "${errors}") || return 1
      ;;
  esac

  count="${count//[[:space:]]/}"
  if [[ ! "${count}" =~ ^[0-9]+$ ]] || (( count == 0 )); then
    log_error "${ve[1]}: the restored database holds no tables (got '${count}')."
    return 1
  fi
  printf '%s' "${count}"
}

#######################################
# Proves an entry's newest dump restores.
#
# SQLite copies are checked with integrity_check, which reads every page. The server engines restore into
# a throwaway container, which is removed again whatever happens.
# Globals:
#   DOCKER_BIN, _tmp_files, _verify_containers
# Arguments:
#   entry: Name of the entry's array.
# Returns:
#   1 when the dump does not restore.
#######################################
verify_entry() {
  local -n ve2="$1"
  local name="${ve2[1]}" dump errors raw count throwaway
  dump=$(find_dump "$1" "") || return 1
  validate_dump "${ve2[0]}" "${dump}" || return 1

  errors=$(scratch_mktemp "${name}" err) || return 1
  _tmp_files+=("${errors}")

  if [[ "${ve2[0]}" == sqlite ]]; then
    raw=$(scratch_mktemp "${name}" verify) || return 1
    _tmp_files+=("${raw}")
    gzip -dc "${dump}" > "${raw}" || return 1
    sqlite_check "${raw}" integrity_check || return 1
    rm -f -- "${raw}"
    log_info "${name}: ${dump} passes SQLite's integrity check."
    return 0
  fi

  # Registered here rather than inside verify_in_container, which runs in a command substitution whose
  # changes to the array would never reach the EXIT trap.
  throwaway="db-backup-verify-${name}-$$"
  _verify_containers+=("${throwaway}")
  if ! count=$(verify_in_container "$1" "${dump}" "${errors}" "${throwaway}"); then
    log_tool_output "${name}" "${errors}" true
    log_error "${name}: ${dump} did not restore into a throwaway container."
    "${DOCKER_BIN}" rm -f "${throwaway}" >/dev/null 2>&1 || true
    return 1
  fi
  "${DOCKER_BIN}" rm -f "${throwaway}" >/dev/null 2>&1 || true
  log_info "${name}: ${dump} restores, with ${count} tables or collections."
}

#######################################
# Checks that the tools the selected entries need are installed.
# Globals:
#   DOCKER_BIN, SQLITE_BIN
# Arguments:
#   The engines of the selected entries.
# Returns:
#   1 when one is missing.
#######################################
check_tools() {
  local engine need_docker=false need_sqlite=false
  for engine in "$@"; do
    case "${engine}" in
      sqlite) need_sqlite=true ;;
      *) need_docker=true ;;
    esac
  done
  if [[ "${need_docker}" == true ]] && ! command -v "${DOCKER_BIN}" &>/dev/null; then
    log_error "'${DOCKER_BIN}' was not found; Postgres, MariaDB and MongoDB are dumped inside their containers."
    return 1
  fi
  if [[ "${need_sqlite}" == true ]] && ! command -v "${SQLITE_BIN}" &>/dev/null; then
    log_error "'${SQLITE_BIN}' was not found; SQLite files are copied with it."
    return 1
  fi
}

#######################################
# Entry point.
# Globals:
#   All settings, _command, _args, DB_BACKUP_NOW
# Arguments:
#   The command-line arguments.
#######################################
main() {
  parse_options "$@"
  local want_color=true
  if [[ "${_no_color}" == true ]]; then
    want_color=false
    disable_log_colors
  fi
  setup_colors "${want_color}"
  load_config || { log_error "Configuration file not found."; exit 1; }
  validate_config "BACKUP_DIR" "int:KEEP_DAILY" "int:KEEP_WEEKLY" "int:KEEP_MONTHLY" "array:DATABASES" || exit 1

  # Dumps hold the databases' contents, so nothing created here is readable outside the owner's group.
  umask 027
  trap cleanup EXIT

  # Every entry is checked before anything runs, so a typo anywhere fails the run up front.
  local -a entries=() fields
  local entry
  for entry in "${DATABASES[@]}"; do
    parse_entry "${entry}" fields || exit 1
    entries+=("${entry}")
  done

  # The names a command acts on: for restore, the first argument; otherwise every argument, or every
  # entry when none is given.
  local -a wanted=()
  if [[ "${_command}" == restore ]]; then
    wanted=("${_args[0]}")
  else
    wanted=("${_args[@]}")
  fi
  local -a selected=() engines=()
  local name found
  for name in "${wanted[@]}"; do
    found=false
    for entry in "${entries[@]}"; do
      parse_entry "${entry}" fields
      [[ "${fields[1]}" == "${name}" ]] && found=true
    done
    if [[ "${found}" != true ]]; then
      log_error "No DATABASES entry is named '${name}'."
      exit 1
    fi
  done
  for entry in "${entries[@]}"; do
    parse_entry "${entry}" fields
    if (( ${#wanted[@]} > 0 )) && [[ " ${wanted[*]} " != *" ${fields[1]} "* ]]; then
      continue
    fi
    selected+=("${entry}")
    engines+=("${fields[0]}")
  done

  if [[ "${_command}" == list ]]; then
    for entry in "${selected[@]}"; do
      parse_entry "${entry}" fields
      list_entry fields
    done
    return 0
  fi

  check_tools "${engines[@]}" || exit 1

  if [[ "${_command}" == restore ]]; then
    parse_entry "${selected[0]}" fields
    restore_entry fields "${_args[1]:-}" || exit 1
    return 0
  fi

  local now day week month
  now="${DB_BACKUP_NOW:-$(printf '%(%s)T' -1)}"
  printf -v day '%(%F)T' "${now}"
  printf -v week '%(%G-W%V)T' "${now}"
  printf -v month '%(%Y-%m)T' "${now}"

  local -a failed=()
  local done_count=0 ok
  for entry in "${selected[@]}"; do
    parse_entry "${entry}" fields
    ok=true
    if [[ "${_command}" == verify ]]; then
      verify_entry fields || ok=false
    else
      backup_entry fields "${day}" "${week}" "${month}" || ok=false
    fi
    if [[ "${ok}" == true ]]; then
      done_count=$(( done_count + 1 ))
    else
      failed+=("${fields[1]}")
    fi
  done

  local verb="Backed up"
  [[ "${_command}" == verify ]] && verb="Verified"
  if (( ${#failed[@]} > 0 )); then
    log_error "${verb} ${done_count} of $(( done_count + ${#failed[@]} )) database(s); failed: ${failed[*]}."
    exit 1
  fi
  log_info "${verb} ${done_count} database(s)."
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

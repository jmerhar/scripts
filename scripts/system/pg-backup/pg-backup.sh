#!/usr/bin/env bash
#
# Dumps Postgres databases from their Docker containers with pg_dump and keeps a daily, weekly and monthly
# rotation of the dumps.
#
# Each database listed in the configuration is dumped in pg_dump's custom format to
# <BACKUP_DIR>/<name>/daily/<name>-YYYY-MM-DD.dump. The first successful dump of an ISO week is also kept
# as weekly/<name>-YYYY-Www.dump, and the first of a month as monthly/<name>-YYYY-MM.dump; those are hard
# links, so a dump kept in several tiers takes its space once. Each tier is then pruned to its newest
# KEEP_* files.

set -o errexit
set -o nounset
set -o pipefail

# The docker client, and the moment the run treats as now (epoch seconds). Both are read from the
# environment so a test can supply a double and choose the day; unset, they are `docker` and the clock.
: "${DOCKER_BIN:=docker}"
: "${PG_BACKUP_NOW:=}"
readonly DOCKER_BIN PG_BACKUP_NOW

# --- Shared Library ---
# shellcheck source=../../lib/cli.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/cli.sh"
# @include ../../lib/cli.sh
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
# shellcheck source=../../lib/config.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/config.sh"
# @include ../../lib/config.sh

# Retention defaults, which the configuration may override.
KEEP_DAILY=14
KEEP_WEEKLY=4
KEEP_MONTHLY=12

# Names given on the command line, to back up only those entries.
_only=()
# Temporary files of the dump in progress, removed on exit however the run ends.
_tmp_files=()

#######################################
# Prints the usage.
# Globals:
#   SCRIPT_NAME
# Outputs:
#   The usage text on stdout.
#######################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [NAME...]

Dumps the Postgres databases listed in the configuration file from their Docker
containers, and keeps a daily, weekly and monthly rotation of the dumps.

Settings are read from a configuration file (e.g. /etc/${SCRIPT_NAME}.conf). Naming
one or more entries backs up only those.

Options:
  -d, --debug     Enable debug logging
  -h, --help      Show this help message
      --version   Show the version and exit
EOF
}

#######################################
# Parses the command line.
# Globals:
#   _only
# Arguments:
#   The command-line arguments.
#######################################
parse_options() {
  while (( $# > 0 )); do
    case "$1" in
      -d | --debug) enable_debug_mode; shift ;;
      -h | --help)  show_usage; exit 0 ;;
      --version)    show_version; exit 0 ;;
      --)           shift; _only+=("$@"); break ;;
      -*)           die_usage "Unknown option '$1'." ;;
      *)            _only+=("$1"); shift ;;
    esac
  done
}

#######################################
# Removes the temporary files of an interrupted dump.
# Globals:
#   _tmp_files
#######################################
cleanup() {
  local f
  for f in "${_tmp_files[@]}"; do
    rm -f -- "${f}"
  done
}

#######################################
# Splits a DATABASES entry into its four fields.
#
# The name becomes a directory and a file prefix, so it is limited to characters that cannot reach
# outside the backup directory or hide the result.
# Arguments:
#   entry: "NAME CONTAINER USER DATABASE".
#   out:   Name of an array to receive the four fields; it must not be called "parts".
# Returns:
#   1 when the entry does not have exactly four fields, or the name is unusable.
#######################################
parse_entry() {
  local entry="$1"
  local -n out="$2"
  local -a parts
  read -r -a parts <<<"${entry}"
  if (( ${#parts[@]} != 4 )); then
    log_error "DATABASES entry '${entry}' must have four fields: NAME CONTAINER USER DATABASE."
    return 1
  fi
  if [[ ! "${parts[0]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    log_error "DATABASES entry '${entry}': the name may hold only letters, digits and . _ - and may not start with a dot or dash."
    return 1
  fi
  # shellcheck disable=SC2034  # out is a nameref, so this assigns the caller's array
  out=("${parts[@]}")
}

#######################################
# Dumps one database into the day's daily file.
#
# Every step returns on failure explicitly, because the caller runs this as an `if` condition, where
# errexit does not apply.
#
# pg_dump writes to a hidden temporary file beside the target, which replaces the day's file only when
# pg_dump exited 0 and the result starts with the custom format's PGDMP header. A failed dump therefore
# leaves every earlier dump as it was. The replacement is a rename, so a second run on the same day puts
# a new file in place without touching the one a weekly or monthly link still holds.
# Globals:
#   DOCKER_BIN, _tmp_files
# Arguments:
#   name, container, user, database: The entry's fields.
#   file: The daily file to write.
# Returns:
#   1 when pg_dump fails or produces something that is not a custom-format dump.
#######################################
dump_database() {
  local name="$1" container="$2" user="$3" database="$4" file="$5"
  local tmp errors status=0 magic line
  tmp=$(mktemp "$(dirname "${file}")/.${name}.XXXXXX") || return 1
  errors=$(mktemp "$(dirname "${file}")/.${name}.err.XXXXXX") || return 1
  _tmp_files+=("${tmp}" "${errors}")

  log_debug "Running: ${DOCKER_BIN} exec ${container} pg_dump -U ${user} -d ${database} -Fc"
  "${DOCKER_BIN}" exec "${container}" pg_dump -U "${user}" -d "${database}" -Fc > "${tmp}" 2> "${errors}" || status=$?

  # pg_dump's own explanation is what says why a dump failed, so it is logged line by line rather than
  # left on a stderr that only the journal sees.
  while IFS= read -r line; do
    if (( status == 0 )); then
      log_warn "${name}: pg_dump: ${line}"
    else
      log_error "${name}: pg_dump: ${line}"
    fi
  done < "${errors}"

  if (( status != 0 )); then
    log_error "${name}: pg_dump of ${database} in ${container} exited ${status}; earlier dumps kept."
    return 1
  fi

  magic=$(head -c 5 "${tmp}")
  case "${magic}" in
    PGDMP) ;;
    *)
      log_error "${name}: the dump of ${database} is not in pg_dump's custom format; earlier dumps kept."
      return 1
      ;;
  esac

  chmod 0640 "${tmp}" || return 1
  mv -f -- "${tmp}" "${file}" || return 1
  log_info "${name}: dumped ${database} from ${container} to ${file} ($(( $(wc -c < "${file}") / 1024 )) KiB)."
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
# Deletes all but the newest files in a tier.
#
# The names carry their date, and the format sorts in date order, so the oldest are the first in a glob.
# Arguments:
#   dir:     The tier's directory.
#   keep:    How many to keep.
#   pattern: Glob matching the tier's dumps, relative to dir.
# Returns:
#   1 when a file cannot be removed.
#######################################
prune() {
  local dir="$1" keep="$2" pattern="$3"
  local -a files
  local i
  shopt -s nullglob
  # shellcheck disable=SC2206  # the pattern is meant to expand as a glob
  files=("${dir}"/${pattern})
  shopt -u nullglob
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
# Pruning follows a successful dump only, so a database that keeps failing never loses the dumps it
# has. Like dump_database, it returns on each failure explicitly, since it runs as an `if` condition.
# Globals:
#   BACKUP_DIR, KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY
# Arguments:
#   name, container, user, database: The entry's fields.
#   day, week, month: The period stamps of this run.
# Returns:
#   1 when the dump, a link or a prune failed.
#######################################
backup_entry() {
  local name="$1" container="$2" user="$3" database="$4" day="$5" week="$6" month="$7"
  local base="${BACKUP_DIR}/${name}"
  local file="${base}/daily/${name}-${day}.dump"

  mkdir -p "${base}/daily" "${base}/weekly" "${base}/monthly" || return 1
  remove_stale_temps "${base}/daily" "${name}"
  dump_database "${name}" "${container}" "${user}" "${database}" "${file}" || return 1

  promote "${file}" "${base}/weekly/${name}-${week}.dump" weekly || return 1
  promote "${file}" "${base}/monthly/${name}-${month}.dump" monthly || return 1

  prune "${base}/daily" "${KEEP_DAILY}" "${name}-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].dump" || return 1
  prune "${base}/weekly" "${KEEP_WEEKLY}" "${name}-[0-9][0-9][0-9][0-9]-W[0-9][0-9].dump" || return 1
  prune "${base}/monthly" "${KEEP_MONTHLY}" "${name}-[0-9][0-9][0-9][0-9]-[0-9][0-9].dump" || return 1
}

#######################################
# Entry point.
# Globals:
#   All settings, _only, PG_BACKUP_NOW
# Arguments:
#   The command-line arguments.
#######################################
main() {
  parse_options "$@"
  load_config || { log_error "Configuration file not found."; exit 1; }
  validate_config "BACKUP_DIR" "int:KEEP_DAILY" "int:KEEP_WEEKLY" "int:KEEP_MONTHLY" "array:DATABASES" || exit 1

  if ! command -v "${DOCKER_BIN}" &>/dev/null; then
    log_error "'${DOCKER_BIN}' was not found; the databases are dumped inside their containers."
    exit 1
  fi

  # Dumps hold the databases' contents, so nothing created here is readable outside the owner's group.
  umask 027
  trap cleanup EXIT

  local -a entries=() fields
  local entry
  for entry in "${DATABASES[@]}"; do
    parse_entry "${entry}" fields || exit 1
    entries+=("${entry}")
  done

  local wanted found
  for wanted in "${_only[@]}"; do
    found=false
    for entry in "${entries[@]}"; do
      parse_entry "${entry}" fields
      [[ "${fields[0]}" == "${wanted}" ]] && found=true
    done
    if [[ "${found}" != true ]]; then
      log_error "No DATABASES entry is named '${wanted}'."
      exit 1
    fi
  done

  local now day week month
  now="${PG_BACKUP_NOW:-$(printf '%(%s)T' -1)}"
  printf -v day '%(%F)T' "${now}"
  printf -v week '%(%G-W%V)T' "${now}"
  printf -v month '%(%Y-%m)T' "${now}"

  local -a failed=()
  local done_count=0
  for entry in "${entries[@]}"; do
    parse_entry "${entry}" fields
    if (( ${#_only[@]} > 0 )) && [[ " ${_only[*]} " != *" ${fields[0]} "* ]]; then
      continue
    fi
    if backup_entry "${fields[@]}" "${day}" "${week}" "${month}"; then
      done_count=$(( done_count + 1 ))
    else
      failed+=("${fields[0]}")
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    log_error "Backed up ${done_count} of $(( done_count + ${#failed[@]} )) database(s); failed: ${failed[*]}."
    exit 1
  fi
  log_info "Backed up ${done_count} database(s)."
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

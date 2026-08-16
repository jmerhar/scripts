#!/usr/bin/env bash
#
# Aggregates a folder of DMARC RUA (aggregate) reports into one overall report,
# flagging anything potentially problematic.
#
# Mailbox providers e-mail DMARC aggregate reports as compressed XML, named
# "<org>!<domain>!<begin>!<end>.xml.gz" or ".zip". This script reads every such
# report in a directory (recursing is not needed; reports are flat files),
# decompresses and parses each one, and prints:
#
#   * the published policy for every domain, and how it changed over time;
#   * message volume with DMARC pass/fail and the dispositions receivers applied;
#   * a per-domain pass/fail breakdown; and
#   * a "flags" section that surfaces the things worth a human's attention:
#     domains not yet enforcing, sampling (pct<100), senders that authenticated
#     but did not ALIGN (a legit sender needing configuration, or ESP abuse),
#     SPF/DKIM temperror/permerror (DNS/config faults), aligned mail that was
#     nonetheless quarantined/rejected, and the volume/top sources of outright
#     spoofing (unauthenticated forgeries the policy is rejecting), grouped into
#     subnets and annotated with a best-effort country per range.
#
# The distinction the report leans on throughout:
#   - "aligned pass"  = the receiver's policy_evaluated dkim OR spf is "pass"
#                       (this is what DMARC actually enforced on the message).
#   - "authenticated" = some auth_results dkim/spf result is "pass", regardless
#                       of alignment. Authenticated-but-not-aligned is the
#                       interesting middle ground worth reviewing.
#
# Usage:
#   ./dmarc-report.sh [OPTIONS] [DIRECTORY]

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../../lib/colors.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/colors.sh"
# @include ../../lib/colors.sh
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
# shellcheck source=../../lib/program.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/program.sh"
# @include ../../lib/program.sh

# --- Global State (option flags) ---
_no_color=false
_show_all=false          # List every failing source, not just the top offenders.
_target_dir="."

# Fail-rate (percent of messages failing DMARC) at or above which the summary is
# annotated as elevated. Informational only; overridable with --warn-rate.
_warn_rate=40

# Number of top failing source IPs to list unless --all is given.
_top_n=10

# Working files (populated by main): records (one line per record), policy (one
# line per report), and the accumulated human-readable flag lines.
_records_tsv=""
_policy_tsv=""
_flags_file=""
_tmp_dir=""

# Counters for the run itself.
_files_seen=0
_reports_ok=0
_reports_bad=0

# --- Color Variables (set by setup_colors "${_no_color}") ---

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [DIRECTORY]

Aggregate a folder of DMARC RUA reports (.xml.gz, .zip, or .xml) into one
overall report and flag anything potentially problematic.

Options:
  -a, --all             List every failing source range, not just the top ${_top_n}.
  -w, --warn-rate PCT   Annotate the summary when the DMARC fail rate reaches
                        PCT percent (0-100; default ${_warn_rate}). Informational only.
  -C, --no-color        Disable colored output.
  -h, --help            Show this help message.

If no directory is given, the current directory is used. Files are matched by
extension (*.xml.gz, *.gz, *.zip, *.xml); anything that is not a DMARC
aggregate report is skipped with a warning.

Exit status is 0 on a clean run, or 2 when an actionable (policy, alignment, or
config) flag is raised. Spoofing and info flags do not change the exit status.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _show_all, _warn_rate, _no_color, _target_dir
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--all)
        _show_all=true
        shift
        ;;
      -w|--warn-rate)
        if [[ $# -lt 2 ]]; then
          log_error "Option '$1' requires a percentage argument."
          exit 1
        fi
        if [[ ! "$2" =~ ^[0-9]+$ ]] || (( $2 > 100 )); then
          log_error "--warn-rate must be an integer between 0 and 100, got '$2'."
          exit 1
        fi
        _warn_rate="$2"
        shift 2
        ;;
      -C|--no-color)
        _no_color=true
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        log_error "Unknown option '$1'. Use --help for usage."
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#positional[@]} -gt 1 ]]; then
    log_error "Expected at most one directory argument, got ${#positional[@]}."
    exit 1
  fi

  if [[ ${#positional[@]} -eq 1 ]]; then
    _target_dir="${positional[0]}"
  fi

  if [[ ! -d "${_target_dir}" ]]; then
    log_error "'${_target_dir}' is not a directory."
    exit 1
  fi
}

########################################
# Configures color variables based on terminal capability and user preference.
# Globals:
#   _no_color and all _C_* color variables.
# Arguments:
#   None

########################################
# Converts a Unix epoch timestamp to a UTC date, portably across BSD (macOS) and
# GNU (Linux) date implementations.
# Globals:
#   None
# Arguments:
#   epoch:  Seconds since the Unix epoch.
#   format: strftime format string (e.g. '%Y-%m-%d').
# Outputs:
#   The formatted date on stdout (empty string if epoch is empty/zero).
########################################
epoch_to_date() {
  local epoch="$1" format="$2"
  [[ -n "${epoch}" && "${epoch}" != 0 ]] || return 0
  # BSD date first, then GNU; whichever is present answers and the other is not reached.
  if date -u -r "${epoch}" +"${format}" 2>/dev/null; then
    return 0
  fi
  date -u -d "@${epoch}" +"${format}" 2>/dev/null || true
}

########################################
# Joins its stdin lines with ", " onto one line.
# Globals:
#   None
# Outputs:
#   The joined line on stdout.
########################################
join_commas() {
  awk '{printf "%s%s", sep, $0; sep=", "} END {print ""}'
}

########################################
# Joins the output of `uniq -c` into "name (count)" pairs on one line, busiest first.
# Globals:
#   None
# Outputs:
#   The joined line on stdout.
########################################
join_counted() {
  awk '{c = $1; $1 = ""; sub(/^ /, ""); printf "%s%s (%d)", sep, $0, c; sep = ", "} END {print ""}'
}

########################################
# Prints its arguments as one tab-separated line.
# Used for the working TSVs, so the column list is written once per row rather than as a format string
# that has to be kept in step with it.
# Globals:
#   None
# Arguments:
#   The field values, in column order.
# Outputs:
#   One tab-separated line on stdout.
########################################
tsv_line() {
  local IFS=$'\t'
  printf '%s\n' "$*"
}

# Number of auth_results signatures of each type (dkim/spf) captured per record.
# DMARC records virtually never carry more than two of either; three is a safe
# ceiling that keeps the per-record extraction to a single xmllint call.
readonly _AUTH_SLOTS=3

########################################
# Builds the XPath concat() sub-expression that emits _AUTH_SLOTS "domain:result"
# tokens (';'-joined) for one auth_results child type. Missing slots yield an
# empty ":" token, filtered out later.
# Globals:
#   _AUTH_SLOTS
# Arguments:
#   rec:  XPath prefix locating the record (e.g. "(/feedback/record)[1]").
#   kind: "dkim" or "spf".
# Outputs:
#   The concat() argument fragment on stdout.
########################################
auth_concat_expr() {
  local rec="$1" kind="$2" j out=""
  for (( j = 1; j <= _AUTH_SLOTS; j++ )); do
    local node="${rec}/auth_results/${kind}[${j}]"
    out+="normalize-space(${node}/domain),':',normalize-space(${node}/result)"
    (( j < _AUTH_SLOTS )) && out+=",';',"
  done
  printf '%s' "${out}"
}

########################################
# Turns raw ';'-joined "domain:result" tokens (with empty ":" placeholders for
# absent signatures) into a clean list, and reports whether any result passed.
# Globals:
#   None
# Arguments:
#   raw: The ';'-joined token string from the record extraction.
# Outputs:
#   Two lines: the cleaned ';'-joined pairs, then 1/0 for "any pass".
########################################
clean_auth_pairs() {
  local raw="$1" tok out="" any=0
  local IFS=';'
  for tok in ${raw}; do
    [[ "${tok}" == ":" || -z "${tok}" ]] && continue
    out+="${out:+;}${tok}"
    [[ "${tok##*:}" == "pass" ]] && any=1
  done
  printf '%s\n%d\n' "${out}" "${any}"
}

########################################
# Parses one DMARC aggregate-report XML document, appending one line per record
# to the records TSV and one line to the policy TSV. Skips (and counts) documents
# whose root element is not <feedback>. To stay fast on large archives it uses a
# single xmllint invocation for the report metadata (plus record count) and one
# per record, rather than one call per field.
#
# records TSV columns (tab-separated):
#   domain begin org source_ip count disposition pe_dkim pe_spf header_from
#   dkim_pairs spf_pairs aligned_pass auth_any_pass
# where *_pairs are ';'-joined "authdomain:result" tokens, and the two _pass
# columns are 1/0.
#
# policy TSV columns:
#   domain begin p sp pct adkim aspf np org
# Globals:
#   _records_tsv, _policy_tsv, _reports_ok, _reports_bad, _AUTH_SLOTS
# Arguments:
#   file: Path to the (decompressed) XML document.
# Returns:
#   0 if parsed, 1 if skipped as non-DMARC/corrupt.
########################################
parse_xml() {
  local file="$1"

  # One call: root element name, all policy/metadata fields, and record count.
  local meta
  meta=$(xmllint --xpath "concat(
      local-name(/*),'|',
      normalize-space(/feedback/policy_published/domain),'|',
      normalize-space(/feedback/report_metadata/date_range/begin),'|',
      normalize-space(/feedback/report_metadata/org_name),'|',
      normalize-space(/feedback/policy_published/p),'|',
      normalize-space(/feedback/policy_published/sp),'|',
      normalize-space(/feedback/policy_published/pct),'|',
      normalize-space(/feedback/policy_published/adkim),'|',
      normalize-space(/feedback/policy_published/aspf),'|',
      normalize-space(/feedback/policy_published/np),'|',
      count(/feedback/record))" "${file}" 2>/dev/null || true)

  local root domain begin org p sp pct adkim aspf np n
  IFS='|' read -r root domain begin org p sp pct adkim aspf np n <<<"${meta}"

  if [[ "${root}" != "feedback" ]]; then
    _reports_bad=$(( _reports_bad + 1 ))
    return 1
  fi
  n=${n%.*}   # xmllint prints counts as floats.

  # policy TSV: domain begin p sp pct adkim aspf np org
  local -a policy=()
  policy+=("${domain}" "${begin}" "${p:-none}")
  policy+=("${sp:--}" "${pct:-100}" "${adkim:-r}")
  policy+=("${aspf:-r}" "${np:--}" "${org}")
  tsv_line "${policy[@]}" >> "${_policy_tsv}"

  local i
  for (( i = 1; i <= n; i++ )); do
    local rec="(/feedback/record)[${i}]"
    # One call per record: scalars, then up to _AUTH_SLOTS dkim and spf tokens.
    local raw
    raw=$(xmllint --xpath "concat(
        normalize-space(${rec}/row/source_ip),'|',
        normalize-space(${rec}/row/count),'|',
        normalize-space(${rec}/row/policy_evaluated/disposition),'|',
        normalize-space(${rec}/row/policy_evaluated/dkim),'|',
        normalize-space(${rec}/row/policy_evaluated/spf),'|',
        normalize-space(${rec}/identifiers/header_from),'|',
        $(auth_concat_expr "${rec}" dkim),'|',
        $(auth_concat_expr "${rec}" spf))" "${file}" 2>/dev/null || true)

    local src count disp pe_dkim pe_spf hfrom dkim_raw spf_raw
    IFS='|' read -r src count disp pe_dkim pe_spf hfrom dkim_raw spf_raw <<<"${raw}"

    local dkim_pairs dkim_pass spf_pairs spf_pass
    { IFS= read -r dkim_pairs; IFS= read -r dkim_pass; } < <(clean_auth_pairs "${dkim_raw}")
    { IFS= read -r spf_pairs;  IFS= read -r spf_pass;  } < <(clean_auth_pairs "${spf_raw}")

    local auth_any_pass=0
    [[ "${dkim_pass}" == 1 || "${spf_pass}" == 1 ]] && auth_any_pass=1

    local aligned_pass=0
    [[ "${pe_dkim}" == "pass" || "${pe_spf}" == "pass" ]] && aligned_pass=1

    # records TSV: domain begin org src count disp pe_dkim pe_spf hfrom
    #              dkim_pairs spf_pairs aligned_pass auth_any_pass
    local -a record=()
    record+=("${domain}" "${begin}" "${org}")
    record+=("${src}" "${count:-0}" "${disp:-none}")
    record+=("${pe_dkim}" "${pe_spf}" "${hfrom}")
    record+=("${dkim_pairs}" "${spf_pairs}")
    record+=("${aligned_pass}" "${auth_any_pass}")
    tsv_line "${record[@]}" >> "${_records_tsv}"
  done

  _reports_ok=$(( _reports_ok + 1 ))
}

########################################
# Decompresses one report file and feeds each XML document it contains to
# parse_xml. Handles gzip (.gz/.xml.gz), zip (.zip, possibly multi-entry), and
# plain .xml. A .zip is read entry-by-entry so multiple reports in one archive
# are parsed separately rather than concatenated.
# Globals:
#   _tmp_dir, _C_* (for warnings)
# Arguments:
#   src: Path to the compressed report file.
########################################
process_source() {
  local src="$1"
  local work="${_tmp_dir}/doc.xml"
  local entry

  case "${src}" in
    *.gz)
      if gzip -dc -- "${src}" > "${work}" 2>/dev/null; then
        parse_xml "${work}" || log_error "Skipped non-DMARC file: ${src}"
      else
        log_error "Could not decompress: ${src}"
        _reports_bad=$(( _reports_bad + 1 ))
      fi
      ;;
    *.zip)
      while IFS= read -r entry; do
        [[ "${entry}" == *.xml ]] || continue
        if unzip -p -- "${src}" "${entry}" > "${work}" 2>/dev/null; then
          parse_xml "${work}" || log_error "Skipped non-DMARC entry ${entry} in ${src}"
        fi
      done < <(unzip -Z1 -- "${src}" 2>/dev/null || true)
      ;;
    *.xml)
      parse_xml "${src}" || log_error "Skipped non-DMARC file: ${src}"
      ;;
  esac
}

########################################
# Discovers and processes every report file in the target directory.
# Globals:
#   _target_dir, _files_seen
# Arguments:
#   None
########################################
collect_reports() {
  local -a files=()
  local f
  # Null-delimited so filenames with spaces or '!' are safe; the '!' in report
  # names is literal, not history expansion, inside find.
  local -a name_filter=()
  name_filter+=(-name '*.gz' -o)
  name_filter+=(-name '*.zip' -o)
  name_filter+=(-name '*.xml')
  while IFS= read -r -d '' f; do
    files+=("${f}")
  done < <(find "${_target_dir}" -maxdepth 1 -type f \( "${name_filter[@]}" \) -print0 | sort -z)

  _files_seen=${#files[@]}
  if (( _files_seen == 0 )); then
    log_error "No DMARC report files (*.gz, *.zip, *.xml) found in '${_target_dir}'."
    exit 1
  fi

  local i=0
  for f in "${files[@]}"; do
    i=$(( i + 1 ))
    if [[ -t 2 ]]; then
      printf '\r%s' "${_C_DIM}${_C_YELLOW}Parsing report ${i}/${_files_seen}${_C_RESET}" >&2
    fi
    process_source "${f}"
  done
  [[ -t 2 ]] && printf '\r\033[K' >&2 || true
}

########################################
# Prints a section heading.
# Globals:
#   _C_BOLD, _C_BRIGHT_GREEN, _C_RESET
# Arguments:
#   title: The heading text.
########################################
heading() {
  printf '\n%s\n' "${_C_BOLD}${_C_BRIGHT_GREEN}$1${_C_RESET}"
}

########################################
# Prints the run overview: files parsed, reporters, date span, domains.
# Globals:
#   _records_tsv, _policy_tsv, _files_seen, _reports_ok, _reports_bad, colors.
# Arguments:
#   None
########################################
print_overview() {
  local min_begin max_begin
  min_begin=$(cut -f2 "${_policy_tsv}" | sort -n | head -1)
  max_begin=$(cut -f2 "${_policy_tsv}" | sort -n | tail -1)

  local total_msgs
  total_msgs=$(awk -F'\t' '{s += $5} END {print s + 0}' "${_records_tsv}")

  local domains
  domains=$(cut -f1 "${_policy_tsv}" | sort -u | join_commas)

  local n_records reporters from_date to_date
  n_records=$(wc -l < "${_records_tsv}" | tr -d ' ')
  reporters=$(cut -f9 "${_policy_tsv}" | sort | uniq -c | sort -rn | join_counted)
  from_date=$(epoch_to_date "${min_begin}" '%Y-%m-%d')
  to_date=$(epoch_to_date "${max_begin}" '%Y-%m-%d')

  local parsed span
  parsed="Parsed ${_reports_ok} reports from ${_files_seen} files (${_reports_bad} skipped)"
  parsed+=" · ${n_records} records · ${total_msgs} messages"
  span="Span: ${from_date} → ${to_date}"

  heading "DMARC aggregate report — ${_target_dir}"
  printf '  %s%s%s\n' "${_C_CYAN}" "${parsed}" "${_C_RESET}"
  printf '  %s%s%s\n' "${_C_CYAN}" "${span}" "${_C_RESET}"
  printf '  %sReporters: %s%s\n' "${_C_CYAN}" "${reporters}" "${_C_RESET}"
  printf '  %sDomains: %s%s\n' "${_C_CYAN}" "${domains}" "${_C_RESET}"
}

########################################
# Prints the latest published policy for each domain and flags weak posture
# inline (p=none, or pct<100). Appends machine-readable flag lines to the flags
# file for the summary section.
# Globals:
#   _policy_tsv, _flags_file, colors.
# Arguments:
#   None
########################################
print_policies() {
  heading "Published policy (latest per domain)"

  local dom
  while IFS= read -r dom; do
    # Latest report for this domain wins.
    local rows line
    rows=$(awk -F'\t' -v d="${dom}" '$1 == d {print}' "${_policy_tsv}")
    line=$(sort -t$'\t' -k2,2n <<<"${rows}" | tail -1)
    local p sp pct adkim aspf np
    p=$(cut -f3 <<<"${line}"); sp=$(cut -f4 <<<"${line}"); pct=$(cut -f5 <<<"${line}")
    adkim=$(cut -f6 <<<"${line}"); aspf=$(cut -f7 <<<"${line}"); np=$(cut -f8 <<<"${line}")

    # RFC 7489: an absent subdomain policy (sp) defaults to p; an absent
    # non-existent-subdomain policy (np) defaults to sp. Reporters differ in
    # which they echo, so show the effective value rather than a bare "-".
    [[ "${sp}" == "-" ]] && sp="${p}"
    [[ "${np}" == "-" ]] && np="${sp}"

    local status color
    case "${p}" in
      reject)     status="enforcing";        color="${_C_GREEN}" ;;
      quarantine) status="partial";          color="${_C_YELLOW}" ;;
      *)          status="NOT ENFORCING";    color="${_C_RED}" ;;
    esac

    local fields
    fields=$(printf 'p=%-10s sp=%-10s pct=%-3s' "${p}" "${sp}" "${pct}")
    fields+=$(printf ' adkim=%s aspf=%s np=%s' "${adkim}" "${aspf}" "${np}")
    local name_cell status_cell
    name_cell=$(printf '%-24s' "${dom}")
    status_cell="${color}[${status}]${_C_RESET}"
    printf '  %s%s%s %s  %s\n' "${_C_WHITE}" "${name_cell}" "${_C_RESET}" "${fields}" "${status_cell}"

    local flag
    if [[ "${p}" != "reject" && "${p}" != "quarantine" ]]; then
      flag="${dom} is at p=${p} — mail claiming this domain is NOT protected."
      tsv_line policy "${flag}" >> "${_flags_file}"
    elif [[ "${p}" == "quarantine" ]]; then
      flag="${dom} is at p=quarantine — consider moving to p=reject once senders are covered."
      tsv_line policy "${flag}" >> "${_flags_file}"
    fi
    if [[ -n "${pct}" && "${pct}" != 100 ]]; then
      flag="${dom} applies its policy to only pct=${pct}% of mail — the rest is unprotected."
      tsv_line policy "${flag}" >> "${_flags_file}"
    fi
  done < <(cut -f1 "${_policy_tsv}" | sort -u)
}

########################################
# Prints the meaningful policy changes over time for each domain, collapsing the
# (p, sp, adkim, aspf, pct, np) signature so reporter-specific noise in the fo/np
# fields does not read as a real change.
# Globals:
#   _policy_tsv, colors.
# Arguments:
#   None
########################################
print_policy_timeline() {
  heading "Policy changes over time"

  local dom any=false
  while IFS= read -r dom; do
    # Detect changes on the RFC-effective policy (absent sp→p, absent np→sp) so a
    # reporter merely omitting sp/np does not masquerade as a policy change.
    # policy TSV: domain begin p sp pct adkim aspf np org
    local rows out
    rows=$(awk -F'\t' -v d="${dom}" '$1 == d {print}' "${_policy_tsv}" | sort -t$'\t' -k2,2n)
    local prog
    prog=$(load_program policy-changes.awk)  # @embed policy-changes.awk
    out=$(awk -F'\t' "${prog}" <<<"${rows}")
    # Only print domains that actually changed (more than one distinct signature).
    if (( $(wc -l <<<"${out}") > 1 )); then
      any=true
      printf '  %s%s:%s\n' "${_C_WHITE}" "${dom}" "${_C_RESET}"
      local ts rest
      while IFS=$'\t' read -r ts rest; do
        printf '    %s%s%s  %s\n' "${_C_DIM}" "$(epoch_to_date "${ts}" '%Y-%m-%d')" "${_C_RESET}" "${rest}"
      done <<<"${out}"
    fi
  done < <(cut -f1 "${_policy_tsv}" | sort -u)

  if [[ "${any}" == false ]]; then
    printf '  %sNo policy changes observed across the reporting period.%s\n' "${_C_DIM}" "${_C_RESET}"
  fi
}

########################################
# Prints overall DMARC outcome by message volume and the dispositions receivers
# applied, plus a per-domain pass/fail table.
# Globals:
#   _records_tsv, _flags_file, _warn_rate, colors.
# Arguments:
#   None
########################################
print_outcomes() {
  heading "DMARC results (by message volume)"

  # $5 = count, $12 = aligned_pass, $6 = disposition.
  local pass fail
  read -r pass fail <<<"$(awk -F'\t' '
    { if ($12 == 1) p += $5; else f += $5 }
    END { printf "%d %d", p + 0, f + 0 }' "${_records_tsv}")"
  local total=$(( pass + fail )) rate=0
  (( total > 0 )) && rate=$(( fail * 100 / total ))

  local passed failed summary
  passed="${_C_GREEN}Pass (aligned): ${pass}${_C_RESET}"
  failed="${_C_RED}Fail: ${fail}${_C_RESET}"
  summary="${_C_CYAN}(${rate}% fail of ${total} messages)${_C_RESET}"
  printf '  %s   %s   %s\n' "${passed}" "${failed}" "${summary}"

  # DMARC defines exactly three dispositions; print them in a fixed order so the
  # output is deterministic regardless of awk's hash iteration order.
  printf '  %sDispositions applied:%s ' "${_C_CYAN}" "${_C_RESET}"
  local prog
  prog=$(load_program domain-pass-fail.awk)  # @embed domain-pass-fail.awk
  awk -F'\t' "${prog}" "${_records_tsv}"

  if (( rate >= _warn_rate )); then
    local rate_flag
    rate_flag="Overall DMARC fail rate is ${rate}% (>= ${_warn_rate}% threshold);"
    rate_flag+=" see the spoofing breakdown below."
    tsv_line info "${rate_flag}" >> "${_flags_file}"
  fi

  heading "Per-domain breakdown"
  local header
  header=$(printf '%-24s %8s %8s %8s %6s' "domain" "msgs" "pass" "fail" "fail%")
  printf '  %s%s%s\n' "${_C_DIM}" "${header}" "${_C_RESET}"

  local per_domain
  local prog
  prog=$(load_program per-domain-totals.awk)  # @embed per-domain-totals.awk
  per_domain=$(awk -F'\t' "${prog}" "${_records_tsv}")
  local d m p f r
  while IFS=$'\t' read -r d m p f r; do
    [[ -n "${d}" ]] || continue
    printf '  %s%-24s%s %8d %8d %8d %5d%%\n' "${_C_WHITE}" "${d}" "${_C_RESET}" "${m}" "${p}" "${f}" "${r}"
  done < <(sort -t$'\t' -k2,2nr <<<"${per_domain}")
}

########################################
# Builds the flags section: the actionable findings. Reads the records TSV and
# appends human-readable flag lines to the flags file, then the summary is
# rendered by print_flags.
# Globals:
#   _records_tsv, _flags_file, colors.
# Arguments:
#   None
########################################
analyze_flags() {
  # 1) Authenticated but NOT aligned: some auth_results result was "pass" yet the
  #    receiver's aligned evaluation failed. Legit sender needing alignment, or
  #    ESP abuse. High value — list each distinct (domain, passing-auth-domain).
  #    $9=header_from, $10=dkim_pairs, $11=spf_pairs, $12=aligned_pass, $13=auth_any_pass
  local unaligned
  local prog
  prog=$(load_program unaligned-auth.awk)  # @embed unaligned-auth.awk
  unaligned=$(awk -F'\t' "${prog}" "${_records_tsv}")

  local hfrom authdom c unaligned_flag
  while IFS=$'\t' read -r hfrom authdom c; do
    [[ -n "${authdom}" ]] || continue
    unaligned_flag="${c} msg for ${hfrom:-<none>} authenticated on ${authdom} but did NOT align"
    unaligned_flag+=" — legit sender to configure, or ESP abuse."
    tsv_line align "${unaligned_flag}" >> "${_flags_file}"
  done < <(sort -t$'\t' -k3,3nr <<<"${unaligned}")

  # 2) SPF/DKIM temperror/permerror anywhere in auth_results → DNS/config faults.
  local err_msgs
  err_msgs=$(awk -F'\t' '
    { if ($10 ~ /:(temperror|permerror)/ || $11 ~ /:(temperror|permerror)/) e += $5 }
    END { print e + 0 }' "${_records_tsv}")
  if (( err_msgs > 0 )); then
    local err_flag
    err_flag="${err_msgs} msg saw an SPF/DKIM temperror or permerror"
    err_flag+=" — check DNS records and DKIM key publication."
    tsv_line config "${err_flag}" >> "${_flags_file}"
  fi

  # 3) Aligned mail that was still quarantined/rejected — should not happen; a
  #    sign of policy_evaluated overrides or misconfiguration worth a look.
  local bad_disp
  bad_disp=$(awk -F'\t' '$12 == 1 && $6 != "none" {b += $5} END {print b + 0}' "${_records_tsv}")
  if (( bad_disp > 0 )); then
    local disp_flag
    disp_flag="${bad_disp} msg passed DMARC alignment yet were quarantined/rejected"
    disp_flag+=" — review those receivers."
    tsv_line align "${disp_flag}" >> "${_flags_file}"
  fi

  # 4) Outright spoofing: failed AND had no passing authentication at all. This is
  #    forgery the policy is catching; informational, with top source IPs.
  local spoof_msgs
  spoof_msgs=$(awk -F'\t' '$12 == 0 && $13 == 0 {s += $5} END {print s + 0}' "${_records_tsv}")
  if (( spoof_msgs > 0 )); then
    local spoof_flag
    spoof_flag="${spoof_msgs} msg failed with NO valid authentication (spoofing/forgery)."
    spoof_flag+=" If your policy is at reject/quarantine these are being blocked."
    tsv_line spoof "${spoof_flag}" >> "${_flags_file}"
  fi
}

########################################
# Best-effort reverse-geolocation of IPv4/IPv6 addresses to country names via the
# free ip-api.com batch endpoint. Requires curl and jq; if either is missing, the
# network is unavailable, or the service errors, it simply returns nothing so the
# caller can render ranges without a country. Addresses are queried in batches of
# 100 (the endpoint's per-request limit).
# Globals:
#   None
# Arguments:
#   One or more IP addresses.
# Outputs:
#   "ip<TAB>country" lines for the addresses it could resolve (order not
#   guaranteed; unresolved addresses are simply omitted).
########################################
geolocate_ips() {
  command -v curl &>/dev/null && command -v jq &>/dev/null || return 0
  (( $# > 0 )) || return 0

  local -a ips=("$@")
  local total=${#ips[@]} start=0
  while (( start < total )); do
    local -a chunk=("${ips[@]:start:100}")
    start=$(( start + 100 ))

    local request response
    local ip_lines
    ip_lines=$(printf '%s\n' "${chunk[@]}")
    request=$(jq -R -s -c 'split("\n") | map(select(length > 0))' <<<"${ip_lines}" 2>/dev/null || true)
    [[ -n "${request}" ]] || continue

    # ip-api.com's free tier is HTTP-only; the payload is just IPs → country.
    local -a curl_args=(-fsS --max-time 15)
    curl_args+=(-H 'Content-Type: application/json')
    curl_args+=(-d "${request}")
    curl_args+=('http://ip-api.com/batch?fields=status,country,query')
    response=$(curl "${curl_args[@]}" 2>/dev/null || true)
    [[ -n "${response}" ]] || continue

    local filter='.[] | select(.status == "success" and .country != "") | "\(.query)\t\(.country)"'
    jq -r "${filter}" <<<"${response}" 2>/dev/null || true
  done
}

########################################
# Renders the flags section from the accumulated flag lines, grouped by
# category, and prints the top failing source ranges with their country.
# Globals:
#   _flags_file, _records_tsv, _show_all, _top_n, colors.
# Arguments:
#   None
# Returns:
#   0 if no actionable (policy/align/config) flags were raised, 1 otherwise.
#   Spoofing and info flags are reported but do not affect the return code, since
#   inbound forgery against an enforcing policy is expected and already blocked.
########################################
print_flags() {
  heading "Flags"

  if [[ ! -s "${_flags_file}" ]]; then
    local clean="Nothing flagged — every domain is enforcing and all mail aligns cleanly."
    printf '  %s%s%s\n' "${_C_BRIGHT_GREEN}" "${clean}" "${_C_RESET}"
  else
    # Order categories by severity; label and color each.
    local cat label color
    for cat in policy align config spoof info; do
      case "${cat}" in
        policy) label="POLICY";     color="${_C_RED}" ;;
        align)  label="ALIGNMENT";  color="${_C_MAGENTA}" ;;
        config) label="CONFIG";     color="${_C_RED}" ;;
        spoof)  label="SPOOFING";   color="${_C_YELLOW}" ;;
        info)   label="INFO";       color="${_C_CYAN}" ;;
      esac
      local msg
      while IFS=$'\t' read -r _ msg; do
        printf '  %s[%s]%s %s\n' "${color}" "${label}" "${_C_RESET}" "${msg}"
      done < <(awk -F'\t' -v c="${cat}" '$1 == c' "${_flags_file}")
    done
  fi

  # Failing source ranges (spoofing pressure / offenders), grouped into subnets
  # (/24 for IPv4, /64 for IPv6) so a provider's block reads as one line, each
  # annotated with a best-effort country for its busiest address.
  local n_fail
  n_fail=$(awk -F'\t' '$12 == 0' "${_records_tsv}" | wc -l | tr -d ' ')
  if (( n_fail > 0 )); then
    local limit_label="top ${_top_n}"
    [[ "${_show_all}" == true ]] && limit_label="all"
    heading "Failing source ranges (${limit_label})"

    # msgs <tab> subnet <tab> representative-ip (the busiest IP in the subnet),
    # sorted by message volume. The representative is a real, routable address so
    # geolocation is accurate rather than querying a synthetic network address.
    local grouped
    local prog
    prog=$(load_program failing-subnets.awk)  # @embed failing-subnets.awk
    grouped=$(awk -F'\t' "${prog}" "${_records_tsv}")
    grouped=$(sort -t$'\t' -k1,1nr <<<"${grouped}")
    [[ "${_show_all}" != true ]] && grouped=$(head -n "${_top_n}" <<<"${grouped}")

    # Collect the representative IPs and resolve them to countries in one batch.
    local -a reps=()
    local msgs subnet rep
    while IFS=$'\t' read -r msgs subnet rep; do
      [[ -n "${rep}" ]] && reps+=("${rep}")
    done <<<"${grouped}"

    local -A country=()
    if (( ${#reps[@]} > 0 )); then
      local ip name
      while IFS=$'\t' read -r ip name; do
        [[ -n "${ip}" ]] && country["${ip}"]="${name}"
      done < <(geolocate_ips "${reps[@]}")
    fi

    printf '  %s%8s  %-20s %s%s\n' "${_C_DIM}" "messages" "range" "country" "${_C_RESET}"
    while IFS=$'\t' read -r msgs subnet rep; do
      [[ -n "${subnet}" ]] || continue
      local msgs_cell range_cell
      msgs_cell=$(printf '%8d' "${msgs}")
      range_cell=$(printf '%-20s %s' "${subnet}" "${country["${rep}"]:-unknown}")
      printf '  %s%s%s  %s\n' "${_C_YELLOW}" "${msgs_cell}" "${_C_RESET}" "${range_cell}"
    done <<<"${grouped}"

    if (( ${#reps[@]} > 0 && ${#country[@]} == 0 )); then
      local unavailable="Country lookup unavailable (offline, or curl/jq missing)."
      printf '  %s%s%s\n' "${_C_DIM}" "${unavailable}" "${_C_RESET}"
    fi
  fi

  # Only actionable categories drive a nonzero exit.
  if awk -F'\t' '$1 == "policy" || $1 == "align" || $1 == "config" {found = 1}
     END {exit !found}' "${_flags_file}"; then
    return 1
  fi
  return 0
}

########################################
# Main entry point.
# Globals:
#   Many; see individual functions.
# Arguments:
#   Command-line arguments.
########################################
main() {
  parse_options "$@"
  setup_colors "${_no_color}"

  if ! command -v xmllint &>/dev/null; then
    log_error "xmllint is required (install libxml2 on Homebrew, or libxml2-utils on Debian)."
    exit 1
  fi
  if ! command -v unzip &>/dev/null; then
    log_error "unzip is required to read .zip reports."
    exit 1
  fi

  _tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dmarc-report.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '${_tmp_dir}'" EXIT
  _records_tsv="${_tmp_dir}/records.tsv"
  _policy_tsv="${_tmp_dir}/policy.tsv"
  _flags_file="${_tmp_dir}/flags.tsv"
  : > "${_records_tsv}"
  : > "${_policy_tsv}"
  : > "${_flags_file}"

  collect_reports

  if (( _reports_ok == 0 )); then
    log_error "No valid DMARC reports could be parsed from '${_target_dir}'."
    exit 1
  fi

  print_overview
  print_policies
  print_policy_timeline
  print_outcomes
  analyze_flags

  local raised=0
  print_flags || raised=1

  printf '\n'
  if (( raised == 1 )); then
    exit 2
  fi
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

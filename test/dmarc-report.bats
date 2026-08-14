#!/usr/bin/env bats
#
# dmarc-report reads compressed XML from mailbox providers and turns it into a verdict a human acts on,
# so the failures that matter are interpretive: calling an enforcing domain unprotected, missing a
# sender that authenticated without aligning, or counting spoofing as legitimate mail. The distinction
# the whole report rests on — "aligned pass" (what DMARC enforced) versus "authenticated" (some
# auth_results pass, aligned or not) — is asserted directly.
#
# Two boundaries, two approaches. The parsing path runs against real fixture reports through the real
# xmllint, gzip and unzip, because a stub would only prove the stub works. The reporting path is driven
# from the internal TSVs, which is what the parsers produce and every print function consumes; building
# them directly keeps each assertion about one decision rather than about an entire pipeline. Only curl
# is stubbed, for the country lookup.

load test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/utility/dmarc-report.sh"
  REPORTS="$BATS_TEST_TMPDIR/reports"
  mkdir -p "$REPORTS"

  POLICY="$BATS_TEST_TMPDIR/policy.tsv"
  RECORDS="$BATS_TEST_TMPDIR/records.tsv"
  FLAGS="$BATS_TEST_TMPDIR/flags.tsv"
  : > "$POLICY"; : > "$RECORDS"; : > "$FLAGS"
}

########################################
# Writes a DMARC aggregate report.
# Arguments:
#   path: Where to write it.
#   domain, p, org, begin: policy_published/metadata values; pass "" for a default.
#   Remaining arguments are <record> blocks, already formed.
########################################
report_xml() {
  local path="$1" domain="${2:-example.com}" p="${3:-none}" org="${4:-google.com}" begin="${5:-1700000000}"
  # Only the leading five are consumed here; shifting past the end would fail, and a report with no
  # records is a case worth writing.
  if (( $# > 5 )); then shift 5; else shift $#; fi
  {
    printf '<?xml version="1.0" encoding="UTF-8" ?>\n<feedback>\n'
    printf '  <report_metadata><org_name>%s</org_name>\n' "$org"
    printf '    <date_range><begin>%s</begin><end>%s</end></date_range></report_metadata>\n' \
      "$begin" "$(( begin + 86400 ))"
    printf '  <policy_published><domain>%s</domain><p>%s</p><pct>100</pct>' "$domain" "$p"
    printf '<adkim>r</adkim><aspf>r</aspf></policy_published>\n'
    (( $# > 0 )) && printf '%s\n' "$@"
    printf '</feedback>\n'
  } > "$path"
}

########################################
# Forms one <record> block.
# Arguments:
#   ip, count, disposition, pe_dkim, pe_spf, header_from, auth_dkim, auth_spf
#   where auth_* are "domain:result" or "" for absent.
########################################
record_xml() {
  local ip="$1" count="$2" disp="$3" pe_dkim="$4" pe_spf="$5" hfrom="$6" adkim="${7:-}" aspf="${8:-}"
  printf '  <record><row><source_ip>%s</source_ip><count>%s</count>' "$ip" "$count"
  printf '<policy_evaluated><disposition>%s</disposition>' "$disp"
  printf '<dkim>%s</dkim><spf>%s</spf></policy_evaluated></row>' "$pe_dkim" "$pe_spf"
  printf '<identifiers><header_from>%s</header_from></identifiers><auth_results>' "$hfrom"
  [[ -n "$adkim" ]] && printf '<dkim><domain>%s</domain><result>%s</result></dkim>' \
    "${adkim%%:*}" "${adkim##*:}"
  [[ -n "$aspf" ]] && printf '<spf><domain>%s</domain><result>%s</result></spf>' \
    "${aspf%%:*}" "${aspf##*:}"
  printf '</auth_results></record>'
}

########################################
# Appends a row to the policy TSV: domain begin p sp pct adkim aspf np org.
########################################
policy_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${1:-example.com}" "${2:-1700000000}" "${3:-none}" "${4:--}" "${5:-100}" \
    "${6:-r}" "${7:-r}" "${8:--}" "${9:-google.com}" >> "$POLICY"
}

########################################
# Appends a row to the records TSV:
# domain begin org src count disp pe_dkim pe_spf hfrom dkim_pairs spf_pairs aligned auth_any.
########################################
record_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${1:-example.com}" "${2:-1700000000}" "${3:-google.com}" "${4:-198.51.100.1}" "${5:-10}" \
    "${6:-none}" "${7:-pass}" "${8:-pass}" "${9:-example.com}" \
    "${10:-}" "${11:-}" "${12:-1}" "${13:-1}" >> "$RECORDS"
}

########################################
# Evaluates a snippet with the report globals pointed at this test's files.
########################################
with_tsv() {
  run_snippet "$SCRIPT" "
    _policy_tsv='$POLICY'; _records_tsv='$RECORDS'; _flags_file='$FLAGS'
    _tmp_dir='$BATS_TEST_TMPDIR'; _target_dir='$REPORTS'
    $1"
}

########################################
# Runs the script over the fixture directory.
########################################
report() {
  run_script "$SCRIPT" -C "$@" "$REPORTS"
}

# --- Parsing a report --------------------------------------------------------------------------

# Each option that takes a value checks for one; without that the next option would be swallowed as the
# value and the run would proceed on a silently wrong threshold.
# Invoked without the `report` helper on purpose: that helper appends the reports directory, which would
# supply the very argument this test is checking for the absence of.
@test "--warn-rate requires an argument" {
  run_script "$SCRIPT" -C --warn-rate
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a percentage argument"* ]]
}

@test "--warn-rate refuses a value that is not a percentage" {
  report --warn-rate 101
  [ "$status" -eq 1 ]
  [[ "$output" == *"between 0 and 100"* ]]
  report --warn-rate abc
  [ "$status" -eq 1 ]
}

@test "a valid report yields one policy row and one record row per record" {
  report_xml "$REPORTS/r.xml" example.com reject google.com 1700000000 \
    "$(record_xml 198.51.100.1 5 none pass pass example.com example.com:pass)" \
    "$(record_xml 198.51.100.2 3 reject fail fail example.com)"
  with_tsv "parse_xml '$REPORTS/r.xml'; echo \"ok=\${_reports_ok} bad=\${_reports_bad}\"
            echo \"policy=\$(wc -l < '$POLICY' | tr -d ' ')\"
            echo \"records=\$(wc -l < '$RECORDS' | tr -d ' ')\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok=1 bad=0"* ]]
  [[ "$output" == *"policy=1"* ]]
  [[ "$output" == *"records=2"* ]]
}

@test "the policy row carries the published policy" {
  report_xml "$REPORTS/r.xml" mydomain.test quarantine yahoo.com 1699999999
  with_tsv "parse_xml '$REPORTS/r.xml'; cut -f1,2,3,9 '$POLICY'"
  [ "$output" = "mydomain.test	1699999999	quarantine	yahoo.com" ]
}

# Written out longhand rather than through report_xml, because the point is the elements being *absent*
# and that helper always emits pct.
@test "absent sp, np and pct fall back to documented defaults" {
  cat > "$REPORTS/r.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" ?>
<feedback>
  <report_metadata><org_name>google.com</org_name>
    <date_range><begin>1700000000</begin><end>1700086400</end></date_range></report_metadata>
  <policy_published><domain>example.com</domain><p>reject</p></policy_published>
</feedback>
XML
  with_tsv "parse_xml '$REPORTS/r.xml'; cut -f4,5,6,7,8 '$POLICY'"
  # sp and np are recorded as "-" so the report can apply the RFC fallbacks itself; pct defaults to 100
  # and the alignment modes to relaxed, which is what DMARC specifies when they are omitted.
  [ "$output" = "-	100	r	r	-" ]
}

@test "a published pct is carried through rather than defaulted" {
  report_xml "$REPORTS/r.xml" example.com reject
  with_tsv "parse_xml '$REPORTS/r.xml'; cut -f5 '$POLICY'"
  [ "$output" = "100" ]

  cat > "$REPORTS/s.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" ?>
<feedback>
  <report_metadata><org_name>google.com</org_name>
    <date_range><begin>1700000000</begin><end>1700086400</end></date_range></report_metadata>
  <policy_published><domain>example.com</domain><p>reject</p><pct>25</pct></policy_published>
</feedback>
XML
  : > "$POLICY"
  with_tsv "parse_xml '$REPORTS/s.xml'; cut -f5 '$POLICY'"
  [ "$output" = "25" ]
}

@test "a file whose root element is not feedback is rejected and counted as bad" {
  printf '<?xml version="1.0"?>\n<notdmarc><a/></notdmarc>\n' > "$REPORTS/other.xml"
  with_tsv "parse_xml '$REPORTS/other.xml' || echo refused; echo \"bad=\${_reports_bad}\""
  [[ "$output" == *"refused"* ]]
  [[ "$output" == *"bad=1"* ]]
}

@test "a record's source, count and disposition are recorded" {
  report_xml "$REPORTS/r.xml" example.com reject google.com 1700000000 \
    "$(record_xml 203.0.113.9 42 quarantine fail pass example.com)"
  with_tsv "parse_xml '$REPORTS/r.xml'; cut -f4,5,6 '$RECORDS'"
  [ "$output" = "203.0.113.9	42	quarantine" ]
}

# The distinction the whole report is built on: policy_evaluated is what DMARC enforced, auth_results is
# what merely authenticated. A record can authenticate and still fail alignment.
@test "aligned pass is taken from policy_evaluated, not from auth_results" {
  report_xml "$REPORTS/r.xml" example.com reject google.com 1700000000 \
    "$(record_xml 198.51.100.1 1 none fail fail example.com esp.example:pass)"
  with_tsv "parse_xml '$REPORTS/r.xml'; cut -f12,13 '$RECORDS'"
  # aligned=0 because policy_evaluated failed; authenticated=1 because auth_results passed.
  [ "$output" = "0	1" ]
}

@test "a record aligned on either dkim or spf counts as an aligned pass" {
  report_xml "$REPORTS/r.xml" example.com reject google.com 1700000000 \
    "$(record_xml 198.51.100.1 1 none fail pass example.com)"
  with_tsv "parse_xml '$REPORTS/r.xml'; cut -f12 '$RECORDS'"
  [ "$output" = "1" ]
}

@test "a record with no passing authentication is neither aligned nor authenticated" {
  report_xml "$REPORTS/r.xml" example.com reject google.com 1700000000 \
    "$(record_xml 198.51.100.1 1 reject fail fail example.com spoofer.test:fail)"
  with_tsv "parse_xml '$REPORTS/r.xml'; cut -f12,13 '$RECORDS'"
  [ "$output" = "0	0" ]
}

@test "auth_results domain:result pairs are recorded for dkim and spf" {
  report_xml "$REPORTS/r.xml" example.com reject google.com 1700000000 \
    "$(record_xml 198.51.100.1 1 none pass pass example.com d.example:pass s.example:softfail)"
  with_tsv "parse_xml '$REPORTS/r.xml'; cut -f10,11 '$RECORDS'"
  [ "$output" = "d.example:pass	s.example:softfail" ]
}

@test "a report with no records still yields its policy" {
  report_xml "$REPORTS/r.xml" example.com reject
  with_tsv "parse_xml '$REPORTS/r.xml'
            echo \"policy=\$(wc -l < '$POLICY' | tr -d ' ') records=\$(wc -l < '$RECORDS' | tr -d ' ')\""
  [[ "$output" == *"policy=1 records=0"* ]]
}

# --- Decompression -----------------------------------------------------------------------------

@test "a gzipped report is decompressed and parsed" {
  report_xml "$BATS_TEST_TMPDIR/r.xml" gz.example reject
  gzip -c "$BATS_TEST_TMPDIR/r.xml" > "$REPORTS/r.xml.gz"
  with_tsv "process_source '$REPORTS/r.xml.gz'; cut -f1 '$POLICY'"
  [ "$output" = "gz.example" ]
}

@test "a zipped report is extracted and parsed" {
  report_xml "$BATS_TEST_TMPDIR/r.xml" zip.example reject
  ( cd "$BATS_TEST_TMPDIR" && zip -q "$REPORTS/r.zip" r.xml )
  with_tsv "process_source '$REPORTS/r.zip'; cut -f1 '$POLICY'"
  [ "$output" = "zip.example" ]
}

# Providers occasionally batch several reports into one archive; concatenating them would produce one
# malformed document instead of several valid ones.
@test "every XML entry in a multi-entry zip is parsed separately" {
  report_xml "$BATS_TEST_TMPDIR/one.xml" first.example reject
  report_xml "$BATS_TEST_TMPDIR/two.xml" second.example reject
  ( cd "$BATS_TEST_TMPDIR" && zip -q "$REPORTS/both.zip" one.xml two.xml )
  with_tsv "process_source '$REPORTS/both.zip'; cut -f1 '$POLICY' | sort"
  [ "${lines[0]}" = "first.example" ]
  [ "${lines[1]}" = "second.example" ]
}

@test "a corrupt gzip is reported and counted, not silently skipped" {
  printf 'this is not gzip' > "$REPORTS/broken.xml.gz"
  with_tsv "process_source '$REPORTS/broken.xml.gz' 2>&1; echo \"bad=\${_reports_bad}\""
  [[ "$output" == *"Could not decompress"* ]]
  [[ "$output" == *"bad=1"* ]]
}

@test "a non-DMARC XML inside an archive is reported rather than counted as data" {
  printf '<other/>\n' > "$BATS_TEST_TMPDIR/x.xml"
  gzip -c "$BATS_TEST_TMPDIR/x.xml" > "$REPORTS/x.xml.gz"
  with_tsv "process_source '$REPORTS/x.xml.gz' 2>&1"
  [[ "$output" == *"Skipped non-DMARC file"* ]]
}

# --- Discovery ---------------------------------------------------------------------------------

@test "a directory with no report files is an error" {
  report
  [ "$status" -eq 1 ]
  [[ "$output" == *"No DMARC report files"* ]]
}

@test "gz, zip and xml reports are all discovered" {
  report_xml "$REPORTS/plain.xml" a.example reject
  report_xml "$BATS_TEST_TMPDIR/g.xml" b.example reject
  gzip -c "$BATS_TEST_TMPDIR/g.xml" > "$REPORTS/g.xml.gz"
  report_xml "$BATS_TEST_TMPDIR/z.xml" c.example reject
  ( cd "$BATS_TEST_TMPDIR" && zip -q "$REPORTS/z.zip" z.xml )
  with_tsv "collect_reports >/dev/null 2>&1; echo \"seen=\${_files_seen} ok=\${_reports_ok}\""
  [[ "$output" == *"seen=3 ok=3"* ]]
}

@test "files that are not reports are left out of the count" {
  report_xml "$REPORTS/r.xml" a.example reject
  printf 'notes' > "$REPORTS/README.txt"
  with_tsv "collect_reports >/dev/null 2>&1; echo \"seen=\${_files_seen}\""
  [[ "$output" == *"seen=1"* ]]
}

# --- The overview and policy sections ----------------------------------------------------------

@test "the overview counts reports, files, records and messages" {
  policy_row example.com 1700000000 reject
  record_row example.com 1700000000 google.com 198.51.100.1 40
  record_row example.com 1700000000 google.com 198.51.100.2 2
  with_tsv '_reports_ok=1 _files_seen=2 _reports_bad=1; print_overview'
  [[ "$output" == *"Parsed 1 reports from 2 files (1 skipped)"* ]]
  [[ "$output" == *"2 records"* ]]
  [[ "$output" == *"42 messages"* ]]
}

@test "the overview lists the reporters with their report counts" {
  policy_row example.com 1700000000 reject - 100 r r - google.com
  policy_row example.com 1700100000 reject - 100 r r - google.com
  policy_row example.com 1700200000 reject - 100 r r - yahoo.com
  with_tsv 'print_overview'
  [[ "$output" == *"google.com (2)"* ]]
  [[ "$output" == *"yahoo.com (1)"* ]]
}

@test "the overview spans the earliest and latest report dates" {
  policy_row example.com 1700000000 reject
  policy_row example.com 1600000000 reject
  with_tsv 'print_overview'
  [[ "$output" == *"2020-09-13"* ]]
  [[ "$output" == *"2023-11-14"* ]]
}

@test "an enforcing domain is shown as enforcing and raises no policy flag" {
  policy_row secure.example 1700000000 reject
  with_tsv 'print_policies'
  [[ "$output" == *"secure.example"* ]]
  [[ "$output" == *"[enforcing]"* ]]
  [ ! -s "$FLAGS" ]
}

@test "p=none is called out as not enforcing, and flagged" {
  policy_row weak.example 1700000000 none
  with_tsv 'print_policies'
  [[ "$output" == *"NOT ENFORCING"* ]]
  run cat "$FLAGS"
  [[ "$output" == *"policy"*"weak.example is at p=none"* ]]
}

@test "p=quarantine is called partial, and flagged as a step short of reject" {
  policy_row partial.example 1700000000 quarantine
  with_tsv 'print_policies'
  [[ "$output" == *"[partial]"* ]]
  run cat "$FLAGS"
  [[ "$output" == *"consider moving to p=reject"* ]]
}

@test "sampling below 100 percent is flagged" {
  policy_row sampled.example 1700000000 reject - 20
  with_tsv 'print_policies'
  run cat "$FLAGS"
  [[ "$output" == *"only pct=20%"* ]]
}

# RFC 7489: an absent sp defaults to p, and an absent np to sp. Reporters differ in which they echo, so
# showing a bare "-" would read as "no policy" when the effective policy is inherited.
@test "an absent subdomain policy is shown as the inherited value, not a dash" {
  policy_row inherit.example 1700000000 reject - 100 r r -
  with_tsv 'print_policies'
  [[ "$output" == *"sp=reject"* ]]
  [[ "$output" == *"np=reject"* ]]
}

@test "the latest report wins when a domain's policy changed" {
  policy_row moving.example 1700000000 none
  policy_row moving.example 1700900000 reject
  with_tsv 'print_policies'
  [[ "$output" == *"p=reject"* ]]
  [[ "$output" != *"NOT ENFORCING"* ]]
}

@test "a policy change over time is listed with its dates" {
  policy_row moving.example 1700000000 none
  policy_row moving.example 1700900000 reject
  with_tsv 'print_policy_timeline'
  [[ "$output" == *"moving.example"* ]]
  [[ "$output" == *"p=none"* ]]
  [[ "$output" == *"p=reject"* ]]
}

@test "a steady policy is reported as unchanged" {
  policy_row steady.example 1700000000 reject
  policy_row steady.example 1700900000 reject
  with_tsv 'print_policy_timeline'
  [[ "$output" == *"No policy changes observed"* ]]
}

# A reporter that merely omits sp or np must not read as a policy change, which is why the timeline
# compares the RFC-effective signature rather than the raw fields.
@test "a reporter omitting sp does not masquerade as a policy change" {
  policy_row same.example 1700000000 reject reject
  policy_row same.example 1700900000 reject -
  with_tsv 'print_policy_timeline'
  [[ "$output" == *"No policy changes observed"* ]]
}

# --- Outcomes ----------------------------------------------------------------------------------

@test "messages are split into aligned passes and failures by volume" {
  record_row example.com 1700000000 google.com 198.51.100.1 70 none pass pass example.com "" "" 1 1
  record_row example.com 1700000000 google.com 198.51.100.2 30 reject fail fail example.com "" "" 0 0
  with_tsv 'print_outcomes'
  [[ "$output" == *"Pass (aligned): 70"* ]]
  [[ "$output" == *"Fail: 30"* ]]
  [[ "$output" == *"30% fail of 100 messages"* ]]
}

@test "dispositions are listed in a fixed order regardless of input order" {
  record_row example.com 1700000000 google.com 198.51.100.1 5 reject fail fail example.com "" "" 0 0
  record_row example.com 1700000000 google.com 198.51.100.2 7 none pass pass example.com "" "" 1 1
  record_row example.com 1700000000 google.com 198.51.100.3 3 quarantine fail fail example.com "" "" 0 0
  with_tsv 'print_outcomes'
  [[ "$output" == *"none=7, quarantine=3, reject=5"* ]]
}

@test "a fail rate at or above the threshold is flagged" {
  record_row example.com 1700000000 google.com 198.51.100.1 60 reject fail fail example.com "" "" 0 0
  record_row example.com 1700000000 google.com 198.51.100.2 40 none pass pass example.com "" "" 1 1
  with_tsv '_warn_rate=40; print_outcomes'
  run cat "$FLAGS"
  [[ "$output" == *"info"*"fail rate is 60%"* ]]
}

@test "a fail rate below the threshold is not flagged" {
  record_row example.com 1700000000 google.com 198.51.100.1 10 reject fail fail example.com "" "" 0 0
  record_row example.com 1700000000 google.com 198.51.100.2 90 none pass pass example.com "" "" 1 1
  with_tsv '_warn_rate=40; print_outcomes'
  [ ! -s "$FLAGS" ]
}

@test "the per-domain table totals each domain separately, busiest first" {
  record_row small.example 1700000000 google.com 198.51.100.1 5 none pass pass small.example "" "" 1 1
  record_row big.example 1700000000 google.com 198.51.100.2 50 none pass pass big.example "" "" 1 1
  record_row big.example 1700000000 google.com 198.51.100.3 50 reject fail fail big.example "" "" 0 0
  with_tsv 'print_outcomes'
  run bash -c "printf '%s\n' \"\$1\" | grep -oE '(big|small)\.example' | head -2 | tr -d '\n'" _ "$output"
  [ "$output" = "big.examplesmall.example" ]
}

# --- Flags -------------------------------------------------------------------------------------

# The interesting middle ground: a sender that authenticates on its own domain but does not align with
# the header_from, which is either a legitimate sender to configure or an ESP being abused.
@test "authenticated but unaligned mail is flagged with both domains" {
  record_row example.com 1700000000 google.com 198.51.100.1 25 none fail fail example.com "esp.test:pass" "" 0 1
  with_tsv 'analyze_flags'
  run cat "$FLAGS"
  [[ "$output" == *"align"* ]]
  [[ "$output" == *"25 msg for example.com authenticated on esp.test but did NOT align"* ]]
}

@test "a record passing both dkim and spf on one domain is counted once" {
  record_row example.com 1700000000 google.com 198.51.100.1 10 none fail fail example.com "esp.test:pass" "esp.test:pass" 0 1
  with_tsv 'analyze_flags'
  run grep -c 'authenticated on esp.test' "$FLAGS"
  [ "$output" = "1" ]
}

@test "temperror and permerror results are flagged as configuration faults" {
  record_row example.com 1700000000 google.com 198.51.100.1 8 none pass pass example.com "d.test:temperror" "" 1 1
  with_tsv 'analyze_flags'
  run cat "$FLAGS"
  [[ "$output" == *"config"*"8 msg saw an SPF/DKIM temperror or permerror"* ]]
}

@test "aligned mail that was still quarantined or rejected is flagged" {
  record_row example.com 1700000000 google.com 198.51.100.1 4 quarantine pass pass example.com "" "" 1 1
  with_tsv 'analyze_flags'
  run cat "$FLAGS"
  [[ "$output" == *"4 msg passed DMARC alignment yet were quarantined/rejected"* ]]
}

@test "unauthenticated failures are flagged as spoofing" {
  record_row example.com 1700000000 google.com 198.51.100.1 900 reject fail fail example.com "" "" 0 0
  with_tsv 'analyze_flags'
  run cat "$FLAGS"
  [[ "$output" == *"spoof"*"900 msg failed with NO valid authentication"* ]]
}

@test "clean mail raises no flags at all" {
  record_row example.com 1700000000 google.com 198.51.100.1 100 none pass pass example.com "d.test:pass" "" 1 1
  with_tsv 'analyze_flags'
  [ ! -s "$FLAGS" ]
}

@test "nothing flagged is stated plainly" {
  with_tsv 'print_flags'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing flagged"* ]]
}

@test "each flag category is rendered under its own label" {
  printf 'policy\tpolicy line\n' >> "$FLAGS"
  printf 'align\talign line\n' >> "$FLAGS"
  printf 'config\tconfig line\n' >> "$FLAGS"
  printf 'spoof\tspoof line\n' >> "$FLAGS"
  printf 'info\tinfo line\n' >> "$FLAGS"
  with_tsv 'print_flags || true'
  [[ "$output" == *"[POLICY] policy line"* ]]
  [[ "$output" == *"[ALIGNMENT] align line"* ]]
  [[ "$output" == *"[CONFIG] config line"* ]]
  [[ "$output" == *"[SPOOFING] spoof line"* ]]
  [[ "$output" == *"[INFO] info line"* ]]
}

# Inbound forgery against an enforcing policy is expected and already blocked, so it is reported without
# turning the run into a failure; only findings the operator can act on do that.
@test "only actionable categories make print_flags return nonzero" {
  printf 'spoof\tforgery\n' >> "$FLAGS"
  printf 'info\tnote\n' >> "$FLAGS"
  with_tsv 'print_flags >/dev/null'
  [ "$status" -eq 0 ]

  printf 'policy\tsomething to fix\n' >> "$FLAGS"
  with_tsv 'print_flags >/dev/null'
  [ "$status" -eq 1 ]
}

# --- Failing ranges and geolocation ------------------------------------------------------------

@test "failing IPv4 sources are grouped into /24 ranges by volume" {
  record_row example.com 1700000000 google.com 198.51.100.7 30 reject fail fail example.com "" "" 0 0
  record_row example.com 1700000000 google.com 198.51.100.9 20 reject fail fail example.com "" "" 0 0
  record_row example.com 1700000000 google.com 203.0.113.5 5 reject fail fail example.com "" "" 0 0
  with_tsv 'print_flags || true'
  [[ "$output" == *"198.51.100.0/24"* ]]
  [[ "$output" == *"203.0.113.0/24"* ]]
  [[ "$output" == *"50"* ]]
}

@test "failing IPv6 sources are grouped into /64 ranges" {
  record_row example.com 1700000000 google.com "2001:db8:1:2::5" 12 reject fail fail example.com "" "" 0 0
  with_tsv 'print_flags || true'
  [[ "$output" == *"2001:db8:1:2::/64"* ]]
}

@test "the range list is limited to the top N unless --all is given" {
  local i
  for i in 1 2 3 4 5; do
    record_row example.com 1700000000 google.com "198.51.$i.1" "$i" reject fail fail example.com "" "" 0 0
  done
  with_tsv '_top_n=2; print_flags || true'
  run bash -c "printf '%s\n' \"\$1\" | grep -c '/24'" _ "$output"
  [ "$output" = "2" ]

  with_tsv '_top_n=2; _show_all=true; print_flags || true'
  run bash -c "printf '%s\n' \"\$1\" | grep -c '/24'" _ "$output"
  [ "$output" = "5" ]
}

@test "a country is shown against a range when the lookup answers" {
  record_row example.com 1700000000 google.com 198.51.100.7 30 reject fail fail example.com "" "" 0 0
  stub_outputs curl <<< '[{"status":"success","country":"Ruritania","query":"198.51.100.7"}]'
  with_tsv 'print_flags || true'
  [[ "$output" == *"198.51.100.0/24"* ]]
  [[ "$output" == *"Ruritania"* ]]
}

@test "an unavailable lookup says so rather than inventing a country" {
  record_row example.com 1700000000 google.com 198.51.100.7 30 reject fail fail example.com "" "" 0 0
  with_tsv 'print_flags || true'
  [[ "$output" == *"unknown"* ]]
  [[ "$output" == *"Country lookup unavailable"* ]]
}

@test "geolocate_ips returns the addresses the service resolved" {
  stub_outputs curl <<< '[{"status":"success","country":"Ruritania","query":"198.51.100.7"},{"status":"fail","country":"","query":"203.0.113.1"}]'
  with_tsv 'geolocate_ips 198.51.100.7 203.0.113.1'
  [ "$output" = "198.51.100.7	Ruritania" ]
}

@test "geolocate_ips asks for nothing when given no addresses" {
  with_tsv 'geolocate_ips; echo done'
  [ "$output" = "done" ]
  [ "$(stub_calls curl)" -eq 0 ]
}

# --- End to end --------------------------------------------------------------------------------

@test "a clean enforcing report exits 0" {
  report_xml "$REPORTS/r.xml" clean.example reject google.com 1700000000 \
    "$(record_xml 198.51.100.1 10 none pass pass clean.example clean.example:pass)"
  report
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean.example"* ]]
  [[ "$output" == *"Nothing flagged"* ]]
}

@test "an actionable finding exits 2" {
  report_xml "$REPORTS/r.xml" weak.example none google.com 1700000000 \
    "$(record_xml 198.51.100.1 10 none pass pass weak.example)"
  report
  [ "$status" -eq 2 ]
  [[ "$output" == *"NOT ENFORCING"* ]]
  [[ "$output" == *"[POLICY]"* ]]
}

@test "spoofing alone does not fail the run" {
  report_xml "$REPORTS/r.xml" strict.example reject google.com 1700000000 \
    "$(record_xml 198.51.100.1 5 none pass pass strict.example strict.example:pass)" \
    "$(record_xml 203.0.113.9 900 reject fail fail strict.example)"
  report
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SPOOFING]"* ]]
}

@test "a directory of only unparseable reports is an error" {
  printf '<nope/>\n' > "$REPORTS/bad.xml"
  report
  [ "$status" -eq 1 ]
  [[ "$output" == *"No valid DMARC reports"* ]]
}

@test "every section heading appears in a full run" {
  report_xml "$REPORTS/r.xml" full.example reject google.com 1700000000 \
    "$(record_xml 198.51.100.1 10 none pass pass full.example full.example:pass)"
  report
  [[ "$output" == *"DMARC aggregate report"* ]]
  [[ "$output" == *"Published policy"* ]]
  [[ "$output" == *"Policy changes over time"* ]]
  [[ "$output" == *"DMARC results"* ]]
  [[ "$output" == *"Per-domain breakdown"* ]]
  [[ "$output" == *"Flags"* ]]
}

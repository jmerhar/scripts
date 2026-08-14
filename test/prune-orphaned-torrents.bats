#!/usr/bin/env bats
#
# This script removes torrents from a daemon and deletes files with rm, so the suite is built around one
# question: can it be made to delete something that is still wanted? The significance gate, the
# orphaned/hard-linked split and the stray/candidate partition are all there to prevent exactly that, and
# they are what the tests below concentrate on.
#
# SCAN_DIRS decides what gets scanned and deleted, and the config committed beside the script names the
# real server volumes. Every test therefore supplies a CONFIG_FILE whose scan roots are inside
# $BATS_TEST_TMPDIR; there is a test at the end asserting the suite cannot forget to.
#
# Deluge is reached over curl, whose stub answers per JSON-RPC method (see test/stubs/_stub). rm, rmdir
# and find are the real tools, working inside the temp tree, because whether a file survived is the
# actual contract and a stub could only show that rm was invoked.

load test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/prune-orphaned-torrents.sh"
  TEMP_ROOT="$BATS_TEST_TMPDIR/temp"
  LIBRARY="$BATS_TEST_TMPDIR/library"
  mkdir -p "$TEMP_ROOT" "$LIBRARY"
  CONF="$BATS_TEST_TMPDIR/prune.conf"
  write_conf
  # Accumulated by the torrent helper, one entry per call.
  TORRENTS='{}'
  # A working daemon by default; individual tests override the pieces they are about.
  rpc_reply auth.login 'true'
  rpc_reply web.connected 'true'
  rpc_reply core.get_torrents_status '{}'
  rpc_reply core.remove_torrent 'true'
}

########################################
# Writes the fixture config. Extra lines are appended verbatim, so a test can override a setting.
# Arguments:
#   Additional config lines.
########################################
write_conf() {
  {
    printf 'SCAN_DIRS=(%s)\n' "\"$TEMP_ROOT\""
    printf 'EXCLUDE_PATTERNS=("*.nfo" "*.jpg" "*.srt" "sample*")\n'
    printf 'DELUGE_URL="http://127.0.0.1:8112/json"\n'
    printf 'DELUGE_PASSWORD="secret"\n'
    printf 'MIN_MEDIA_RATIO=0.1\n'
    local line
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$CONF"
}

########################################
# Gives the curl stub a canned JSON-RPC result for one method.
# Arguments:
#   method: The JSON-RPC method name.
#   result_json: The value to return as ".result".
########################################
rpc_reply() {
  printf '{"result": %s}\n' "$2" > "$STUB_FIXTURES/curl.$1.stdout"
}

########################################
# Gives the curl stub a raw (possibly malformed) response body for one method.
# Arguments:
#   method: The JSON-RPC method name.
#   body: The exact response body.
########################################
rpc_raw() {
  printf '%s' "$2" > "$STUB_FIXTURES/curl.$1.stdout"
}

########################################
# Creates an orphaned file: one link only, so the scan treats it as abandoned.
# Arguments:
#   path: Path relative to TEMP_ROOT.
#   size: Size in bytes (default 1000).
########################################
orphan() {
  local rel="$1" size="${2:-1000}"
  mkdir -p "$(dirname "$TEMP_ROOT/$rel")"
  head -c "$size" /dev/zero > "$TEMP_ROOT/$rel"
}

########################################
# Creates a file that is still hard-linked from the library, as an in-use download is.
# Arguments:
#   path: Path relative to TEMP_ROOT.
#   size: Size in bytes (default 1000).
########################################
linked() {
  local rel="$1" size="${2:-1000}"
  mkdir -p "$(dirname "$TEMP_ROOT/$rel")"
  head -c "$size" /dev/zero > "$TEMP_ROOT/$rel"
  ln "$TEMP_ROOT/$rel" "$LIBRARY/$(basename "$rel").link"
}

########################################
# Declares one torrent for the status reply. Files are "name:size" pairs relative to the save path.
# Arguments:
#   hash: Info-hash.
#   name: Torrent name.
#   save_path: Its download location.
#   time_added: Epoch seconds.
#   Remaining: "relative/path:size" pairs.
########################################
torrent() {
  local hash="$1" name="$2" save="$3" added="$4"
  shift 4
  local files="[]" pair
  for pair in "$@"; do
    files=$(jq -c --arg p "${pair%:*}" --argjson s "${pair##*:}" \
      '. + [{path: $p, size: $s}]' <<<"$files")
  done
  local total
  total=$(jq '[.[].size] | add // 0' <<<"$files")
  TORRENTS=$(jq -c \
    --arg h "$hash" --arg n "$name" --arg sp "$save" --argjson ta "$added" \
    --argjson f "$files" --argjson tot "$total" \
    '. + {($h): {name: $n, download_location: $sp, save_path: $sp, total_size: $tot,
                 time_added: $ta, files: $f}}' <<<"$TORRENTS")
  rpc_reply core.get_torrents_status "$TORRENTS"
}

########################################
# Runs the script with the fixture config, answering prompts from the given keys.
# Arguments:
#   Command-line arguments; a leading "keys=..." supplies stdin.
########################################
prune_run() {
  local keys=""
  if [[ "${1:-}" == keys=* ]]; then
    keys="${1#keys=}"
    shift
  fi
  if [[ -n "$keys" ]]; then
    CONFIG_FILE="$CONF" run_script "$SCRIPT" -C "$@" <<<"$keys"
  else
    CONFIG_FILE="$CONF" run_script "$SCRIPT" -C "$@" < /dev/null
  fi
}

########################################
# Counts the JSON-RPC calls recorded for a method.
# Arguments:
#   method: The JSON-RPC method name.
########################################
rpc_calls() {
  grep -c "^curl-rpc $1 " "$STUB_CALLS" 2>/dev/null || true
}

########################################
# Evaluates a snippet inside the script with the config loaded, as main does.
########################################
with_conf() {
  CONFIG_FILE="$CONF" run_snippet "$SCRIPT" "load_config >/dev/null; $1"
}

# --- Options and configuration -----------------------------------------------------------------

@test "--help explains what it prunes" {
  prune_run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphaned media files"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "an unknown option is refused" {
  prune_run --wat
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "a missing configuration file is refused" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_script "$SCRIPT" -C < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_FILE is set to"* ]]
}

@test "SCAN_DIRS must be a non-empty array" {
  printf 'DELUGE_URL="u"\nDELUGE_PASSWORD="p"\n' > "$CONF"
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"SCAN_DIRS"* ]]
}

@test "the Deluge endpoint and password must be set" {
  printf 'SCAN_DIRS=(%s)\nDELUGE_PASSWORD="p"\n' "\"$TEMP_ROOT\"" > "$CONF"
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"DELUGE_URL"* ]]
  printf 'SCAN_DIRS=(%s)\nDELUGE_URL="u"\n' "\"$TEMP_ROOT\"" > "$CONF"
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"DELUGE_PASSWORD"* ]]
}

# The ratio scales the significance gate, so a value outside 0..1 would either flag every torrent or
# none of them.
@test "MIN_MEDIA_RATIO outside zero-to-one is refused" {
  write_conf 'MIN_MEDIA_RATIO=2'
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIN_MEDIA_RATIO must be a number between 0 and 1"* ]]
  write_conf 'MIN_MEDIA_RATIO=abc'
  prune_run
  [ "$status" -eq 1 ]
}

@test "MIN_MEDIA_RATIO of zero and one are both accepted" {
  local value
  for value in 0 1 0.5 1.0; do
    write_conf "MIN_MEDIA_RATIO=${value}"
    prune_run
    [ "$status" -eq 0 ]
  done
}

# --- Scan directories --------------------------------------------------------------------------

@test "a non-existent scan directory is skipped with a note" {
  write_conf
  printf 'SCAN_DIRS=(%s %s)\n' "\"$TEMP_ROOT\"" "\"$BATS_TEST_TMPDIR/gone\"" >> "$CONF"
  prune_run
  [[ "$output" == *"Skipping non-existent scan directory"* ]]
  [[ "$output" == *"gone"* ]]
}

@test "no existing scan directory at all is an error" {
  printf 'SCAN_DIRS=(%s)\nDELUGE_URL="u"\nDELUGE_PASSWORD="p"\n' "\"$BATS_TEST_TMPDIR/gone\"" > "$CONF"
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"None of the configured SCAN_DIRS exist"* ]]
}

# A trailing slash would make find emit "/root//file", which never matches the path built from the
# torrent's save path, so every orphan would look unowned.
@test "a trailing slash on a scan directory does not break matching" {
  with_conf "SCAN_DIRS=('${TEMP_ROOT}/'); prepare_scan_dirs; printf '%s' \"\${_scan_dirs[0]}\""
  [ "$output" = "$TEMP_ROOT" ]
}

@test "prepare_scan_dirs keeps a root that has no trailing slash" {
  with_conf "SCAN_DIRS=('${TEMP_ROOT}'); prepare_scan_dirs; printf '%s' \"\${_scan_dirs[0]}\""
  [ "$output" = "$TEMP_ROOT" ]
}

# --- Finding orphans ---------------------------------------------------------------------------

@test "a file with one link is an orphan and a hard-linked one is not" {
  orphan show/ep1.mkv
  linked show/ep2.mkv
  with_conf "prepare_scan_dirs; find_orphans; jq -r '.[]' <<<\"\$_orphans_json\""
  [[ "$output" == *"ep1.mkv"* ]]
  [[ "$output" != *"ep2.mkv"* ]]
}

@test "excluded filenames are not reported as orphans" {
  orphan show/ep1.mkv
  orphan show/ep1.nfo
  orphan show/poster.JPG
  orphan show/sample-clip.mkv
  with_conf "prepare_scan_dirs; find_orphans; jq -r '.[]' <<<\"\$_orphans_json\""
  [[ "$output" == *"ep1.mkv"* ]]
  [[ "$output" != *".nfo"* ]]
  [[ "$output" != *"poster"* ]]
  [[ "$output" != *"sample-clip"* ]]
}

@test "a filename with spaces is found intact" {
  orphan "show/The Episode (2024).mkv"
  with_conf "prepare_scan_dirs; find_orphans; jq -r '.[]' <<<\"\$_orphans_json\""
  [[ "$output" == *"The Episode (2024).mkv"* ]]
}

# A symlink has a link count of 1, so only the file-type test keeps it out of the orphan list. Offering
# one would mean deleting a link whose target is very much still in use.
@test "a symlink is not treated as an orphaned file" {
  orphan show/real.mkv
  ln -s "$TEMP_ROOT/show/real.mkv" "$TEMP_ROOT/show/link.mkv"
  with_conf "prepare_scan_dirs; find_orphans; jq -r '.[]' <<<\"\$_orphans_json\""
  [[ "$output" == *"real.mkv"* ]]
  [[ "$output" != *"link.mkv"* ]]
}

@test "nothing to scan reports no orphans and stops before contacting Deluge" {
  prune_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No orphaned files found"* ]]
  [ "$(stub_calls curl)" -eq 0 ]
}

# --- Talking to Deluge -------------------------------------------------------------------------

@test "authentication failure is reported" {
  orphan show/ep1.mkv
  rpc_reply auth.login 'false'
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Deluge authentication failed"* ]]
}

@test "a transport failure is reported" {
  orphan show/ep1.mkv
  stub_fails curl 7
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Deluge request failed"* ]]
}

# curl -f only fails on HTTP >= 400, so a reverse proxy answering 200 with a login page has to be
# caught here or jq would abort the run with a parse error instead.
@test "an empty or non-JSON response is reported as a likely wrong URL" {
  orphan show/ep1.mkv
  rpc_raw auth.login ''
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty or non-JSON response"* ]]
  [[ "$output" == *"DELUGE_URL"* ]]
  rpc_raw auth.login '<html>login</html>'
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty or non-JSON response"* ]]
}

@test "an API error in the response body is reported" {
  orphan show/ep1.mkv
  rpc_raw auth.login '{"error": {"message": "Not authenticated"}, "result": null}'
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Deluge API error"* ]]
  [[ "$output" == *"Not authenticated"* ]]
}

@test "the password is sent in the request body, never in the argument list" {
  orphan show/ep1.mkv
  prune_run
  run grep -c 'secret' "$STUB_CALLS"
  # The body line carries it; the argv line must not, or it would be visible in ps.
  run bash -c "grep '^curl ' '$STUB_CALLS' | grep -c secret || true"
  [ "$output" = "0" ]
  run bash -c "grep '^curl-rpc auth.login ' '$STUB_CALLS' | grep -c secret || true"
  [ "$output" = "1" ]
}

@test "a web UI already connected to a daemon is not reconnected" {
  orphan show/ep1.mkv
  prune_run
  [ "$(rpc_calls web.get_hosts)" -eq 0 ]
  [ "$(rpc_calls web.connect)" -eq 0 ]
}

@test "a disconnected web UI is connected to the first configured host" {
  orphan show/ep1.mkv
  rpc_reply web.connected 'false'
  rpc_reply web.get_hosts '[["hostid1","127.0.0.1",58846,"localclient"]]'
  rpc_reply web.connect 'null'
  prune_run
  [ "$(rpc_calls web.connect)" -eq 1 ]
  stub_called 'curl-rpc web.connect .*hostid1'
}

@test "a disconnected web UI with no configured hosts is an error" {
  orphan show/ep1.mkv
  rpc_reply web.connected 'false'
  rpc_reply web.get_hosts '[]'
  prune_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"No Deluge daemon hosts are configured"* ]]
}

@test "the torrent status request asks for the fields the report needs" {
  orphan show/ep1.mkv
  prune_run
  stub_called 'curl-rpc core.get_torrents_status .*download_location'
  stub_called 'curl-rpc core.get_torrents_status .*time_added'
  stub_called 'curl-rpc core.get_torrents_status .*files'
}

# --- Choosing candidates -----------------------------------------------------------------------

@test "a torrent whose media is orphaned becomes a candidate" {
  orphan show/ep1.mkv 5000
  torrent hashA "Show S01E01" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000"
  prune_run --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Show S01E01"* ]]
  [[ "$output" == *"would remove this torrent"* ]]
}

# This is the safety gate: a torrent still seeding wanted media must not be offered just because a
# tiny extra lost its link.
@test "a torrent flagged only by a tiny extra is not a candidate" {
  linked show/feature.mkv 100000
  orphan show/deleted-scene.mkv 500
  torrent hashA "The Feature" "$TEMP_ROOT/show" 1000 "feature.mkv:100000" "deleted-scene.mkv:500"
  prune_run --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to prune"* ]]
  [[ "$output" != *"The Feature"* ]]
}

@test "MIN_MEDIA_RATIO decides how small is too small" {
  linked show/feature.mkv 100000
  orphan show/extra.mkv 5000
  torrent hashA "The Feature" "$TEMP_ROOT/show" 1000 "feature.mkv:100000" "extra.mkv:5000"
  write_conf 'MIN_MEDIA_RATIO=0.9'
  prune_run --dry-run
  [[ "$output" == *"Nothing to prune"* ]]
  write_conf 'MIN_MEDIA_RATIO=0.01'
  prune_run --dry-run
  [[ "$output" == *"The Feature"* ]]
}

# A part-orphaned torrent is the case a user most needs explained, since removing it frees only some of
# its files.
@test "a partly orphaned torrent lists what is freed and what is kept" {
  orphan show/ep1.mkv 5000
  linked show/ep2.mkv 5000
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000" "ep2.mkv:5000"
  prune_run --dry-run
  [[ "$output" == *"still hard-linked"* ]]
  [[ "$output" == *"will free"* ]]
  [[ "$output" == *"ep1.mkv"* ]]
  [[ "$output" == *"will keep"* ]]
  [[ "$output" == *"ep2.mkv"* ]]
}

@test "a fully orphaned torrent needs no per-file breakdown" {
  orphan show/ep1.mkv 5000
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000"
  prune_run --dry-run
  [[ "$output" != *"still hard-linked"* ]]
  [[ "$output" != *"will keep"* ]]
}

# A sidecar losing its link says nothing about whether the media is still wanted, so an excluded file
# never enters the orphan set and cannot put its torrent up for removal.
@test "a torrent whose only unlinked file is a sidecar is never offered" {
  orphan show/ep1.nfo 5000
  linked show/ep1.mkv 5000
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000" "ep1.nfo:5000"
  prune_run --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"No orphaned files found"* ]]
  [ "$(rpc_calls core.remove_torrent)" -eq 0 ]
}

# The counts and the kept/freed lists describe media only. Counting sidecars would misreport how much of
# a torrent is still in use, which is the number the user decides on.
@test "sidecars are left out of the media accounting" {
  orphan show/ep1.mkv 5000
  linked show/ep2.mkv 5000
  orphan show/ep1.nfo 400
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000" "ep2.mkv:5000" "ep1.nfo:400"
  prune_run --dry-run
  [[ "$output" == *"orphaned: 1/2 media files"* ]]
  [[ "$output" == *"ep2.mkv"* ]]
  [[ "$output" != *"ep1.nfo"* ]]
}

# The scan applies the exclusions with find -iname, but the torrent's own file list is classified again in
# jq, and release groups are not consistent about case. A sidecar read as media inflates the "still in
# use" count the user decides on.
@test "sidecars are recognised whatever the case of their extension" {
  orphan show/ep1.mkv 5000
  linked show/ep1.NFO 400
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000" "ep1.NFO:400"
  prune_run --dry-run
  [[ "$output" == *"orphaned: 1/1 media files"* ]]
}

# The point of the whole exercise is the space recovered, and it is only the orphaned copies that are
# freed -- the hard-linked ones survive the removal.
@test "the freed size counts the orphaned files only" {
  orphan show/ep1.mkv 5000
  linked show/ep2.mkv 5000
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000" "ep2.mkv:5000"
  prune_run --dry-run
  [[ "$output" == *"frees: 4.88 KB"* ]]
  [[ "$output" == *"Would remove 1 torrent(s), freeing 4.88 KB."* ]]
}

@test "the freed sizes of several removals are added up" {
  orphan a/ep.mkv 5000
  orphan b/ep.mkv 3000
  torrent h1 "One" "$TEMP_ROOT/a" 1000 "ep.mkv:5000"
  torrent h2 "Two" "$TEMP_ROOT/b" 2000 "ep.mkv:3000"
  prune_run --yes
  [[ "$output" == *"Removed 2 torrent(s), freeing 7.81 KB."* ]]
}

@test "candidates are offered oldest first" {
  orphan a/ep.mkv 5000
  orphan b/ep.mkv 5000
  torrent hashNew "Newer" "$TEMP_ROOT/b" 9000 "ep.mkv:5000"
  torrent hashOld "Older" "$TEMP_ROOT/a" 1000 "ep.mkv:5000"
  prune_run --dry-run
  [[ "$output" == *"Older"*"Newer"* ]]
}

# A metadata-only or errored torrent reports no location at all. It still carries a file list, so the
# fixture gives it one: the run must skip it rather than building paths on an empty base.
@test "a torrent with no save location is ignored rather than aborting the run" {
  orphan show/ep1.mkv 5000
  TORRENTS='{"hashBad": {"name": "Broken", "total_size": 5000, "time_added": 1,
                         "files": [{"path": "ep1.mkv", "size": 5000}]}}'
  rpc_reply core.get_torrents_status "$TORRENTS"
  prune_run --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"Broken"* ]]
}

# save_path is the older field name; a daemon that reports only that one must still work.
@test "a torrent reporting only save_path is understood" {
  orphan show/ep1.mkv 5000
  TORRENTS=$(jq -nc --arg sp "$TEMP_ROOT/show" \
    '{hashA: {name: "Show", save_path: $sp, total_size: 5000, time_added: 1,
              files: [{path: "ep1.mkv", size: 5000}]}}')
  rpc_reply core.get_torrents_status "$TORRENTS"
  prune_run --dry-run
  [[ "$output" == *"Show"* ]]
  [[ "$output" == *"would remove"* ]]
}

# Deluge reports paths as the daemon sees them, which inside a container differ from the host's.
@test "the Deluge path prefix is rewritten to the local one" {
  orphan show/ep1.mkv 5000
  torrent hashA "Show" "/downloads/show" 1000 "ep1.mkv:5000"
  write_conf "DELUGE_PATH_PREFIX=\"/downloads\"" "LOCAL_PATH_PREFIX=\"$TEMP_ROOT\""
  prune_run --dry-run
  [[ "$output" == *"Show"* ]]
  [[ "$output" == *"would remove"* ]]
}

@test "without the prefix rewrite a container path matches nothing" {
  orphan show/ep1.mkv 5000
  torrent hashA "Show" "/downloads/show" 1000 "ep1.mkv:5000"
  prune_run --dry-run
  [[ "$output" != *"would remove this torrent"* ]]
}

# --- Strays ------------------------------------------------------------------------------------

@test "an orphan belonging to no torrent is offered as a stray" {
  orphan loose/ep1.mkv 5000
  rpc_reply core.get_torrents_status '{}'
  prune_run --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stray files"* ]]
  [[ "$output" == *"ep1.mkv"* ]]
  [[ "$output" == *"would delete this file"* ]]
}

# The distinction that protects live data: a file the significance gate declined is still part of a
# torrent, so it must not be offered for direct deletion.
@test "an orphan inside a torrent the gate declined is not a stray" {
  linked show/feature.mkv 100000
  orphan show/deleted-scene.mkv 500
  torrent hashA "The Feature" "$TEMP_ROOT/show" 1000 "feature.mkv:100000" "deleted-scene.mkv:500"
  prune_run --dry-run
  [[ "$output" != *"Stray files"* ]]
  [[ "$output" == *"Nothing to prune"* ]]
}

@test "strays and candidates are reported in the same run" {
  orphan show/ep1.mkv 5000
  orphan loose/other.mkv 3000
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000"
  prune_run --dry-run
  [[ "$output" == *"Show"* ]]
  [[ "$output" == *"Stray files"* ]]
  [[ "$output" == *"other.mkv"* ]]
}

# --- Removing, for real ------------------------------------------------------------------------

@test "--dry-run contacts nothing to remove and deletes no file" {
  orphan show/ep1.mkv 5000
  orphan loose/stray.mkv 3000
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000"
  prune_run --dry-run
  [ "$(rpc_calls core.remove_torrent)" -eq 0 ]
  [ -f "$TEMP_ROOT/show/ep1.mkv" ]
  [ -f "$TEMP_ROOT/loose/stray.mkv" ]
  [[ "$output" == *"Would remove 1 torrent"* ]]
  [[ "$output" == *"Would delete 1 stray file"* ]]
}

@test "--yes removes the torrent and its data without asking" {
  orphan show/ep1.mkv 5000
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000"
  prune_run --yes
  [ "$status" -eq 0 ]
  [ "$(rpc_calls core.remove_torrent)" -eq 1 ]
  stub_called 'curl-rpc core.remove_torrent .*hashA'
  [[ "$output" == *"Removed: Show"* ]]
  [[ "$output" == *"Removed 1 torrent"* ]]
}

# The second parameter is what tells Deluge to delete the downloaded files as well; without it the
# torrent goes but the wasted space stays.
@test "the remove request asks for the data to go too" {
  orphan show/ep1.mkv 5000
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000"
  prune_run --yes
  stub_called 'curl-rpc core.remove_torrent .*\[.*hashA.*,true\]'
}

@test "answering y removes and answering n does not" {
  orphan a/ep.mkv 5000
  orphan b/ep.mkv 5000
  torrent hashOld "Older" "$TEMP_ROOT/a" 1000 "ep.mkv:5000"
  torrent hashNew "Newer" "$TEMP_ROOT/b" 2000 "ep.mkv:5000"
  prune_run keys=yn
  [ "$(rpc_calls core.remove_torrent)" -eq 1 ]
  stub_called 'curl-rpc core.remove_torrent .*hashOld'
  run bash -c "grep -c hashNew '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "answering a removes the rest without further prompting" {
  orphan a/ep.mkv 5000
  orphan b/ep.mkv 5000
  orphan c/ep.mkv 5000
  torrent h1 "One" "$TEMP_ROOT/a" 1000 "ep.mkv:5000"
  torrent h2 "Two" "$TEMP_ROOT/b" 2000 "ep.mkv:5000"
  torrent h3 "Three" "$TEMP_ROOT/c" 3000 "ep.mkv:5000"
  prune_run keys=na
  [ "$(rpc_calls core.remove_torrent)" -eq 2 ]
}

# Quitting has to leave the loop entirely. Breaking only out of the prompt would move on to the next
# torrent and ask about it, which is the opposite of what the user just asked for -- so the third
# candidate must never even be shown.
@test "answering q stops and still reports what was done" {
  orphan a/ep.mkv 5000
  orphan b/ep.mkv 5000
  orphan c/ep.mkv 5000
  torrent h1 "One" "$TEMP_ROOT/a" 1000 "ep.mkv:5000"
  torrent h2 "Two" "$TEMP_ROOT/b" 2000 "ep.mkv:5000"
  torrent h3 "Three" "$TEMP_ROOT/c" 3000 "ep.mkv:5000"
  prune_run keys=yq
  [ "$(rpc_calls core.remove_torrent)" -eq 1 ]
  [[ "$output" == *"Quitting"* ]]
  [[ "$output" == *"Removed 1 torrent"* ]]
  [[ "$output" == *"Two"* ]]
  [[ "$output" != *"Three"* ]]
}

# An unrecognised key must re-ask rather than being taken as consent to delete.
@test "an unrecognised key re-asks instead of removing" {
  orphan a/ep.mkv 5000
  torrent h1 "One" "$TEMP_ROOT/a" 1000 "ep.mkv:5000"
  prune_run keys=xn
  [ "$(rpc_calls core.remove_torrent)" -eq 0 ]
}

# Empty stdin must end the loop, not spin re-prompting forever.
@test "exhausted input quits instead of looping" {
  orphan a/ep.mkv 5000
  torrent h1 "One" "$TEMP_ROOT/a" 1000 "ep.mkv:5000"
  prune_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No more input; quitting"* ]]
  [ "$(rpc_calls core.remove_torrent)" -eq 0 ]
}

@test "a refused removal is reported and not counted" {
  orphan a/ep.mkv 5000
  torrent h1 "One" "$TEMP_ROOT/a" 1000 "ep.mkv:5000"
  rpc_reply core.remove_torrent 'false'
  prune_run --yes
  [[ "$output" == *"Failed to remove: One"* ]]
  [[ "$output" == *"Removed 0 torrent"* ]]
}

@test "a removal that errors at the transport is reported" {
  orphan a/ep.mkv 5000
  torrent h1 "One" "$TEMP_ROOT/a" 1000 "ep.mkv:5000"
  printf '7' > "$STUB_FIXTURES/curl.core.remove_torrent.fail"
  prune_run --yes
  [[ "$output" == *"Failed to remove: One"* ]]
}

# --- Deleting strays ---------------------------------------------------------------------------

@test "--yes deletes a stray file" {
  orphan loose/stray.mkv 3000
  rpc_reply core.get_torrents_status '{}'
  prune_run --yes
  [ ! -e "$TEMP_ROOT/loose/stray.mkv" ]
  [[ "$output" == *"Deleted:"* ]]
  [[ "$output" == *"Deleted 1 stray file"* ]]
}

@test "answering n keeps a stray file" {
  orphan loose/stray.mkv 3000
  rpc_reply core.get_torrents_status '{}'
  prune_run keys=n
  [ -f "$TEMP_ROOT/loose/stray.mkv" ]
  [[ "$output" == *"Deleted 0 stray file"* ]]
}

@test "a stray whose name has spaces is deleted correctly" {
  orphan "loose/The Stray (2024).mkv" 3000
  rpc_reply core.get_torrents_status '{}'
  prune_run --yes
  [ ! -e "$TEMP_ROOT/loose/The Stray (2024).mkv" ]
}

@test "a directory left empty by a deletion is pruned" {
  orphan loose/only.mkv 3000
  rpc_reply core.get_torrents_status '{}'
  prune_run --yes
  [ ! -e "$TEMP_ROOT/loose" ]
}

# Pruning must stop at the scan root: removing it would break the next run, and anything above it is
# not this script's business at all.
@test "the scan root itself is never pruned" {
  orphan only.mkv 3000
  rpc_reply core.get_torrents_status '{}'
  prune_run --yes
  [ -d "$TEMP_ROOT" ]
}

@test "a directory that still holds a file is not pruned" {
  orphan loose/stray.mkv 3000
  orphan loose/keep.nfo 100
  rpc_reply core.get_torrents_status '{}'
  prune_run --yes
  [ -d "$TEMP_ROOT/loose" ]
  [ -f "$TEMP_ROOT/loose/keep.nfo" ]
}

@test "prune_empty_dirs walks up several levels but stops at the root" {
  mkdir -p "$TEMP_ROOT/a/b/c"
  with_conf "prepare_scan_dirs; prune_empty_dirs '$TEMP_ROOT/a/b/c'"
  [ ! -e "$TEMP_ROOT/a" ]
  [ -d "$TEMP_ROOT" ]
}

@test "prune_empty_dirs refuses a directory outside the scan roots" {
  mkdir -p "$BATS_TEST_TMPDIR/outside/deep"
  with_conf "prepare_scan_dirs; prune_empty_dirs '$BATS_TEST_TMPDIR/outside/deep'"
  [ -d "$BATS_TEST_TMPDIR/outside/deep" ]
}

# --- Formatting --------------------------------------------------------------------------------

@test "format_size scales into human units" {
  run_snippet "$SCRIPT" \
    "printf '%s|%s|%s|%s' \"\$(format_size 0)\" \"\$(format_size 999)\" \"\$(format_size 1024)\" \"\$(format_size 1073741824)\""
  [ "$output" = "0 B|999.00 B|1.00 KB|1.00 GB" ]
}

@test "format_age shows days and hours, or hours and minutes" {
  run_snippet "$SCRIPT" \
    "printf '%s|%s|%s' \"\$(format_age 1051200)\" \"\$(format_age 11220)\" \"\$(format_age 0)\""
  [ "$output" = "12d 4h|3h 7m|0h 0m" ]
}

@test "format_age treats a negative age as zero" {
  run_snippet "$SCRIPT" "format_age -90000"
  [ "$output" = "0h 0m" ]
}

# --- Safety ------------------------------------------------------------------------------------

# The committed configuration names the real server volumes, so a test that forgot CONFIG_FILE would
# scan and offer to delete real media. This asserts the mechanism the whole suite depends on.
@test "the committed config is never what a test reads" {
  local committed="$REPO_ROOT/scripts/system/prune-orphaned-torrents.conf"
  [ -f "$committed" ]
  run grep -c "$TEMP_ROOT" "$committed"
  [ "$output" = "0" ]
  with_conf "printf '%s' \"\${SCAN_DIRS[0]}\""
  [ "$output" = "$TEMP_ROOT" ]
}

@test "no recorded call names a path outside the test directory" {
  orphan show/ep1.mkv 5000
  orphan loose/stray.mkv 3000
  torrent hashA "Show" "$TEMP_ROOT/show" 1000 "ep1.mkv:5000"
  prune_run --yes
  run grep -c "/mnt/storage" "$STUB_CALLS"
  [ "$output" = "0" ]
}

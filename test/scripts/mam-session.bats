#!/usr/bin/env bats
#
# mam-session holds a credential and talks to a private tracker, so three properties matter more than
# the rest: the session never reaches the process list or a file others can read, the tracker is not
# called when there is nothing to tell it, and a refusal is turned into the setting that has to change.
#
# The endpoint is a seam pointed at a stub host, so nothing here can reach the real tracker. curl answers
# per host, which lets one run be told a different thing by the address service and by the tracker.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/mam-session/mam-session.sh"

  STATE="$BATS_TEST_TMPDIR/state"
  CONFIG_FILE="$BATS_TEST_TMPDIR/mam-session.conf"
  export CONFIG_FILE
  configure

  # Neither host is real: the endpoint is a seam precisely so a test cannot reach a tracker.
  export MAM_ENDPOINT="https://tracker.invalid/json/dynamicSeedbox.php"
  export NOW=1800000000
}

########################################
# Writes a private config file.
# Arguments:
#   Extra lines to add, e.g. IP_SERVICE="".
########################################
configure() {
  {
    printf 'MAM_ID="session-secret-value"\n'
    printf 'STATE_DIR="%s"\n' "$STATE"
    printf 'IP_SERVICE="https://addresses.invalid/"\n'
    printf '%s\n' "$@"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

########################################
# Makes the address service answer with an address.
########################################
address_is() {
  printf '%s' "$1" > "$STUB_FIXTURES/curl.addresses.invalid.stdout"
}

########################################
# Makes the tracker answer with a JSON body and an HTTP status.
# Arguments:
#   status: The HTTP status to report through -w.
#   body: The JSON body.
########################################
tracker_answers() {
  printf '%s' "$1" > "$STUB_FIXTURES/curl.tracker.invalid.status"
  printf '%s' "$2" > "$STUB_FIXTURES/curl.tracker.invalid.stdout"
}

########################################
# Makes the tracker accept the session, reporting an address and network.
########################################
tracker_accepts() {
  tracker_answers 200 "{\"Success\":true,\"msg\":\"Completed\",\"ip\":\"${1:-198.51.100.7}\",\"ASN\":64500,\"AS\":\"Example Networks\"}"
}

# --- The credential ------------------------------------------------------------------------------

# The session is enough to act as the account, and a config anyone can read is how the script this
# replaces leaked one.
@test "a configuration other users can read is refused, not warned about" {
  chmod 644 "$CONFIG_FILE"
  address_is 198.51.100.7
  tracker_accepts
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is readable by other users"* ]]
  [[ "$output" == *"chmod 600"* ]]
  run stub_calls curl
  [ "$output" = "0" ]
}

# Arguments are visible to every other user through the process list.
@test "the session is never passed as a command-line argument" {
  address_is 198.51.100.7
  tracker_accepts
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c "grep -c 'session-secret-value' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
  stub_called 'curl .*-b .*session.cookies'
}

@test "the session is never printed, not even in debug output" {
  address_is 198.51.100.7
  tracker_accepts
  run_script "$SCRIPT" --debug
  [ "$status" -eq 0 ]
  [[ "$output" != *"session-secret-value"* ]]
}

@test "the cookie jar and the state directory are private" {
  address_is 198.51.100.7
  tracker_accepts
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  # Asked through the script's own accessor, since stat's flags differ between the two platforms this
  # publishes to — and the assertion is about the mode, not about which stat is installed.
  run_func "$SCRIPT" stat_mode "$STATE"
  [ "$output" = "700" ]
  run_func "$SCRIPT" stat_mode "$STATE/session.cookies"
  [ "$output" = "600" ]
}

@test "the configured session is written into the jar in the form curl reads" {
  address_is 198.51.100.7
  tracker_accepts
  run_script "$SCRIPT"
  run cat "$STATE/session.cookies"
  [[ "$output" == *"tracker.invalid"* ]]
  [[ "$output" == *"mam_id"* ]]
  [[ "$output" == *"session-secret-value"* ]]
}

@test "a run with no session configured says where to get one" {
  configure 'MAM_ID=""'
  chmod 600 "$CONFIG_FILE"
  address_is 198.51.100.7
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dynamic seedbox allowed"* ]]
}

# --- Calling sparingly ----------------------------------------------------------------------------

@test "the tracker is not called when the address has not changed" {
  address_is 198.51.100.7
  tracker_accepts 198.51.100.7
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  : > "$STUB_CALLS"

  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do: the address is still 198.51.100.7"* ]]
  run bash -c "grep -c 'tracker.invalid' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "a changed address does call the tracker" {
  address_is 198.51.100.7
  tracker_accepts 198.51.100.7
  run_script "$SCRIPT"
  : > "$STUB_CALLS"

  address_is 203.0.113.9
  tracker_accepts 203.0.113.9
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  stub_called 'curl .*tracker.invalid'
  run cat "$STATE/last-address"
  [ "$output" = "203.0.113.9" ]
}

# With no address to compare, the interval is the only thing standing between a timer and a private
# tracker's API.
@test "without an address service, calls are limited to one an interval" {
  configure 'IP_SERVICE=""' 'MIN_INTERVAL=3600'
  chmod 600 "$CONFIG_FILE"
  tracker_accepts
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  : > "$STUB_CALLS"

  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"calls are limited to one every 3600s"* ]]
  run bash -c "grep -c 'tracker.invalid' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "once the interval has passed the tracker is called again" {
  configure 'IP_SERVICE=""' 'MIN_INTERVAL=3600'
  chmod 600 "$CONFIG_FILE"
  tracker_accepts
  run_script "$SCRIPT"
  : > "$STUB_CALLS"

  NOW=$(( 1800000000 + 3601 )) run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  stub_called 'curl .*tracker.invalid'
}

@test "--force calls regardless" {
  address_is 198.51.100.7
  tracker_accepts 198.51.100.7
  run_script "$SCRIPT"
  : > "$STUB_CALLS"

  run_script "$SCRIPT" --force
  [ "$status" -eq 0 ]
  stub_called 'curl .*tracker.invalid'
}

@test "--dry-run calls nothing and writes no state" {
  address_is 198.51.100.7
  tracker_accepts
  run_script "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would ask the tracker"* ]]
  [ ! -e "$STATE/last-address" ]
  run bash -c "grep -c 'tracker.invalid' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

# A refusal that needs a settings change refuses just as fast next time, so the clock is still recorded.
@test "a refusal counts as a call for interval purposes" {
  configure 'IP_SERVICE=""'
  chmod 600 "$CONFIG_FILE"
  tracker_answers 403 '{"Success":false,"msg":"Invalid session - Other","ip":"198.51.100.7","ASN":64500,"AS":"Example Networks"}'
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [ -s "$STATE/last-call" ]
}

# --- Turning a refusal into the setting that has to change ----------------------------------------

# The likeliest answer to a first run: a session created without the dynamic-seedbox permission. The
# tracker calls it an incorrect session type, and the fix is one checkbox.
@test "a session-type refusal names the permission to enable" {
  tracker_answers 403 '{"Success":false,"msg":"Incorrect session type - not allowed this function","ip":"198.51.100.7","ASN":64500,"AS":"Example Networks"}'
  address_is 198.51.100.7
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"allow session to set dynamic seedbox"* ]]
  [[ "$output" != *"The tracker refused:"* ]]
}

@test "an ASN refusal names the network to add" {
  tracker_answers 403 '{"Success":false,"msg":"Incorrect ASN for this session","ip":"198.51.100.7","ASN":64500,"AS":"Example Networks"}'
  address_is 198.51.100.7
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ASN 64500 (Example Networks)"* ]]
  [[ "$output" == *"add additional ASN via IP address"* ]]
}

@test "an unrecognised session says it may be the wrong kind" {
  tracker_answers 403 '{"Success":false,"msg":"Invalid session - Other","ip":"198.51.100.7","ASN":64500,"AS":"Example Networks"}'
  address_is 198.51.100.7
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not recognise this session"* ]]
  [[ "$output" == *"dynamic seedbox allowed"* ]]
}

@test "an address mismatch says to allow the current address" {
  tracker_answers 403 '{"Success":false,"msg":"IP mismatch for session","ip":"198.51.100.7"}'
  address_is 198.51.100.7
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"locked to a different address"* ]]
}

@test "any other refusal is reported verbatim" {
  tracker_answers 403 '{"Success":false,"msg":"Rate limited, try later"}'
  address_is 198.51.100.7
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"The tracker refused: Rate limited, try later"* ]]
}

@test "a reply that is not the expected JSON is refused rather than read as success" {
  tracker_answers 502 '<html>bad gateway</html>'
  address_is 198.51.100.7
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not the JSON this expects"* ]]
  [ ! -e "$STATE/last-address" ]
}

@test "no answer at all is reported as such" {
  address_is 198.51.100.7
  printf '' > "$STUB_FIXTURES/curl.tracker.invalid.stdout"
  printf '000' > "$STUB_FIXTURES/curl.tracker.invalid.status"
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No answer from the tracker"* ]]
}

# --- What it reports ------------------------------------------------------------------------------

@test "a successful update names the address and network the tracker saw" {
  address_is 198.51.100.7
  tracker_accepts 203.0.113.9
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"points at 203.0.113.9 on ASN 64500 (Example Networks)"* ]]
  [[ "$output" == *"Completed"* ]]
  # The tracker's own view of the address is what gets remembered, not the service's.
  run cat "$STATE/last-address"
  [ "$output" = "203.0.113.9" ]
}

@test "--status reports the stored state and calls nothing" {
  address_is 198.51.100.7
  tracker_accepts
  run_script "$SCRIPT"
  : > "$STUB_CALLS"

  run_script "$SCRIPT" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"session         : stored"* ]]
  [[ "$output" == *"last address    : 198.51.100.7"* ]]
  [[ "$output" == *"last call       : 0s ago"* ]]
  run stub_calls curl
  [ "$output" = "0" ]
}

# A run from a timer says nothing; --status is where the reason has to be findable afterwards.
@test "--status reports what the tracker last said, refusal included" {
  tracker_answers 403 '{"Success":false,"msg":"Incorrect session type - not allowed this function","ip":"198.51.100.7"}'
  address_is 198.51.100.7
  run_script "$SCRIPT" --quiet
  [ "$status" -eq 1 ]

  run_script "$SCRIPT" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"last result     : refused: Incorrect session type - not allowed this function"* ]]
}

@test "--status reports an acceptance too" {
  address_is 198.51.100.7
  tracker_accepts
  run_script "$SCRIPT"
  run_script "$SCRIPT" --status
  [[ "$output" == *"last result     : accepted: Completed"* ]]
}

@test "--quiet says nothing when there is nothing to do" {
  address_is 198.51.100.7
  tracker_accepts 198.51.100.7
  run_script "$SCRIPT"

  run_script "$SCRIPT" --quiet
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# An address service that is down must not stop the tracker being told, since the tracker reports the
# address itself.
@test "an address service that answers nothing does not stop the run" {
  printf '' > "$STUB_FIXTURES/curl.addresses.invalid.stdout"
  tracker_accepts
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  stub_called 'curl .*tracker.invalid'
}

@test "an address service answering a captive-portal page is ignored" {
  printf '<html>sign in</html>' > "$STUB_FIXTURES/curl.addresses.invalid.stdout"
  tracker_accepts
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  stub_called 'curl .*tracker.invalid'
}

# --- Options --------------------------------------------------------------------------------------

@test "an interval that is not a number is refused" {
  configure 'MIN_INTERVAL="hourly"'
  chmod 600 "$CONFIG_FILE"
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIN_INTERVAL must be a whole number"* ]]
}

@test "the flags are recorded as parse_options sees them" {
  run_snippet "$SCRIPT" 'parse_options -f -s -n -q -C; printf "%s|%s|%s|%s|%s" "$_force" "$_status" "$_dry_run" "$_quiet" "$_no_color"'
  [ "$output" = "true|true|true|true|true" ]
}

@test "an unknown option is refused" {
  run_script "$SCRIPT" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'."* ]]
}

@test "a positional argument is refused" {
  run_script "$SCRIPT" extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected arguments: extra"* ]]
}

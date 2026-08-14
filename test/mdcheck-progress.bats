#!/usr/bin/env bats
#
# mdcheck-progress reads state that only exists on a Linux box with MD RAID mid-scrub, so the paths it
# reads come from the environment (MDSTAT, SYS_BLOCK, MDCHECK_STATE_DIR, MDADM_CONF) and every test builds
# a fake sysfs tree. Nothing here touches the real /proc or /sys.
#
# The tool is published for Debian only and its arithmetic runs on `date -d` and `stat -c`, neither of
# which BSD supports, so the tests that reach those skip on macOS. That is a real gap on one runner rather
# than a hidden one: what is skipped is stated in the skip message.
#
# The report is a wall-clock estimate built from three inputs -- how far the check has got, how much active
# window time that took, and when the next window opens -- so the arithmetic (active_seconds,
# project_finish) is tested directly with fixed epochs, and the report is tested for the decisions it
# makes: which branch it takes, and whether it says "unavailable" rather than inventing a number.

load test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/mdcheck-progress.sh"
  SYSFS="$BATS_TEST_TMPDIR/sys-block"
  STATE="$BATS_TEST_TMPDIR/mdcheck-state"
  MDSTAT_FILE="$BATS_TEST_TMPDIR/mdstat"
  MDADM_CONF_FILE="$BATS_TEST_TMPDIR/mdadm.conf"
  mkdir -p "$SYSFS" "$STATE"
  printf 'Personalities : [raid1]\nunused devices: <none>\n' > "$MDSTAT_FILE"
  : > "$MDADM_CONF_FILE"
}

########################################
# Bounds every test in this file. The projection walks forward window by window until the work fits, so a
# fault in that loop does not fail — it spins, and a spinning test would hold the whole suite open. bats
# arms the timeout before setup runs, which is why it is set here rather than in setup.
#
# BATS_TEST_TIMEOUT needs bats 1.9 or newer, which is why bin/run-coverage.sh installs a pinned bats rather
# than the distribution's 1.8: with 1.8 the bound silently would not exist.
########################################
setup_file() {
  export BATS_TEST_TIMEOUT=60
}

########################################
# Skips the calling test unless GNU date's -d option is available.
########################################
require_gnu_date() {
  date -d "@0" +%s >/dev/null 2>&1 || skip "needs GNU date -d (mdcheck-progress is Linux-only)"
}

########################################
# Skips the calling test unless GNU stat's -c option is available.
########################################
require_gnu_stat() {
  stat -c %Y "$BATS_TEST_TMPDIR" >/dev/null 2>&1 || skip "needs GNU stat -c (mdcheck-progress is Linux-only)"
}

########################################
# Creates a fake MD array in the fixture sysfs tree.
# Arguments:
#   name: Array name, e.g. md0.
#   level: RAID level string.
#   component_size: Per-device size in KiB.
#   sync_action: idle, check, resync…; omit for no sync_action file.
#   sync_completed: "done max" sector pair; omit for none.
########################################
make_array() {
  local name="$1" level="${2:-raid1}" comp="${3:-1000000}" action="${4:-}" completed="${5:-}"
  local md="$SYSFS/$name/md"
  mkdir -p "$md"
  printf '%s\n' "$level" > "$md/level"
  printf '%s\n' "$comp" > "$md/component_size"
  [[ -n "$action" ]] && printf '%s\n' "$action" > "$md/sync_action"
  [[ -n "$completed" ]] && printf '%s\n' "$completed" > "$md/sync_completed"
  return 0
}

########################################
# Writes a checkpoint file holding a saved sector offset.
# Arguments:
#   uuid: The array UUID the file is named for.
#   sectors: The saved offset.
########################################
make_checkpoint() {
  printf '%s\n' "$2" > "$STATE/MD_UUID_$1"
}

########################################
# Registers an array UUID in the fixture mdadm.conf.
# Arguments:
#   device: e.g. /dev/md0.
#   uuid: The UUID to record.
########################################
register_uuid() {
  printf 'ARRAY %s metadata=1.2 UUID=%s name=host:0\n' "$1" "$2" >> "$MDADM_CONF_FILE"
}

########################################
# Gives the systemctl stub a value for one property.
# Arguments:
#   property: e.g. NextElapseUSecRealtime.
#   value: The value to print.
########################################
systemd_property() {
  printf '%s\n' "$2" > "$STUB_FIXTURES/systemctl.$1.stdout"
}

########################################
# Runs the script against the fixture tree.
########################################
mdcheck_run() {
  MDSTAT="$MDSTAT_FILE" SYS_BLOCK="$SYSFS" MDCHECK_STATE_DIR="$STATE" MDADM_CONF="$MDADM_CONF_FILE" \
    run_script "$SCRIPT" -C "$@"
}

########################################
# Evaluates a snippet inside the script against the fixture tree.
########################################
with_fixtures() {
  MDSTAT="$MDSTAT_FILE" SYS_BLOCK="$SYSFS" MDCHECK_STATE_DIR="$STATE" MDADM_CONF="$MDADM_CONF_FILE" \
    run_snippet "$SCRIPT" "$1"
}

# --- Options -----------------------------------------------------------------------------------

@test "--help describes the paused-check problem it solves" {
  mdcheck_run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"paused"* ]]
  [[ "$output" == *"ARRAY"* ]]
}

@test "an unknown option is refused" {
  mdcheck_run --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "an array may be named with or without the /dev prefix" {
  with_fixtures "parse_options md0 /dev/md1; printf '%s\n' \"\${_filters[@]}\""
  [ "${lines[0]}" = "md0" ]
  [ "${lines[1]}" = "md1" ]
}

@test "arguments after -- are taken as array names" {
  with_fixtures "parse_options -- -md9; printf '%s' \"\${_filters[0]}\""
  [ "$output" = "-md9" ]
}

# --- Choosing arrays ---------------------------------------------------------------------------

@test "with no filter every array in sysfs is reported" {
  make_array md0
  make_array md1
  with_fixtures "select_arrays"
  [ "${lines[0]}" = "md0" ]
  [ "${lines[1]}" = "md1" ]
}

# A block device without an md/ directory is not an array, so it must not be enumerated.
@test "a non-MD block device is not enumerated" {
  make_array md0
  mkdir -p "$SYSFS/mdnotarray"
  with_fixtures "select_arrays"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "md0" ]
}

@test "a named array wins over enumeration" {
  make_array md0
  make_array md1
  with_fixtures "_filters=(md1); select_arrays"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "md1" ]
}

@test "a machine with no MD RAID at all is refused" {
  rm -f "$MDSTAT_FILE"
  mdcheck_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires Linux MD RAID"* ]]
}

@test "no arrays found is refused" {
  mdcheck_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"No MD arrays found"* ]]
}

@test "a named array that is not an MD array is reported as such" {
  make_array md0
  mdcheck_run md9
  [[ "$output" == *"md9: not an MD array"* ]]
}

@test "several arrays are separated by a blank line" {
  make_array md0
  make_array md1
  mdcheck_run
  [[ "$output" == *"md0"* ]]
  [[ "$output" == *"md1"* ]]
  run bash -c "printf '%s\n' \"\$1\" | grep -c '^\$'" _ "$output"
  [ "$output" -ge 1 ]
}

# --- Resolving the checkpoint ------------------------------------------------------------------

# A second array is present so the single-array fallback cannot answer: without it, a lookup that ignored
# mdadm.conf entirely would still return the right file and the test would prove nothing.
@test "the checkpoint is found through the array UUID in mdadm.conf" {
  make_array md0
  make_array md1
  register_uuid /dev/md0 "aaaa:bbbb:cccc:dddd"
  make_checkpoint "aaaa:bbbb:cccc:dddd" 500000
  with_fixtures "checkpoint_file md0"
  [ "$output" = "$STATE/MD_UUID_aaaa:bbbb:cccc:dddd" ]
}

@test "the UUID of a different array is not used" {
  make_array md0
  register_uuid /dev/md1 "1111:2222:3333:4444"
  make_checkpoint "1111:2222:3333:4444" 500000
  make_array md1
  with_fixtures "checkpoint_file md0"
  [ -z "$output" ]
}

# With one array and one checkpoint there is no ambiguity, which saves needing root to read mdadm.conf.
@test "a single array and single checkpoint are paired without the config" {
  make_array md0
  make_checkpoint "unknown-uuid" 500000
  with_fixtures "checkpoint_file md0"
  [ "$output" = "$STATE/MD_UUID_unknown-uuid" ]
}

# Two of either makes the pairing a guess, so it must decline rather than report another array's progress.
@test "the fallback declines when there are two arrays" {
  make_array md0
  make_array md1
  make_checkpoint "unknown-uuid" 500000
  with_fixtures "checkpoint_file md0"
  [ -z "$output" ]
}

@test "the fallback declines when there are two checkpoints" {
  make_array md0
  make_checkpoint "uuid-one" 500000
  make_checkpoint "uuid-two" 600000
  with_fixtures "checkpoint_file md0"
  [ -z "$output" ]
}

@test "no checkpoint at all yields nothing" {
  make_array md0
  with_fixtures "checkpoint_file md0"
  [ -z "$output" ]
}

# --- The live speed ----------------------------------------------------------------------------

@test "the live speed is read from the array's own mdstat stanza" {
  printf 'md0 : active raid1 sda1[0]\n      [==>..]  check = 12.0%% (1/2) finish=1.0min speed=120000K/sec\n\n' \
    > "$MDSTAT_FILE"
  with_fixtures "live_speed_sectors md0"
  # 120000 KiB/s over 512-byte sectors.
  [ "$output" = "240000" ]
}

@test "another array's speed is not attributed to this one" {
  {
    printf 'md0 : active raid1 sda1[0]\n      1000 blocks [2/2] [UU]\n\n'
    printf 'md1 : active raid1 sdb1[0]\n      [==>..]  check = 12.0%% speed=99000K/sec\n\n'
  } > "$MDSTAT_FILE"
  with_fixtures "live_speed_sectors md0"
  [ -z "$output" ]
}

@test "an array with no speed reported yields nothing without failing" {
  printf 'md0 : active raid1 sda1[0]\n      1000 blocks [2/2] [UU]\n\n' > "$MDSTAT_FILE"
  with_fixtures "live_speed_sectors md0; echo '[end]'"
  [ "$output" = "[end]" ]
}

# --- The schedule ------------------------------------------------------------------------------

@test "the window length is read from the service environment" {
  require_gnu_date
  systemd_property Environment '"MDADM_CHECK_DURATION=2 hours"'
  with_fixtures "load_schedule; echo \"\$_window_sec\""
  [ "$output" = "7200" ]
}

@test "an unreadable window length falls back to six hours" {
  require_gnu_date
  with_fixtures "load_schedule; echo \"\$_window_sec\""
  [ "$output" = "21600" ]
}

@test "a nonsense window length falls back rather than being used" {
  require_gnu_date
  systemd_property Environment '"MDADM_CHECK_DURATION=not a duration"'
  with_fixtures "load_schedule; echo \"\$_window_sec\""
  [ "$output" = "21600" ]
}

@test "the next window and its time of day come from the timer" {
  require_gnu_date
  systemd_property NextElapseUSecRealtime "Tue 2026-08-04 01:30:00 UTC"
  with_fixtures "load_schedule; echo \"\$_next_window\"; echo \"\$_window_tod\""
  [ "${lines[0]}" = "$(TZ=UTC date -d 'Tue 2026-08-04 01:30:00 UTC' +%s)" ]
  [ "${lines[1]}" = "5400" ]
}

@test "an absent next window leaves the schedule unknown rather than at the epoch" {
  require_gnu_date
  systemd_property NextElapseUSecRealtime "n/a"
  with_fixtures "load_schedule; echo \"\$_next_window\""
  [ "$output" = "0" ]
}

@test "the check start time comes from the start service" {
  require_gnu_date
  systemd_property ExecMainStartTimestamp "Sun 2026-08-02 00:57:00 UTC"
  with_fixtures "load_schedule; echo \"\$_check_start\""
  [ "$output" = "$(TZ=UTC date -d 'Sun 2026-08-02 00:57:00 UTC' +%s)" ]
}

# --- Active-time arithmetic --------------------------------------------------------------------

# The first window starts when the check starts, because mdcheck_start does not wait for the nightly slot.
@test "active_seconds counts from the check start for the first window" {
  require_gnu_date
  local cs
  cs=$(TZ=UTC date -d '2026-08-02 01:00:00 UTC' +%s)
  with_fixtures "_window_sec=3600; _window_tod=3600; active_seconds ${cs} \$(( ${cs} + 600 ))"
  [ "$output" = "600" ]
}

@test "active_seconds stops at the end of a window" {
  require_gnu_date
  local cs
  cs=$(TZ=UTC date -d '2026-08-02 01:00:00 UTC' +%s)
  # Ten hours later, but the window is only one hour long.
  with_fixtures "_window_sec=3600; _window_tod=3600; active_seconds ${cs} \$(( ${cs} + 36000 ))"
  [ "$output" = "3600" ]
}

@test "active_seconds adds a later day's window" {
  require_gnu_date
  local cs
  cs=$(TZ=UTC date -d '2026-08-02 01:00:00 UTC' +%s)
  # Two days on, so the first window plus one full nightly window have elapsed.
  with_fixtures "_window_sec=3600; _window_tod=3600; active_seconds ${cs} \$(( ${cs} + 172800 ))"
  [ "$output" = "7200" ]
}

# Ending half an hour into the next night's window is what pins where that window begins: measured from
# midnight instead of the configured time, the same range would credit a full extra hour.
@test "active_seconds counts only up to the moment inside a later window" {
  require_gnu_date
  local cs
  cs=$(TZ=UTC date -d '2026-08-02 01:00:00 UTC' +%s)
  with_fixtures "_window_sec=3600; _window_tod=3600; active_seconds ${cs} \$(( ${cs} + 86400 + 1800 ))"
  [ "$output" = "5400" ]
}

# Idle daytime hours must not count, or the average speed while checking would be far too low.
@test "active_seconds ignores time outside the windows" {
  require_gnu_date
  local cs
  cs=$(TZ=UTC date -d '2026-08-02 01:00:00 UTC' +%s)
  local one two
  with_fixtures "_window_sec=3600; _window_tod=3600; active_seconds ${cs} \$(( ${cs} + 3600 ))"
  one="$output"
  with_fixtures "_window_sec=3600; _window_tod=3600; active_seconds ${cs} \$(( ${cs} + 43200 ))"
  two="$output"
  [ "$one" = "$two" ]
}

# --- Projecting the finish ---------------------------------------------------------------------

@test "work that fits in the current window finishes inside it" {
  require_gnu_date
  local t
  t=$(TZ=UTC date -d '2026-08-04 01:30:00 UTC' +%s)
  with_fixtures "_window_sec=7200; _window_tod=5400; project_finish 600 ${t}"
  [ "$output" = "$(( t + 600 )) 1" ]
}

@test "work that overflows the window continues in the next one" {
  require_gnu_date
  local t
  t=$(TZ=UTC date -d '2026-08-04 01:30:00 UTC' +%s)
  # An hour of work with half an hour available each night: tonight's window plus tomorrow's finishes it.
  with_fixtures "_window_sec=1800; _window_tod=5400; project_finish 3600 ${t}"
  local expected=$(( t + 86400 + 1800 ))
  [ "${output%% *}" = "$expected" ]
  [ "${output##* }" = "2" ]
}

# Asked to resume in the middle of an idle day, the projection has to wait for the window rather than
# start immediately.
# Resuming before tonight's window opens must wait for it, not start immediately: work cannot happen while
# the check is paused.
@test "work asked to resume before the window opens waits for it" {
  require_gnu_date
  local t
  t=$(TZ=UTC date -d '2026-08-04 00:30:00 UTC' +%s)
  local opens
  opens=$(TZ=UTC date -d '2026-08-04 01:00:00 UTC' +%s)
  with_fixtures "_window_sec=3600; _window_tod=3600; project_finish 600 ${t}"
  [ "${output%% *}" = "$(( opens + 600 ))" ]
}

@test "work asked to resume outside a window waits for the next one" {
  require_gnu_date
  local t
  t=$(TZ=UTC date -d '2026-08-04 12:00:00 UTC' +%s)
  with_fixtures "_window_sec=3600; _window_tod=3600; project_finish 600 ${t}"
  local tomorrow
  tomorrow=$(TZ=UTC date -d '2026-08-05 01:00:00 UTC' +%s)
  [ "${output%% *}" = "$(( tomorrow + 600 ))" ]
}

@test "the window count reflects how many nights are needed" {
  require_gnu_date
  local t
  t=$(TZ=UTC date -d '2026-08-04 01:00:00 UTC' +%s)
  with_fixtures "_window_sec=3600; _window_tod=3600; project_finish 10800 ${t}"
  [ "${output##* }" = "3" ]
}

# --- The report --------------------------------------------------------------------------------

@test "an array with no check in progress says so" {
  make_array md0
  mdcheck_run md0
  [[ "$output" == *"no check in progress"* ]]
}

@test "an active check reports the live position and says it is checking" {
  require_gnu_date
  make_array md0 raid1 1000000 check "500000 1000000"
  printf 'md0 : active raid1 sda1[0]\n      [==>..]  check = 50.0%% speed=100000K/sec\n\n' > "$MDSTAT_FILE"
  mdcheck_run md0
  [[ "$output" == *"monthly check"* ]]
  [[ "$output" == *"50.0%"* ]]
  [[ "$output" == *"checking now"* ]]
  [[ "$output" == *"MB/s (current)"* ]]
}

@test "a paused check reports the checkpoint position and says it is paused" {
  require_gnu_date
  require_gnu_stat
  make_array md0 raid1 1000000 idle
  register_uuid /dev/md0 "uuid-1"
  make_checkpoint "uuid-1" 250000
  mdcheck_run md0
  [[ "$output" == *"12.5%"* ]]
  [[ "$output" == *"paused (idle between nightly windows)"* ]]
}

@test "progress is shown as bytes per device as well as a percentage" {
  require_gnu_date
  require_gnu_stat
  make_array md0 raid1 1048576 idle
  register_uuid /dev/md0 "uuid-1"
  make_checkpoint "uuid-1" 1048576
  mdcheck_run md0
  [[ "$output" == *"512.00 MiB"* ]]
  [[ "$output" == *"1.00 GiB"* ]]
}

@test "a checkpoint holding something other than a number is reported, not used" {
  require_gnu_date
  require_gnu_stat
  make_array md0 raid1 1000000 idle
  register_uuid /dev/md0 "uuid-1"
  printf 'not-a-number\n' > "$STATE/MD_UUID_uuid-1"
  mdcheck_run md0
  [[ "$output" == *"unable to read progress"* ]]
}

@test "a completed check is reported as complete rather than given an estimate" {
  require_gnu_date
  require_gnu_stat
  make_array md0 raid1 1000000 idle
  register_uuid /dev/md0 "uuid-1"
  make_checkpoint "uuid-1" 2000000
  mdcheck_run md0
  [[ "$output" == *"complete"* ]]
}

# With no rate to go on, saying so is the only honest answer; a made-up estimate would be worse than none.
# The two unavailable reasons are asserted apart, or a test could pass on the wrong one.
@test "an unknown rate is admitted rather than estimated" {
  require_gnu_date
  require_gnu_stat
  make_array md0 raid1 1000000 idle
  register_uuid /dev/md0 "uuid-1"
  make_checkpoint "uuid-1" 250000
  mdcheck_run md0
  [[ "$output" == *"est. finish"* ]]
  [[ "$output" == *"cannot determine check rate"* ]]
}

# A rate is available here but no next window is known, so the estimate has nowhere to start. Driven
# through report_array with the schedule globals set, since that combination cannot be produced by
# fixtures alone.
@test "an unknown nightly schedule is admitted rather than estimated" {
  require_gnu_date
  require_gnu_stat
  make_array md0 raid1 1000000 idle
  register_uuid /dev/md0 "uuid-1"
  make_checkpoint "uuid-1" 250000
  local now
  now=$(date +%s)
  with_fixtures "_check_start=$(( now - 7200 )); _window_sec=21600; _window_tod=0; _next_window=0
                 report_array md0"
  [[ "$output" == *"MB/s while checking"* ]]
  [[ "$output" == *"unknown nightly schedule"* ]]
}

# The average is progress divided by the active time it took, not by wall clock. Two hours of window time
# for 250000 sectors is 34 sectors/s, which is 0 MB/s to the nearest whole unit; measured against the raw
# sector count instead the line would read 128 MB/s.
@test "the average rate is measured over active window time" {
  require_gnu_date
  require_gnu_stat
  make_array md0 raid1 1000000 idle
  register_uuid /dev/md0 "uuid-1"
  make_checkpoint "uuid-1" 250000
  local now
  now=$(date +%s)
  with_fixtures "_check_start=$(( now - 7200 )); _window_sec=21600; _window_tod=0; _next_window=0
                 report_array md0"
  [[ "$output" == *"0 MB/s while checking"* ]]
}

@test "the schedule line names the window length and the next window" {
  require_gnu_date
  require_gnu_stat
  make_array md0 raid1 1000000 idle
  register_uuid /dev/md0 "uuid-1"
  make_checkpoint "uuid-1" 250000
  systemd_property Environment '"MDADM_CHECK_DURATION=2 hours"'
  systemd_property NextElapseUSecRealtime "$(date -d 'tomorrow 01:30' +'%a %Y-%m-%d %H:%M:%S %Z')"
  mdcheck_run md0
  [[ "$output" == *"schedule"* ]]
  [[ "$output" == *"2 h nightly"* ]]
  [[ "$output" == *"01:30"* ]]
}

@test "an array missing its size attributes is not an MD array" {
  mkdir -p "$SYSFS/md0/md"
  printf 'raid1\n' > "$SYSFS/md0/md/level"
  mdcheck_run md0
  [[ "$output" == *"not an MD array"* ]]
}

@test "the array's RAID level is shown in the header" {
  make_array md0 raid6 1000000
  mdcheck_run md0
  [[ "$output" == *"md0"*"(raid6)"* ]]
}

#!/usr/bin/env bats
#
# memory-pressure-alert reads live kernel memory state, which cannot be conjured on demand, so every
# reading comes from the environment (SWAPUSAGE_CMD, MEMSIZE_CMD, VMSTAT_CMD, TOP_CMD, NOTIFY_CMD) and
# each test supplies a fixed one. Nothing here reads the real machine, which matters twice over: the real
# values change between runs, and a test that let the notifier default would post to the developer's
# desktop every time the suite ran.
#
# The tool's job is a decision — alert or stay quiet — so the thresholds are tested at their boundaries,
# and the readers are tested for what they do with input they cannot parse. That last part carries weight:
# this runs unattended every few minutes, so a missing reading must read as healthy rather than raise an
# alarm nobody can act on.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/memory-pressure-alert/memory-pressure-alert.sh"
  # Keep the committed .conf out of it: its thresholds would otherwise decide these outcomes.
  CONFIG_FILE="$BATS_TEST_TMPDIR/empty.conf"
  : > "$CONFIG_FILE"
  export CONFIG_FILE
  # A healthy machine unless a test says otherwise.
  # Seams are commands, and a command string is word-split — so quoted arguments
  # cannot survive one. Every fixture is therefore a file read with `cat`.
  FIX="$BATS_TEST_TMPDIR"
  printf 'total = 0.00M used = 0.00M free = 0.00M\n' > "$FIX/swap"
  # 16 GB installed, and a sample that is busy but not alarming: 4 GB anonymous of 16 GB is 25% used.
  printf '17179869184\n' > "$FIX/memsize"
  write_vmstat 262144 0 0 0 0 0
  : > "$FIX/top"
  export SWAPUSAGE_CMD="cat $FIX/swap"
  export MEMSIZE_CMD="cat $FIX/memsize"
  export VMSTAT_CMD="cat $FIX/vmstat"
  export TOP_CMD="cat $FIX/top"
  export NOTIFY_CMD=true
}

# Writes a vm_stat sample with the page counts that decide the used percentage. Every figure has to
# come from one sample, so they are written together rather than patched in one at a time.
# Arguments:
#   active, inactive, wired, compressor, purgeable, file-backed — in pages.
write_vmstat() {
  cat > "$FIX/vmstat" <<VMSTAT
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                     1000.
Pages active:                                   $1.
Pages inactive:                                 $2.
Pages speculative:                                 0.
Pages throttled:                                   0.
Pages wired down:                               $3.
Pages purgeable:                                $5.
File-backed pages:                              $6.
Pages occupied by compressor:                   $4.
VMSTAT
}

########################################
# Readings
########################################

@test "read_swap_mb parses the used figure from vm.swapusage" {
  printf 'total = 84992.00M used = 83579.88M free = 388.12M  (encrypted)\n' > "$FIX/swap"
  run_func "$SCRIPT" read_swap_mb
  [ "$status" -eq 0 ]
  [ "$output" = "83580" ]
}

@test "read_swap_mb reports zero rather than failing when swap is unreadable" {
  # Runs unattended: an unparseable reading must not look like an emergency.
  printf 'nonsense\n' > "$FIX/swap"
  run_func "$SCRIPT" read_swap_mb
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "read_used treats an unreadable total as healthy" {
  # Zero is the healthy end of this reading, and both forms have to say so: a size beside a nil
  # percentage would read as a machine that is full but somehow at ease.
  printf 'not-a-number\n' > "$FIX/memsize"
  run_func "$SCRIPT" read_used
  [ "$status" -eq 0 ]
  [ "$output" = "0 0" ]
}

@test "read_used reports the percentage and the size from one sample" {
  # 2 GB anonymous plus 10 GB compressed of 16 GB installed.
  write_vmstat 131072 0 0 655360 0 0
  run_func "$SCRIPT" read_used
  [ "$status" -eq 0 ]
  [ "$output" = "75 12288" ]
}

@test "read_used reports a size the percentage cannot be rounded back into" {
  # 8354 MB of 16384 is 50.99%, and 50% of 16384 is 8192 — so this sample is only reported correctly by
  # a size that came from the page counts. The reading stays in MB whatever the display does with it.
  write_vmstat 534656 0 0 0 0 0
  run_func "$SCRIPT" read_used
  [ "$status" -eq 0 ]
  [ "$output" = "50 8354" ]
}

@test "read_total_mb converts the installed byte count to whole MB" {
  run_func "$SCRIPT" read_total_mb
  [ "$status" -eq 0 ]
  [ "$output" = "16384" ]
}

@test "read_total_mb reports zero rather than failing when the total is unreadable" {
  # It is the denominator of every share, so an unreadable total has to leave those at zero rather
  # than divide by it.
  printf 'not-a-number\n' > "$FIX/memsize"
  run_func "$SCRIPT" read_total_mb
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "percent_of_ram is zero when the installed total is unknown" {
  # Reached whenever hw.memsize cannot be read, and a division by zero there would kill the run under
  # errexit — turning an unreadable reading into a failing agent rather than a quiet one.
  run_func "$SCRIPT" percent_of_ram 4096 0
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "percent_of_ram takes the share of installed memory" {
  run_func "$SCRIPT" percent_of_ram 4096 16384
  [ "$status" -eq 0 ]
  [ "$output" = "25" ]
}

@test "read_compressor_mb converts pages using the page size vm_stat states" {
  # Page size differs between Intel and Apple silicon, so it is read back rather than assumed.
  printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages occupied by compressor: 65536.\n' > "$FIX/vmstat"
  run_func "$SCRIPT" read_compressor_mb
  [ "$status" -eq 0 ]
  [ "$output" = "1024" ]
}

@test "read_compressor_mb reports zero when vm_stat says nothing about the compressor" {
  run_func "$SCRIPT" read_compressor_mb
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

########################################
# The alert decision
########################################

@test "raises nothing and exits 0 while every reading is healthy" {
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 0 ]
  # Not an empty-output assertion: load_optional_config logs the file it read.
  # What must be absent is any alert.
  [[ "$output" != *"swap "* ]]
  [[ "$output" != *"used "* ]]
  [[ "$output" != *"Heaviest"* ]]
}

@test "alerts on swap alone, before memory use has risen at all" {
  # The whole point: swap is the leading indicator, so it must fire on its own.
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"swap 2.9 GB"* ]]
}

@test "does not alert just below the swap threshold" {
  printf 'total = 4096.00M used = 2047.00M free = 2049.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 0 ]
}

@test "alerts exactly at the swap threshold" {
  printf 'total = 4096.00M used = 2048.00M free = 2048.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
}

@test "alerts when memory use reaches the threshold" {
  # 85% of 16 GB is 13.6 GB; 892928 pages of 16 KB is exactly that.
  write_vmstat 892928 0 0 0 0 0
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"used 85%"* ]]
}

@test "alerts on compressed memory as a share of installed RAM" {
  write_vmstat 131072 0 0 655360 0 0
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"⚠ compressed 62%"* ]]
  # The share is what the threshold is compared against, so the same 10 GB has to raise the alert on a
  # 16 GB machine and stay quiet on a 64 GB one — which a fixed size in MB could not do.
  [[ "$output" != *"⚠ used"* ]]
}

@test "the same compressed size stays quiet on a machine with more RAM" {
  # The whole reason the threshold is a share: 10 GB compressed of 64 GB is 15%, which is a machine
  # coping, where the same figure on a 16 GB machine is one running out of room to squeeze.
  printf '68719476736\n' > "$FIX/memsize"
  write_vmstat 131072 0 0 655360 0 0
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 0 ]
}

@test "thresholds are configurable from the command line" {
  printf 'total = 4096.00M used = 100.00M free = 3996.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --no-notify --swap-mb 50
  [ "$status" -eq 2 ]
  # The threshold is set in MB and the reading is shown in GB: the two units are not the same, so the
  # display has to convert rather than echo the number the flag was given.
  [[ "$output" == *"swap 0.1 GB"* ]]
}

@test "an explicit flag beats the config file" {
  # The config is loaded after the options are parsed, so a flag written straight
  # into the config global would be silently overwritten by the file.
  printf 'COMPRESSOR_WARN_PERCENT=99\n' > "$CONFIG_FILE"
  write_vmstat 131072 0 0 655360 0 0
  run_script "$SCRIPT" --no-notify --compressor 10
  [ "$status" -eq 2 ]
  [[ "$output" == *"⚠ compressed 62%"* ]]
}

@test "the config file applies when no flag overrides it" {
  printf 'COMPRESSOR_WARN_PERCENT=10\n' > "$CONFIG_FILE"
  write_vmstat 131072 0 0 655360 0 0
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
}

@test "reports every crossed threshold, not just the first" {
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  write_vmstat 1000000 0 0 0 0 0
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"swap 2.9 GB"* ]]
  [[ "$output" == *"used 95%"* ]]
}

@test "an alert carries every reading, not only the one that crossed" {
  # A single reading cannot be acted on: 62% compressed means nothing until the reader also knows that
  # swap is empty and memory is three quarters full, which is the difference between a machine coping
  # and a machine about to stall.
  write_vmstat 131072 0 0 655360 0 0
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"used 75%"* ]]
  [[ "$output" == *"swap 0.0 GB"* ]]
  [[ "$output" == *"compressed 62%"* ]]
}

@test "an alert gives one form of each figure, the one its threshold is written in" {
  # A notification is read at a glance and truncated on a lock screen, so the second form of every
  # figure would crowd out the application names that say what to close.
  write_vmstat 131072 0 0 655360 0 0
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"used 75% · swap 0.0 GB · ⚠ compressed 62%."* ]]
  [[ "$output" != *"12.0 GB"* ]]
  [[ "$output" != *"10.0 GB"* ]]
}

@test "only the reading that crossed its threshold is marked" {
  # The mark is what tells the reader which figure raised the alert, since all three are reported
  # whatever their values; marking the wrong one would point at an innocent reading.
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"⚠ swap 2.9 GB"* ]]
  [[ "$output" != *"⚠ used"* ]]
  [[ "$output" != *"⚠ compressed"* ]]
}

@test "the readings lead with memory used and swap, and compressed comes last" {
  # Ordered for a reader looking at a notification cold: the two figures that need no explanation
  # first, the one that does last.
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"used 25% · ⚠ swap 2.9 GB · compressed 0%"* ]]
}

@test "--report marks a reading that crossed its threshold" {
  # The report and the alert judge the readings once, together, so a report cannot show a figure as
  # unremarkable that the very next scheduled run alerts on.
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ swap 2.9 GB"* ]]
}

@test "--report leaves the readings unmarked while every one is healthy" {
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"used 25% (4.0 GB) · swap 0.0 GB (0%) · compressed 0% (0.0 GB)"* ]]
}

@test "--report gives both forms of every figure" {
  # Read deliberately rather than glanced at, so it has the room for the share and the size of each
  # reading. Every one of the six figures here differs, so a pair reported against the wrong reading
  # cannot pass.
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  write_vmstat 131072 0 0 655360 0 0
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"used 75% (12.0 GB) · ⚠ swap 2.9 GB (18%) · ⚠ compressed 62% (10.0 GB)"* ]]
}

@test "--report shows a size taken from the sample, not one rebuilt from the percentage" {
  # The two forms sit side by side here, so a size rebuilt from the truncated share would be visibly
  # wrong. The fixture is chosen for the gap to survive rounding to a tenth of a GB: 8354 MB is 50.99%
  # of 16 GB, and 50% of 16 GB is 8192 MB — 8.2 GB against 8.0 GB.
  write_vmstat 534656 0 0 0 0 0
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"used 50% (8.2 GB)"* ]]
}

@test "--report gives the heaviest applications as sizes and shares" {
  printf 'COMMAND  MEM  CMPRS\nChrome  1024M  1024M\nSlack  256M  256M\n' > "$FIX/top"
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"2.0 GB   12%    1 proc  Chrome"* ]]
  [[ "$output" == *"0.5 GB    3%    1 proc  Slack"* ]]
}

########################################
# Naming the cause
########################################

@test "blames the application by resident plus compressed, aggregated over its processes" {
  # A browser's helpers each report a small resident size while holding most of the
  # footprint compressed, so resident alone would blame the wrong process.
  printf 'Processes: 400 total\nCOMMAND  MEM  CMPRS\nChrome  200M  1200M\nChrome  180M  1100M\nidle     10M    5M\n' > "$FIX/top"
  run_func "$SCRIPT" read_top_offenders
  [ "$status" -eq 0 ]
  # 200+1200+180+1100 MB over two processes.
  [[ "${lines[0]}" == "2680 2 Chrome" ]]
}

@test "top's changed-value suffixes do not corrupt the totals" {
  printf 'COMMAND  MEM  CMPRS\nSlack  512M+  256M-\n' > "$FIX/top"
  run_func "$SCRIPT" read_top_offenders
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "768 1 Slack" ]]
}

@test "the alert names the heaviest application, as a share of RAM" {
  # A share rather than a size, for the same reason the readings are: it says whether the application
  # is the cause without the reader having to remember how much memory the machine has.
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  printf 'COMMAND  MEM  CMPRS\nChrome  2048M  6144M\nSlack  256M  256M\n' > "$FIX/top"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"Heaviest: Chrome 50%; Slack 3%"* ]]
}

@test "the alert says so rather than naming nothing when no application can be read" {
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  : > "$FIX/top"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"Heaviest: unknown"* ]]
}

########################################
# Reporting and the CLI
########################################

@test "--report prints the readings and exits 0 even when a threshold is crossed" {
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"swap 2.9 GB"* ]]
  [[ "$output" == *"used 25%"* ]]
}

@test "a failed notification does not hide the condition" {
  # Under real pressure osascript is itself liable to be refused; the exit code
  # still has to say a threshold was crossed.
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  export NOTIFY_CMD=false
  run_script "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "the alert is logged as a warning, not an error" {
  # The tool has not failed when a machine fills up: it has done its job. ERROR would say the script
  # itself broke, and a red line for a working tool teaches its reader to ignore the next one.
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"[WARN]:"* ]]
  [[ "$output" != *"[ERROR]:"* ]]
}

@test "sizes are rendered in gigabytes, never as five digits of megabytes" {
  # 25450 MB has to be read digit by digit before it says anything; 24.9 GB does not.
  printf 'total = 65536.00M used = 25450.00M free = 40086.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"swap 24.9 GB"* ]]
  [[ "$output" != *"25450"* ]]
}

@test "a size in MB passed to the compressor threshold is refused, not silently ignored" {
  # The habit a size leaves behind: 8192 as a percentage can never be reached, so it would disable the
  # reading entirely and look exactly like a machine that never fills up.
  run_script "$SCRIPT" --no-notify --compressor 8192
  [ "$status" -eq 1 ]
  [[ "$output" == *"percentage from 0 to 100"* ]]
}

@test "a percentage threshold above 100 is refused wherever it was set" {
  run_script "$SCRIPT" --no-notify --used 150
  [ "$status" -eq 1 ]
  printf 'COMPRESSOR_WARN_PERCENT=200\n' > "$CONFIG_FILE"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 1 ]
}

@test "a percentage threshold that is not a whole number is refused" {
  run_script "$SCRIPT" --no-notify --compressor 62.5
  [ "$status" -eq 1 ]
  run_script "$SCRIPT" --no-notify --compressor abc
  [ "$status" -eq 1 ]
}

@test "a threshold of exactly 100 percent is allowed" {
  # Reachable, since the used reading is clamped there — so it means "only when memory is entirely
  # accounted for", which is a legitimate if severe choice.
  write_vmstat 2000000 2000000 0 0 0 0
  run_script "$SCRIPT" --no-notify --used 100 --compressor 100
  [ "$status" -eq 2 ]
  [[ "$output" == *"⚠ used 100%"* ]]
}

@test "--help exits 0 and describes the options" {
  run_script "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--swap-mb"* ]]
  [[ "$output" == *"--report"* ]]
}

@test "--help explains what each reading means, compressed included" {
  # "compressed 62%" is unreadable without it, and the help is the only place the tool can say what the
  # figure is before someone decides whether to worry about it. The part that matters most is that it
  # is not consumption on top of the used figure, which is what makes a large number look alarming.
  run_script "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Readings:"* ]]
  [[ "$output" == *"compressed"* ]]
  [[ "$output" == *"already part of"* ]]
}

@test "an unknown option is a usage error" {
  run_script "$SCRIPT" --nope
  # 1 is cli.sh's die_usage; a raised threshold uses 2 so the two stay distinct.
  [ "$status" -eq 1 ]
}

@test "an option missing its value is a usage error" {
  run_script "$SCRIPT" --swap-mb
  [ "$status" -eq 1 ]
}

########################################
# launchd agent installation
#
# --install writes into the user's real LaunchAgents directory and loads the agent for real, so
# LAUNCHCTL_CMD, LAUNCH_AGENTS_DIR and AGENT_LOG_DIR are seams and every test here redirects all
# three. A stub launchctl records its arguments to a file, because the order of unload and load is
# the whole of the idempotence contract and is invisible in the resulting plist.
########################################

# Points the installer at the test's own directories and a launchctl that records rather than acts.
# Arguments:
#   $1 - exit status the stub returns for `load` (default 0).
stub_launchctl() {
  local load_status=${1:-0}
  CALLS="$BATS_TEST_TMPDIR/launchctl.calls"
  : > "$CALLS"
  cat > "$BATS_TEST_TMPDIR/launchctl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${CALLS}"
[[ \$1 == load ]] && exit ${load_status}
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/launchctl"
  export LAUNCHCTL_CMD="$BATS_TEST_TMPDIR/launchctl"
  export LAUNCH_AGENTS_DIR="$BATS_TEST_TMPDIR/agents"
  export AGENT_LOG_DIR="$BATS_TEST_TMPDIR/logs"
  PLIST="$LAUNCH_AGENTS_DIR/si.merhar.memory-pressure-alert.plist"
}

@test "--install writes a plist and loads it" {
  stub_launchctl
  run_script "$SCRIPT" --install
  [ "$status" -eq 0 ]
  [ -f "$PLIST" ]
  grep -q '<key>Label</key>.*si.merhar.memory-pressure-alert' "$PLIST"
  grep -q '<key>RunAtLoad</key>' "$PLIST"
  grep -q "^load ${PLIST}$" "$CALLS"
}

@test "--install defaults to a five-minute interval" {
  stub_launchctl
  run_script "$SCRIPT" --install
  [ "$status" -eq 0 ]
  grep -q '<key>StartInterval</key>.*<integer>300</integer>' "$PLIST"
}

@test "--install honours an explicit interval" {
  stub_launchctl
  run_script "$SCRIPT" --install --interval 60
  [ "$status" -eq 0 ]
  grep -q '<key>StartInterval</key>.*<integer>60</integer>' "$PLIST"
}

@test "--install unloads any running agent before loading the new one" {
  # Reinstalling is how the interval is changed, and launchd keeps running the plist it loaded, so
  # rewriting the file without unloading first would leave the old interval in force.
  stub_launchctl
  run_script "$SCRIPT" --install --interval 60
  [ "$status" -eq 0 ]
  [ "$(sed -n '1s/ .*//p' "$CALLS")" = "unload" ]
  [ "$(sed -n '2s/ .*//p' "$CALLS")" = "load" ]
}

@test "--install creates the LaunchAgents directory when it does not exist" {
  stub_launchctl
  [ ! -d "$LAUNCH_AGENTS_DIR" ]
  run_script "$SCRIPT" --install
  [ "$status" -eq 0 ]
  [ -d "$LAUNCH_AGENTS_DIR" ]
}

@test "--install passes no thresholds to the agent" {
  # Thresholds belong to the config file, which the agent reads at every run; baking them into the
  # plist would mean reinstalling the agent to change one.
  stub_launchctl
  run_script "$SCRIPT" --install --interval 60
  [ "$status" -eq 0 ]
  # Asserted on the ProgramArguments line itself, and by counting occurrences rather than lines: the
  # whole array is written on one line, so a line count cannot see a second argument appear on it.
  run sed -n 's/.*<key>ProgramArguments<\/key> *//p' "$PLIST"
  [ "$(printf '%s' "$output" | grep -o '<string>' | wc -l | tr -d ' ')" = "1" ]
}

@test "--install names the invoked path, not a resolved symlink target" {
  # Homebrew installs a symlink into the versioned Cellar; an agent pointed at the resolved target
  # would break at the next version bump, so the symlink is what the plist must name.
  #
  # The symlink gets the directory layout the script expects rather than sitting in a bare temporary
  # directory, because the in-repo copy sources its libraries at ../../lib relative to its own
  # location — the published single-file form inlines them, so this constraint is the test harness's
  # alone and says nothing about how the installed tool behaves.
  stub_launchctl
  local link_dir="$BATS_TEST_TMPDIR/tree/scripts/system/tool"
  mkdir -p "$link_dir"
  ln -s "$REPO_ROOT/scripts/lib" "$BATS_TEST_TMPDIR/tree/scripts/lib"
  ln -s "$SCRIPT" "$link_dir/mpa.sh"

  run_script "$link_dir/mpa.sh" --install
  [ "$status" -eq 0 ]
  # The invoked basename survives; the symlink's target does not appear.
  grep -q '/mpa\.sh</string>' "$PLIST"
  ! grep -q 'memory-pressure-alert\.sh</string>' "$PLIST"
}

@test "--install reports failure when launchd refuses to load the agent" {
  stub_launchctl 1
  run_script "$SCRIPT" --install
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused to load"* ]]
  # The plist is left behind on purpose: it is what the user needs to inspect to find out why.
  [ -f "$PLIST" ]
}

@test "--uninstall unloads the agent and removes its plist" {
  stub_launchctl
  run_script "$SCRIPT" --install
  [ "$status" -eq 0 ]
  : > "$CALLS"
  run_script "$SCRIPT" --uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$PLIST" ]
  grep -q "^unload ${PLIST}$" "$CALLS"
}

@test "--uninstall succeeds quietly when no agent is installed" {
  stub_launchctl
  run_script "$SCRIPT" --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not installed"* ]]
  # Nothing to stop, so launchctl is not called at all.
  [ ! -s "$CALLS" ]
}

@test "--install and --uninstall together are a usage error" {
  stub_launchctl
  run_script "$SCRIPT" --install --uninstall
  [ "$status" -eq 1 ]
  [ ! -f "$PLIST" ]
}

@test "--interval outside an install is a usage error" {
  # Silently ignoring it would let someone believe they had changed the agent's schedule.
  stub_launchctl
  run_script "$SCRIPT" --interval 60
  [ "$status" -eq 1 ]
}

@test "--install rejects an interval that is not a positive whole number" {
  # launchd accepts a nonsensical StartInterval by ignoring the key, leaving an agent that runs only
  # at load — so this has to be refused here rather than discovered later.
  stub_launchctl
  run_script "$SCRIPT" --install --interval 0
  [ "$status" -eq 1 ]
  run_script "$SCRIPT" --install --interval abc
  [ "$status" -eq 1 ]
  run_script "$SCRIPT" --install --interval -5
  [ "$status" -eq 1 ]
  [ ! -f "$PLIST" ]
}

@test "--help describes the install options" {
  run_script "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--install"* ]]
  [[ "$output" == *"--uninstall"* ]]
  [[ "$output" == *"--interval"* ]]
}

# The kernel's memorystatus level counts active pages as available, so it reads near 70% on a machine
# with a few hundred MB genuinely unused. Calling it "free" in the output invites the reader to
# conclude the opposite of what the number means, which is worse than not reporting it.
@test "used memory is counted as Activity Monitor counts it, not as total minus free" {
  # 8 GB anonymous plus 1 GB wired plus 2 GB compressed, less the 4 GB of file cache and 1 GB
  # purgeable the kernel can reclaim, is 6 GB of 16 GB — 37%. The reclaimable pages are the whole
  # point: counting total minus free would report 99% here and never move.
  write_vmstat 524288 0 65536 131072 65536 262144
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"used 37%"* ]]
  [[ "$output" != *"free"* ]]
}

@test "read_used reports zero when the sample carries no page size" {
  # The counts are pages, so without the page size they cannot be turned into bytes at all. The
  # sample therefore carries real counts: assuming a page size instead of refusing would convert them
  # against a guess, and on the wrong architecture that is a figure twice or half the truth.
  printf 'Pages active: 500000.\nPages wired down: 100000.\n' > "$FIX/vmstat"
  run_func "$SCRIPT" read_used
  [ "$status" -eq 0 ]
  [ "$output" = "0 0" ]
}

@test "read_used never exceeds the installed total, in either form" {
  # The kernel keeps moving pages while a sample is taken, so the parts can add to more than the
  # installed total. Both forms are clamped from the same byte count, so a report cannot show 100% of
  # 16 GB beside a size larger than the machine has.
  write_vmstat 2000000 2000000 0 0 0 0
  run_func "$SCRIPT" read_used
  [ "$status" -eq 0 ]
  [ "$output" = "100 16384" ]
}

@test "read_used floors at zero when the cache exceeds anonymous memory" {
  # Subtracting the reclaimable pages could otherwise go negative, which would read as healthy by
  # accident rather than by decision.
  write_vmstat 1000 0 0 0 500000 500000
  run_func "$SCRIPT" read_used
  [ "$status" -eq 0 ]
  [ "$output" = "0 0" ]
}

@test "a config still setting the retired free-memory threshold is told so" {
  # The threshold inverted its meaning, so silently dropping the old key would leave the user
  # believing a limit was in force that is not.
  printf 'PRESSURE_WARN_PERCENT=25\n' > "$CONFIG_FILE"
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRESSURE_WARN_PERCENT is no longer read"* ]]
  [[ "$output" == *"USED_WARN_PERCENT"* ]]
}

@test "a config still setting the compressor threshold as a size is told so" {
  # Same trap in the other direction: 8192 read as a percentage is a threshold nothing reaches, so the
  # key has to be refused rather than quietly dropped.
  printf 'COMPRESSOR_WARN_MB=8192\n' > "$CONFIG_FILE"
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPRESSOR_WARN_MB is no longer read"* ]]
  [[ "$output" == *"COMPRESSOR_WARN_PERCENT"* ]]
}

@test "both retired keys are reported, not just the first" {
  printf 'PRESSURE_WARN_PERCENT=25\nCOMPRESSOR_WARN_MB=8192\n' > "$CONFIG_FILE"
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  # Counted on the [ERROR]: prefix, since GITHUB_ACTIONS makes log_error print its message twice.
  [ "$(printf '%s\n' "$output" | grep -c '\[ERROR\]:')" -eq 2 ]
}

@test "a path containing XML metacharacters still yields a well-formed plist" {
  # The paths come from $0 and $HOME, so they are not this script's to choose: an ampersand in a
  # directory name is legal on macOS and would otherwise produce XML launchd refuses outright.
  stub_launchctl
  export AGENT_LOG_DIR="$BATS_TEST_TMPDIR/a & b <logs>"
  run_script "$SCRIPT" --install
  [ "$status" -eq 0 ]
  grep -q 'a &amp; b &lt;logs&gt;' "$PLIST"
  [[ "$(grep -c ' & ' "$PLIST")" = "0" ]]
}

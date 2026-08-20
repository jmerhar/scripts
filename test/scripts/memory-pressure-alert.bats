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

@test "read_used_percent treats an unreadable total as healthy" {
  # Zero is the healthy end of this reading, where the old free-memory figure had 100.
  printf 'not-a-number\n' > "$FIX/memsize"
  run_func "$SCRIPT" read_used_percent
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
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
  [[ "$output" == *"swap 3000 MB"* ]]
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
  [[ "$output" == *"85% memory used"* ]]
}

@test "alerts on compressed memory" {
  printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages occupied by compressor: 1048576.\n' > "$FIX/vmstat"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"16384 MB compressed"* ]]
}

@test "thresholds are configurable from the command line" {
  printf 'total = 4096.00M used = 100.00M free = 3996.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --no-notify --swap-mb 50
  [ "$status" -eq 2 ]
  [[ "$output" == *"swap 100 MB"* ]]
}

@test "an explicit flag beats the config file" {
  # The config is loaded after the options are parsed, so a flag written straight
  # into the config global would be silently overwritten by the file.
  printf 'COMPRESSOR_WARN_MB=999999\n' > "$CONFIG_FILE"
  printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages occupied by compressor: 65536.\n' > "$FIX/vmstat"
  run_script "$SCRIPT" --no-notify --compressor 512
  [ "$status" -eq 2 ]
  [[ "$output" == *"1024 MB compressed"* ]]
}

@test "the config file applies when no flag overrides it" {
  printf 'COMPRESSOR_WARN_MB=512\n' > "$CONFIG_FILE"
  printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages occupied by compressor: 65536.\n' > "$FIX/vmstat"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
}

@test "reports every crossed threshold, not just the first" {
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  write_vmstat 1000000 0 0 0 0 0
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"swap 3000 MB"* ]]
  [[ "$output" == *"95% memory used"* ]]
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

@test "the alert names the heaviest application" {
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  printf 'COMMAND  MEM  CMPRS\nChrome  2048M  20480M\n' > "$FIX/top"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"Chrome"* ]]
}

########################################
# Reporting and the CLI
########################################

@test "--report prints the readings and exits 0 even when a threshold is crossed" {
  printf 'total = 4096.00M used = 3000.00M free = 1096.00M\n' > "$FIX/swap"
  run_script "$SCRIPT" --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"swap 3000 MB"* ]]
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

@test "--help exits 0 and describes the options" {
  run_script "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--swap-mb"* ]]
  [[ "$output" == *"--report"* ]]
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

@test "read_used_percent reports zero when the sample carries no page size" {
  # The counts are pages, so without the page size they cannot be turned into bytes at all. The
  # sample therefore carries real counts: assuming a page size instead of refusing would convert them
  # against a guess, and on the wrong architecture that is a figure twice or half the truth.
  printf 'Pages active: 500000.\nPages wired down: 100000.\n' > "$FIX/vmstat"
  run_func "$SCRIPT" read_used_percent
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "read_used_percent never exceeds 100 percent" {
  # The kernel keeps moving pages while a sample is taken, so the parts can add to more than the
  # installed total; a figure above 100 would be nonsense on a dashboard.
  write_vmstat 2000000 2000000 0 0 0 0
  run_func "$SCRIPT" read_used_percent
  [ "$status" -eq 0 ]
  [ "$output" = "100" ]
}

@test "read_used_percent floors at zero when the cache exceeds anonymous memory" {
  # Subtracting the reclaimable pages could otherwise go negative, which would read as healthy by
  # accident rather than by decision.
  write_vmstat 1000 0 0 0 500000 500000
  run_func "$SCRIPT" read_used_percent
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
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

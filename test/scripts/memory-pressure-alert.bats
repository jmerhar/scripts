#!/usr/bin/env bats
#
# memory-pressure-alert reads live kernel memory state, which cannot be conjured on demand, so every
# reading comes from the environment (SWAPUSAGE_CMD, PRESSURE_CMD, VMSTAT_CMD, TOP_CMD, NOTIFY_CMD) and
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
  printf '80\n' > "$FIX/pressure"
  : > "$FIX/vmstat"
  : > "$FIX/top"
  export SWAPUSAGE_CMD="cat $FIX/swap"
  export PRESSURE_CMD="cat $FIX/pressure"
  export VMSTAT_CMD="cat $FIX/vmstat"
  export TOP_CMD="cat $FIX/top"
  export NOTIFY_CMD=true
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

@test "read_free_percent treats an unreadable level as healthy" {
  printf 'not-a-number\n' > "$FIX/pressure"
  run_func "$SCRIPT" read_free_percent
  [ "$status" -eq 0 ]
  [ "$output" = "100" ]
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
  [[ "$output" != *"free."* ]]
  [[ "$output" != *"Heaviest"* ]]
}

@test "alerts on swap alone, before free memory has fallen at all" {
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

@test "alerts when free memory falls to the threshold" {
  printf '25\n' > "$FIX/pressure"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"only 25% free"* ]]
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
  printf '10\n' > "$FIX/pressure"
  run_script "$SCRIPT" --no-notify
  [ "$status" -eq 2 ]
  [[ "$output" == *"swap 3000 MB"* ]]
  [[ "$output" == *"only 10% free"* ]]
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
  [[ "$output" == *"free 80%"* ]]
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

#!/usr/bin/env bats
#
# scripts/lib/common.sh is inlined into nine published scripts, so a regression here ships everywhere
# at once. Its behaviour is also almost entirely $0-derived — SCRIPT_NAME, the install prefix and the
# config search path all come from it — so most tests here place a copy of the library at a chosen
# path and source that, which is the only way to exercise those branches.

load test_helper

setup() { setup_common; }

########################################
# Places a copy of the shared library at <dir>/<name>.sh inside the test's temp directory and prints
# its path. Sourcing that copy is what lets a test choose $0, and with it SCRIPT_NAME, the config
# search path and the detected install prefix.
# Arguments:
#   dir: Directory relative to BATS_TEST_TMPDIR.
#   name: Basename without the .sh suffix; becomes SCRIPT_NAME.
# Outputs:
#   Prints the absolute path of the copy.
########################################
lib_copy() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir"
  cp "$LIB" "$dir/$2.sh"
  printf '%s' "$dir/$2.sh"
}

# --- Script identity -------------------------------------------------------------------------

@test "SCRIPT_NAME defaults to the script's basename without the extension" {
  run_snippet "$(lib_copy bin widget)" 'echo "$SCRIPT_NAME"'
  [ "$status" -eq 0 ]
  [ "$output" = "widget" ]
}

@test "SCRIPT_NAME honours a value set before sourcing" {
  SCRIPT_NAME=chosen run_snippet "$LIB" 'echo "$SCRIPT_NAME"'
  [ "$output" = "chosen" ]
}

@test "SCRIPT_NAME cannot be reassigned after sourcing" {
  run_snippet "$LIB" 'SCRIPT_NAME=other'
  [ "$status" -ne 0 ]
  [[ "$output" == *"readonly"* ]]
}

@test "sourcing the library twice is harmless" {
  run_snippet "$LIB" "source '$LIB'; echo twice-ok"
  [ "$status" -eq 0 ]
  [ "$output" = "twice-ok" ]
}

# --- get_script_prefix -----------------------------------------------------------------------

@test "get_script_prefix returns the parent of a bin directory" {
  local tool; tool=$(lib_copy usr/bin mytool)
  run_func "$tool" get_script_prefix
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$BATS_TEST_TMPDIR/usr" && pwd -P)" ]
}

@test "get_script_prefix returns the parent of an sbin directory" {
  local tool; tool=$(lib_copy usr/sbin mytool)
  run_func "$tool" get_script_prefix
  [ "$output" = "$(cd "$BATS_TEST_TMPDIR/usr" && pwd -P)" ]
}

@test "get_script_prefix returns nothing outside bin or sbin" {
  local tool; tool=$(lib_copy opt/tools mytool)
  run_func "$tool" get_script_prefix
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "get_script_prefix is not fooled by a directory merely ending in bin" {
  local tool; tool=$(lib_copy opt/sbin-like mytool)
  run_func "$tool" get_script_prefix
  [ -z "$output" ]
}

# --- load_config -----------------------------------------------------------------------------

@test "load_config reads a config beside the script" {
  local tool; tool=$(lib_copy opt/tools mytool)
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$status" -eq 0 ]
  [ "$output" = "beside" ]
}

@test "load_config falls back to the install prefix's etc directory" {
  local tool; tool=$(lib_copy usr/bin mytool)
  mkdir -p "$BATS_TEST_TMPDIR/usr/etc"
  echo 'VAL=prefix' > "$BATS_TEST_TMPDIR/usr/etc/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "prefix" ]
}

@test "load_config prefers the config beside the script over the prefix one" {
  local tool; tool=$(lib_copy usr/bin mytool)
  mkdir -p "$BATS_TEST_TMPDIR/usr/etc"
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/usr/bin/mytool.conf"
  echo 'VAL=prefix' > "$BATS_TEST_TMPDIR/usr/etc/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "beside" ]
}

@test "load_config reports which file it read" {
  local tool; tool=$(lib_copy opt/tools mytool)
  echo 'VAL=x' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_func "$tool" load_config
  [[ "$output" == *"Loading configuration from: "*"/opt/tools/mytool.conf" ]]
}

@test "load_config fails when no config exists anywhere" {
  # A deliberately improbable name, so the /etc fallback cannot accidentally match.
  local tool; tool=$(lib_copy opt/tools lib-common-bats-absent-tool)
  run_func "$tool" load_config
  [ "$status" -eq 1 ]
}

@test "load_config tolerates a config that reads an unset variable" {
  local tool; tool=$(lib_copy opt/tools mytool)
  printf 'VAL="${NOT_DEFINED_ANYWHERE:-}fallback"\n' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'set -o nounset; load_config >/dev/null; echo "$VAL"'
  [ "$status" -eq 0 ]
  [ "$output" = "fallback" ]
}

@test "load_config restores nounset after reading a config" {
  # load_config relaxes nounset around `source` so a config may reference unset variables; the
  # setting must be back on afterwards. Probed in a subshell so the abort does not become this
  # test's own exit status.
  local tool; tool=$(lib_copy opt/tools mytool)
  echo 'VAL=x' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'set -o nounset; load_config >/dev/null
    if (echo "${NEVER_SET}") 2>/dev/null; then echo "nounset lost"; else echo "nounset restored"; fi'
  [ "$status" -eq 0 ]
  [ "$output" = "nounset restored" ]
}

@test "a malformed config aborts a script running under errexit" {
  local tool; tool=$(lib_copy opt/tools mytool)
  printf 'VAL=(unclosed\n' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'set -o errexit; load_config >/dev/null; echo "kept going"'
  [ "$status" -ne 0 ]
  [[ "$output" != *"kept going"* ]]
}

@test "load_config leaves a config's arrays usable" {
  local tool; tool=$(lib_copy opt/tools mytool)
  printf 'DIRS=(one two three)\n' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "${#DIRS[@]}:${DIRS[1]}"'
  [ "$output" = "3:two" ]
}

# --- validate_config -------------------------------------------------------------------------

@test "validate_config accepts a non-empty string" {
  run_snippet "$LIB" 'HOST=example.com; validate_config HOST'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate_config rejects an unset string" {
  run_func "$LIB" validate_config HOST
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required setting 'HOST' is missing or empty."* ]]
}

@test "validate_config rejects an empty string" {
  run_snippet "$LIB" 'HOST=""; validate_config HOST'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required setting 'HOST' is missing or empty."* ]]
}

@test "validate_config accepts a positive integer" {
  run_snippet "$LIB" 'PORT=8080; validate_config int:PORT'
  [ "$status" -eq 0 ]
}

@test "validate_config rejects zero as a positive integer" {
  run_snippet "$LIB" 'PORT=0; validate_config int:PORT'
  [ "$status" -eq 1 ]
  [[ "$output" == *"PORT must be a positive integer, got '0'."* ]]
}

@test "validate_config rejects a negative integer" {
  run_snippet "$LIB" 'PORT=-5; validate_config int:PORT'
  [ "$status" -eq 1 ]
  [[ "$output" == *"got '-5'"* ]]
}

@test "validate_config rejects a non-numeric integer" {
  run_snippet "$LIB" 'PORT=eighty; validate_config int:PORT'
  [ "$status" -eq 1 ]
  [[ "$output" == *"got 'eighty'"* ]]
}

@test "validate_config rejects a leading-zero integer" {
  run_snippet "$LIB" 'PORT=07; validate_config int:PORT'
  [ "$status" -eq 1 ]
  [[ "$output" == *"got '07'"* ]]
}

@test "validate_config reports an unset integer with an empty value" {
  run_func "$LIB" validate_config int:PORT
  [ "$status" -eq 1 ]
  [[ "$output" == *"PORT must be a positive integer, got ''."* ]]
}

@test "validate_config accepts a populated array" {
  run_snippet "$LIB" 'DIRS=(a b); validate_config array:DIRS'
  [ "$status" -eq 0 ]
}

@test "validate_config rejects an empty array" {
  run_snippet "$LIB" 'DIRS=(); validate_config array:DIRS'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required setting 'DIRS' is missing or empty."* ]]
}

@test "validate_config rejects an undeclared array" {
  run_func "$LIB" validate_config array:DIRS
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required setting 'DIRS' is missing or empty."* ]]
}

@test "validate_config rejects an unknown type" {
  run_snippet "$LIB" 'V=x; validate_config bogus:V'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown validation type 'bogus' for 'V'."* ]]
}

@test "validate_config reports every failure, not just the first" {
  run_func "$LIB" validate_config HOST int:PORT array:DIRS
  [ "$status" -eq 1 ]
  [[ "$output" == *"'HOST' is missing"* ]]
  [[ "$output" == *"PORT must be a positive integer"* ]]
  [[ "$output" == *"'DIRS' is missing"* ]]
}

@test "validate_config succeeds when every check passes" {
  run_snippet "$LIB" 'HOST=h; PORT=1; DIRS=(a); validate_config HOST int:PORT array:DIRS'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate_config succeeds with nothing to check" {
  run_func "$LIB" validate_config
  [ "$status" -eq 0 ]
}

# --- Logging ---------------------------------------------------------------------------------

@test "log_info writes to stdout" {
  run_func "$LIB" log_info "hello world"
  [ "$status" -eq 0 ]
  [ "$output" = "[INFO]: hello world" ]
}

@test "log_error writes to stderr" {
  run_snippet "$LIB" 'log_error "bad thing" 2>/dev/null'
  [ -z "$output" ]
  run_snippet "$LIB" 'log_error "bad thing" 2>&1 >/dev/null'
  [ "$output" = "[ERROR]: bad thing" ]
}

@test "log output carries no escape codes when not on a terminal" {
  run_snippet "$LIB" 'log_info "plain"; log_error "plain" 2>&1'
  [[ "$output" != *$'\e'* ]]
}

@test "log_debug is silent unless debug mode is enabled" {
  run_snippet "$LIB" 'log_debug "hidden"; echo done'
  [ "$output" = "done" ]
}

@test "enable_debug_mode makes log_debug speak" {
  run_snippet "$LIB" 'enable_debug_mode; log_debug "now visible"'
  [ "$output" = "[DEBUG]: now visible" ]
}

@test "IS_DEBUG_MODE set before sourcing enables log_debug" {
  IS_DEBUG_MODE=true run_func "$LIB" log_debug "from the environment"
  [ "$output" = "[DEBUG]: from the environment" ]
}

@test "_LOG_QUIET suppresses log_info but not log_error" {
  run_snippet "$LIB" '_LOG_QUIET=true; log_info "quiet"; log_error "loud" 2>&1'
  [ "$output" = "[ERROR]: loud" ]
}

@test "log_message does nothing without a log file" {
  run_snippet "$LIB" 'log_message INFO "nowhere"; echo survived'
  [ "$status" -eq 0 ]
  [ "$output" = "survived" ]
}

@test "log_message timestamps each line in ISO 8601" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB" "LOG_FILE='$log'; log_message INFO 'stamped'"
  [ "$status" -eq 0 ]
  run cat "$log"
  # TZ is pinned to UTC by setup_common, so the offset is fixed.
  [[ "$output" =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+0000\]\ \[INFO\]:\ stamped$ ]]
}

@test "log_message creates the log file's parent directories" {
  local log="$BATS_TEST_TMPDIR/deep/nested/app.log"
  run_snippet "$LIB" "LOG_FILE='$log'; log_info 'to file' >/dev/null"
  [ "$status" -eq 0 ]
  [ -f "$log" ]
  [[ "$(cat "$log")" == *"[INFO]: to file" ]]
}

@test "log_message appends rather than truncating" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB" "LOG_FILE='$log'; log_info first >/dev/null; log_info second >/dev/null"
  run wc -l < "$log"
  [ "$output" -eq 2 ]
}

@test "a quiet run still writes to the log file" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB" "_LOG_QUIET=true; LOG_FILE='$log'; log_info 'quiet but logged'"
  [ -z "$output" ]
  [[ "$(cat "$log")" == *"[INFO]: quiet but logged" ]]
}

@test "log_error is recorded at ERROR level" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB" "LOG_FILE='$log'; log_error 'oops' 2>/dev/null"
  [[ "$(cat "$log")" == *"[ERROR]: oops" ]]
}

@test "log_debug writes nothing to the log file while disabled" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB" "LOG_FILE='$log'; log_debug 'hidden'"
  [ ! -f "$log" ]
}

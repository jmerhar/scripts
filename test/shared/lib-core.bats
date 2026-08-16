#!/usr/bin/env bats
#
# scripts/lib/core.sh is what every script includes: its own name, where it is installed, and how it logs.
# A regression here ships everywhere at once. Its behaviour is also almost entirely $0-derived —
# SCRIPT_NAME, the install prefix, the default log path — so most tests here link the library under a
# chosen path and source it there, which is the only way to exercise those branches.

load ../test_helper

setup() { setup_common; }

########################################
# Links every library into a directory inside the test's temp dir, with one of them also linked under a
# chosen name, and prints that path.
#
# Sourcing it through that name is what lets a test choose $0, and with it SCRIPT_NAME, the config search
# path and the detected install prefix. All the libraries are linked, not just the chosen one, because a
# library sources its dependencies from beside itself: config.sh loads core.sh that way.
#
# Links rather than copies so kcov credits scripts/lib: a copy would leave these tests exercising the
# library while the coverage landed on a temp path nothing measures.
# Arguments:
#   dir: Directory relative to BATS_TEST_TMPDIR.
#   name: Basename without the .sh suffix; becomes SCRIPT_NAME.
#   library: Library to link under that name, e.g. core.sh.
# Outputs:
#   Prints the absolute path of the link.
########################################
lib_at() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir"
  local f
  for f in "$LIB_DIR"/*.sh; do
    ln -sf "$f" "$dir/$(basename "$f")"
  done
  ln -sf "$LIB_DIR/$3" "$dir/$2.sh"
  printf '%s' "$dir/$2.sh"
}

# --- Script identity -------------------------------------------------------------------------

@test "SCRIPT_NAME defaults to the script's basename without the extension" {
  run_snippet "$(lib_at bin widget core.sh)" 'echo "$SCRIPT_NAME"'
  [ "$status" -eq 0 ]
  [ "$output" = "widget" ]
}

@test "SCRIPT_NAME honours a value set before sourcing" {
  SCRIPT_NAME=chosen run_snippet "$LIB_DIR/core.sh" 'echo "$SCRIPT_NAME"'
  [ "$output" = "chosen" ]
}

@test "SCRIPT_NAME cannot be reassigned after sourcing" {
  run_snippet "$LIB_DIR/core.sh" 'SCRIPT_NAME=other'
  [ "$status" -ne 0 ]
  [[ "$output" == *"readonly"* ]]
}

@test "sourcing the library twice is harmless" {
  run_snippet "$LIB_DIR/core.sh" "source '$LIB_DIR/core.sh'; echo twice-ok"
  [ "$status" -eq 0 ]
  [ "$output" = "twice-ok" ]
}

# --- _get_script_prefix -----------------------------------------------------------------------

@test "_get_script_prefix returns the parent of a bin directory" {
  local tool; tool=$(lib_at usr/bin mytool core.sh)
  run_func "$tool" _get_script_prefix
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$BATS_TEST_TMPDIR/usr" && pwd -P)" ]
}

@test "_get_script_prefix returns the parent of an sbin directory" {
  local tool; tool=$(lib_at usr/sbin mytool core.sh)
  run_func "$tool" _get_script_prefix
  [ "$output" = "$(cd "$BATS_TEST_TMPDIR/usr" && pwd -P)" ]
}

@test "_get_script_prefix returns nothing outside bin or sbin" {
  local tool; tool=$(lib_at opt/tools mytool core.sh)
  run_func "$tool" _get_script_prefix
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_get_script_prefix is not fooled by a directory merely ending in bin" {
  local tool; tool=$(lib_at opt/sbin-like mytool core.sh)
  run_func "$tool" _get_script_prefix
  [ -z "$output" ]
}

# --- Logging ---------------------------------------------------------------------------------

@test "log_info writes to stdout" {
  run_func "$LIB_DIR/core.sh" log_info "hello world"
  [ "$status" -eq 0 ]
  [ "$output" = "[INFO]: hello world" ]
}

@test "log_error writes to stderr" {
  run_snippet "$LIB_DIR/core.sh" 'log_error "bad thing" 2>/dev/null'
  [ -z "$output" ]
  run_snippet "$LIB_DIR/core.sh" 'log_error "bad thing" 2>&1 >/dev/null'
  [ "$output" = "[ERROR]: bad thing" ]
}

@test "log output carries no escape codes when not on a terminal" {
  run_snippet "$LIB_DIR/core.sh" 'log_info "plain"; log_error "plain" 2>&1'
  [[ "$output" != *$'\e'* ]]
}

@test "log_debug is silent unless debug mode is enabled" {
  run_snippet "$LIB_DIR/core.sh" 'log_debug "hidden"; echo done'
  [ "$output" = "done" ]
}

@test "enable_debug_mode makes log_debug speak" {
  run_snippet "$LIB_DIR/core.sh" 'enable_debug_mode; log_debug "now visible"'
  [ "$output" = "[DEBUG]: now visible" ]
}

@test "IS_DEBUG_MODE set before sourcing enables log_debug" {
  IS_DEBUG_MODE=true run_func "$LIB_DIR/core.sh" log_debug "from the environment"
  [ "$output" = "[DEBUG]: from the environment" ]
}

@test "_LOG_QUIET suppresses log_info but not log_error" {
  run_snippet "$LIB_DIR/core.sh" '_LOG_QUIET=true; log_info "quiet"; log_error "loud" 2>&1'
  [ "$output" = "[ERROR]: loud" ]
}

@test "log_message does nothing without a log file" {
  run_snippet "$LIB_DIR/core.sh" 'log_message INFO "nowhere"; echo survived'
  [ "$status" -eq 0 ]
  [ "$output" = "survived" ]
}

@test "log_message timestamps each line in ISO 8601" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB_DIR/core.sh" "LOG_FILE='$log'; log_message INFO 'stamped'"
  [ "$status" -eq 0 ]
  run cat "$log"
  # TZ is pinned to UTC by setup_common, so the offset is fixed.
  [[ "$output" =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+0000\]\ \[INFO\]:\ stamped$ ]]
}

@test "log_message creates the log file's parent directories" {
  local log="$BATS_TEST_TMPDIR/deep/nested/app.log"
  run_snippet "$LIB_DIR/core.sh" "LOG_FILE='$log'; log_info 'to file' >/dev/null"
  [ "$status" -eq 0 ]
  [ -f "$log" ]
  [[ "$(cat "$log")" == *"[INFO]: to file" ]]
}

@test "log_message appends rather than truncating" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB_DIR/core.sh" "LOG_FILE='$log'; log_info first >/dev/null; log_info second >/dev/null"
  run wc -l < "$log"
  [ "$output" -eq 2 ]
}

@test "a quiet run still writes to the log file" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB_DIR/core.sh" "_LOG_QUIET=true; LOG_FILE='$log'; log_info 'quiet but logged'"
  [ -z "$output" ]
  [[ "$(cat "$log")" == *"[INFO]: quiet but logged" ]]
}

@test "log_error is recorded at ERROR level" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB_DIR/core.sh" "LOG_FILE='$log'; log_error 'oops' 2>/dev/null"
  [[ "$(cat "$log")" == *"[ERROR]: oops" ]]
}

@test "log_debug writes nothing to the log file while disabled" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB_DIR/core.sh" "LOG_FILE='$log'; log_debug 'hidden'"
  [ ! -f "$log" ]
}

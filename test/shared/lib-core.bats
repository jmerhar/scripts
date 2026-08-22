#!/usr/bin/env bats
#
# scripts/lib/core.sh is what every script includes: its own name, where it is installed, and how it logs.
# A regression here ships everywhere at once. Its behaviour is also almost entirely $0-derived —
# SCRIPT_NAME, the install prefix, the default log path — so most tests here link the library under a
# chosen path and source it there, which is the only way to exercise those branches.

load ../test_helper

setup() { setup_common; }

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

@test "log_warn writes to stderr" {
  # Stderr like log_error, so a caller reading a script's output does not receive a diagnostic as data.
  run_snippet "$LIB_DIR/core.sh" 'log_warn "getting full" 2>/dev/null'
  [ -z "$output" ]
  run_snippet "$LIB_DIR/core.sh" 'log_warn "getting full" 2>&1 >/dev/null'
  [ "$output" = "[WARN]: getting full" ]
}

@test "log_warn is not silenced by _LOG_QUIET" {
  # It reports a finding the caller asked for; only log_info is chatter.
  run_snippet "$LIB_DIR/core.sh" '_LOG_QUIET=true; log_warn "still said" 2>&1'
  [ "$output" = "[WARN]: still said" ]
}

@test "log output carries no escape codes when not on a terminal" {
  run_snippet "$LIB_DIR/core.sh" 'log_info "plain"; log_warn "plain" 2>&1; log_error "plain" 2>&1'
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

@test "log_warn is recorded at WARN level" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB_DIR/core.sh" "LOG_FILE='$log'; log_warn 'filling up' 2>/dev/null"
  [[ "$(cat "$log")" == *"[WARN]: filling up" ]]
}

@test "log_debug writes nothing to the log file while disabled" {
  local log="$BATS_TEST_TMPDIR/app.log"
  run_snippet "$LIB_DIR/core.sh" "LOG_FILE='$log'; log_debug 'hidden'"
  [ ! -f "$log" ]
}

# --- log_command -------------------------------------------------------------------------------
#
# What the script decided goes through log_message; what the commands it ran had to say goes through this.
# The distinction matters on failure: without it a log records "rsync exited 23" and nothing about the path
# it could not read.

@test "log_command runs the command and passes its output through" {
  local tool; tool=$(lib_at opt/tools cmdtool core.sh)
  run_snippet "$tool" 'log_command printf "hello\n"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]]
}

# Callers map particular statuses to meaning — rsync's 24 is a warning, not a failure — so the status has to
# be the command's own and not tee's.
@test "log_command returns the command's exit status, not tee's" {
  local tool; tool=$(lib_at opt/tools cmdtool core.sh)
  run_snippet "$tool" 'LOG_FILE="'"$BATS_TEST_TMPDIR/cmd.log"'"
    log_command bash -c "exit 24" || echo "status=$?"'
  [[ "$output" == *"status=24"* ]]
}

@test "log_command works with no log file, running the command plainly" {
  local tool; tool=$(lib_at opt/tools cmdtool core.sh)
  run_snippet "$tool" 'log_command printf "no log\n"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no log"* ]]
}

# The reason this exists. `tee` writes asynchronously, so the log is waited for rather than read at once —
# which is the same caution any caller reading it back needs.
@test "log_command copies a command's stdout and stderr into the log file" {
  local tool log
  tool=$(lib_at opt/tools cmdtool core.sh)
  log="$BATS_TEST_TMPDIR/cmd.log"
  run_snippet "$tool" 'LOG_FILE="'"$log"'"
    log_command bash -c "printf out; printf err >&2" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      grep -q out "'"$log"'" && grep -q err "'"$log"'" && break
      sleep 0.1
    done'
  run cat "$log"
  [[ "$output" == *"out"* ]]
  [[ "$output" == *"err"* ]]
}

@test "log_command creates the log file's directory" {
  local tool log
  tool=$(lib_at opt/tools cmdtool core.sh)
  log="$BATS_TEST_TMPDIR/nested/deeper/cmd.log"
  run_snippet "$tool" 'LOG_FILE="'"$log"'"
    log_command printf "x\n" >/dev/null
    for _ in 1 2 3 4 5; do [ -s "'"$log"'" ] && break; sleep 0.1; done'
  [ -f "$log" ]
}

# --- default_log_file --------------------------------------------------------------------------

@test "default_log_file names a path under the install prefix" {
  local tool; tool=$(lib_at opt/bin logtool core.sh)
  run_snippet "$tool" 'default_log_file'
  # Compared against the physical path, as the prefix tests above do: the prefix comes from `pwd -P`, and on
  # macOS the temp directory is reached through a symlink.
  [ "$output" = "$(cd "$BATS_TEST_TMPDIR/opt" && pwd -P)/var/log/logtool.log" ]
}

# A checkout has no prefix, and scattering log files through a working tree is worse than logging to the
# terminal — so nothing is named, which the callers read as "no log file".
@test "default_log_file names nothing outside an install prefix" {
  local tool; tool=$(lib_at opt/tools logtool core.sh)
  run_snippet "$tool" 'printf "[%s]" "$(default_log_file)"'
  [ "$output" = "[]" ]
}

# --- disable_log_colors ------------------------------------------------------------------------

# A script with its own --no-color option should not have to know the names of the library's internals, which
# is how one script came to blank five variables by hand.
@test "disable_log_colors empties the log colours" {
  local tool; tool=$(lib_at opt/tools colourtool core.sh)
  # Seeded first, because core.sh picks its colours from `[[ -t 1 ]]` and bats is never a terminal: every
  # one of these is already empty here, so an unseeded assertion holds however few of them the function
  # actually clears.
  run_snippet "$tool" '_color_info=X _color_debug=X _color_warn=X _color_error=X _color_reset=X _text_bold=X
    disable_log_colors
    printf "[%s%s%s%s%s%s]" "${_color_info}" "${_color_debug}" "${_color_warn}" "${_color_error}" "${_color_reset}" "${_text_bold}"'
  [ "$output" = "[]" ]
}

@test "log_info still prints its message with colours disabled" {
  local tool; tool=$(lib_at opt/tools colourtool core.sh)
  run_snippet "$tool" 'disable_log_colors; log_info "plain message"'
  [[ "$output" == *"plain message"* ]]
}

#!/usr/bin/env bats
#
# scripts/lib/common.sh is inlined into nine published scripts, so a regression here ships everywhere
# at once. Its behaviour is also almost entirely $0-derived — SCRIPT_NAME, the install prefix and the
# config search path all come from it — so most tests here link the library under a chosen
# path and source it there, which is the only way to exercise those branches.

load ../test_helper

setup() { setup_common; }

########################################
# Links the shared library as <dir>/<name>.sh inside the test's temp directory and prints that path.
# Sourcing it through that name is what lets a test choose $0, and with it SCRIPT_NAME, the config
# search path and the detected install prefix.
# A link rather than a copy so kcov credits the library in scripts/lib: a copy leaves these tests
# exercising it while the coverage lands on a temp path nothing measures.
# Arguments:
#   dir: Directory relative to BATS_TEST_TMPDIR.
#   name: Basename without the .sh suffix; becomes SCRIPT_NAME.
# Outputs:
#   Prints the absolute path of the link.
########################################
lib_at() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir"
  ln -sf "$LIB" "$dir/$2.sh"
  printf '%s' "$dir/$2.sh"
}

# --- Script identity -------------------------------------------------------------------------

@test "SCRIPT_NAME defaults to the script's basename without the extension" {
  run_snippet "$(lib_at bin widget)" 'echo "$SCRIPT_NAME"'
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
  local tool; tool=$(lib_at usr/bin mytool)
  run_func "$tool" get_script_prefix
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$BATS_TEST_TMPDIR/usr" && pwd -P)" ]
}

@test "get_script_prefix returns the parent of an sbin directory" {
  local tool; tool=$(lib_at usr/sbin mytool)
  run_func "$tool" get_script_prefix
  [ "$output" = "$(cd "$BATS_TEST_TMPDIR/usr" && pwd -P)" ]
}

@test "get_script_prefix returns nothing outside bin or sbin" {
  local tool; tool=$(lib_at opt/tools mytool)
  run_func "$tool" get_script_prefix
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "get_script_prefix is not fooled by a directory merely ending in bin" {
  local tool; tool=$(lib_at opt/sbin-like mytool)
  run_func "$tool" get_script_prefix
  [ -z "$output" ]
}

# --- load_config -----------------------------------------------------------------------------

@test "load_config reads a config beside the script" {
  local tool; tool=$(lib_at opt/tools mytool)
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$status" -eq 0 ]
  [ "$output" = "beside" ]
}

@test "load_config falls back to the install prefix's etc directory" {
  local tool; tool=$(lib_at usr/bin mytool)
  mkdir -p "$BATS_TEST_TMPDIR/usr/etc"
  echo 'VAL=prefix' > "$BATS_TEST_TMPDIR/usr/etc/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "prefix" ]
}

@test "load_config prefers the config beside the script over the prefix one" {
  local tool; tool=$(lib_at usr/bin mytool)
  mkdir -p "$BATS_TEST_TMPDIR/usr/etc"
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/usr/bin/mytool.conf"
  echo 'VAL=prefix' > "$BATS_TEST_TMPDIR/usr/etc/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "beside" ]
}

@test "load_config reports which file it read" {
  local tool; tool=$(lib_at opt/tools mytool)
  echo 'VAL=x' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_func "$tool" load_config
  [[ "$output" == *"Loading configuration from: "*"/opt/tools/mytool.conf" ]]
}

@test "load_config fails when no config exists anywhere" {
  # A deliberately improbable name, so the /etc fallback cannot accidentally match.
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool)
  run_func "$tool" load_config
  [ "$status" -eq 1 ]
}

@test "load_config tolerates a config that reads an unset variable" {
  local tool; tool=$(lib_at opt/tools mytool)
  printf 'VAL="${NOT_DEFINED_ANYWHERE:-}fallback"\n' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'set -o nounset; load_config >/dev/null; echo "$VAL"'
  [ "$status" -eq 0 ]
  [ "$output" = "fallback" ]
}

@test "load_config restores nounset after reading a config" {
  # load_config relaxes nounset around `source` so a config may reference unset variables; the
  # setting must be back on afterwards. Probed in a subshell so the abort does not become this
  # test's own exit status.
  local tool; tool=$(lib_at opt/tools mytool)
  echo 'VAL=x' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'set -o nounset; load_config >/dev/null
    if (echo "${NEVER_SET}") 2>/dev/null; then echo "nounset lost"; else echo "nounset restored"; fi'
  [ "$status" -eq 0 ]
  [ "$output" = "nounset restored" ]
}

@test "a malformed config aborts a script running under errexit" {
  local tool; tool=$(lib_at opt/tools mytool)
  printf 'VAL=(unclosed\n' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'set -o errexit; load_config >/dev/null; echo "kept going"'
  [ "$status" -ne 0 ]
  [[ "$output" != *"kept going"* ]]
}

# --- load_config: an explicitly named file ------------------------------------------------------

@test "CONFIG_FILE is loaded in preference to everything else" {
  local tool; tool=$(lib_at usr/bin mytool)
  mkdir -p "$BATS_TEST_TMPDIR/usr/etc"
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/usr/bin/mytool.conf"
  echo 'VAL=prefix' > "$BATS_TEST_TMPDIR/usr/etc/mytool.conf"
  echo 'VAL=named'  > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$status" -eq 0 ]
  [ "$output" = "named" ]
}

@test "CONFIG_FILE works where the search would find nothing" {
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool)
  echo 'VAL=named' > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "named" ]
}

@test "CONFIG_FILE reports which file it read" {
  local tool; tool=$(lib_at opt/tools mytool)
  echo 'VAL=named' > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_func "$tool" load_config
  [[ "$output" == *"Loading configuration from: $BATS_TEST_TMPDIR/named.conf" ]]
}

# Naming a file excludes the alternatives, so an unreadable one must fail rather than quietly load a
# different config — which could point at different backup targets or hold different credentials.
@test "an unreadable CONFIG_FILE fails instead of falling back to the search" {
  local tool; tool=$(lib_at opt/tools mytool)
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_snippet "$tool" \
    'if load_config >/dev/null 2>&1; then echo "loaded [$VAL]"; else echo "refused"; fi'
  [ "$output" = "refused" ]
}

@test "an unreadable CONFIG_FILE says so" {
  local tool; tool=$(lib_at opt/tools mytool)
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_func "$tool" load_config
  [[ "$output" == *"CONFIG_FILE is set to"*"absent.conf"*"not readable"* ]]
}

# The two failures carry different statuses so a caller for whom a missing config is normal can still
# refuse a named one it cannot read.
@test "load_config distinguishes an unreadable CONFIG_FILE from no config at all" {
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool)
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_func "$tool" load_config
  [ "$status" -eq 2 ]
  run_func "$tool" load_config
  [ "$status" -eq 1 ]
}

# --- load_optional_config -----------------------------------------------------------------------

@test "load_optional_config succeeds when there is no config to find" {
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool)
  run_snippet "$tool" 'load_optional_config >/dev/null; echo "status=$?"'
  [ "$output" = "status=0" ]
}

@test "load_optional_config loads a config when one exists" {
  local tool; tool=$(lib_at opt/tools mytool)
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'load_optional_config >/dev/null; echo "$VAL"'
  [ "$output" = "beside" ]
}

# The whole point of the wrapper: a typo in CONFIG_FILE must not read as "no config", or the run
# proceeds on the defaults the caller thinks they overrode.
@test "load_optional_config refuses an unreadable CONFIG_FILE" {
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool)
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_snippet "$tool" \
    'if load_optional_config >/dev/null 2>&1; then echo "carried on"; else echo "refused"; fi'
  [ "$output" = "refused" ]
}

@test "load_optional_config lets the refusal reach stderr while stdout is dropped" {
  local tool; tool=$(lib_at opt/tools mytool)
  echo 'VAL=named' > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_snippet "$tool" 'load_optional_config >/dev/null'
  [[ "$output" != *"Loading configuration from"* ]]
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_snippet "$tool" 'load_optional_config >/dev/null || true'
  [[ "$output" == *"CONFIG_FILE is set to"* ]]
}

@test "an empty CONFIG_FILE is ignored, leaving the search in charge" {
  local tool; tool=$(lib_at opt/tools mytool)
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  CONFIG_FILE="" run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "beside" ]
}

@test "CONFIG_FILE keeps nounset relaxed while sourcing and restored after" {
  local tool; tool=$(lib_at opt/tools mytool)
  printf 'VAL="${NOT_DEFINED:-}ok"\n' > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_snippet "$tool" \
    'set -o nounset; load_config >/dev/null; echo "$VAL"
     if (echo "${NEVER_SET}") 2>/dev/null; then echo "nounset lost"; else echo "nounset restored"; fi'
  [ "${lines[0]}" = "ok" ]
  [ "${lines[1]}" = "nounset restored" ]
}

@test "load_config leaves a config's arrays usable" {
  local tool; tool=$(lib_at opt/tools mytool)
  printf 'DIRS=(one two three)\n' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "${#DIRS[@]}:${DIRS[1]}"'
  [ "$output" = "3:two" ]
}

# --- load_program ------------------------------------------------------------------------------
#
# load_program is the development half of the @embed mechanism: it reads an awk or jq program from a file
# beside the script, and bin/compile-includes.sh replaces the call with the program text on the way to a
# package. So the text it returns has to be exactly what gets embedded, and a program it cannot read has
# to stop the run — awk and jq both accept an empty program and print nothing, which would turn a
# packaging mistake into a script that silently finds no results.

@test "load_program reads a program from beside the script" {
  local tool; tool=$(lib_at opt/tools progtool)
  printf 'BEGIN { print "hello" }\n' > "$BATS_TEST_TMPDIR/opt/tools/greet.awk"
  run_snippet "$tool" 'load_program greet.awk'
  [ "$status" -eq 0 ]
  [ "$output" = 'BEGIN { print "hello" }' ]
}

@test "load_program returns a multi-line program intact" {
  local tool; tool=$(lib_at opt/tools progtool)
  printf '{ n += $1 }\nEND { print n + 0 }\n' > "$BATS_TEST_TMPDIR/opt/tools/sum.awk"
  run_snippet "$tool" 'load_program sum.awk'
  [ "${lines[0]}" = '{ n += $1 }' ]
  [ "${lines[1]}" = 'END { print n + 0 }' ]
}

# The program is resolved against the script, not the working directory, so a script called by an
# absolute path from anywhere still finds its own programs.
@test "load_program resolves against the script's directory, not the caller's" {
  local tool; tool=$(lib_at opt/tools progtool)
  printf 'BEGIN { print "beside" }\n' > "$BATS_TEST_TMPDIR/opt/tools/where.awk"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  printf 'BEGIN { print "decoy" }\n' > "$BATS_TEST_TMPDIR/elsewhere/where.awk"
  cd "$BATS_TEST_TMPDIR/elsewhere"
  run_snippet "$tool" 'load_program where.awk'
  [ "$output" = 'BEGIN { print "beside" }' ]
}

# An empty program is a valid program to awk and jq, so returning "" for a missing file would hide the
# mistake and report no matches instead of failing.
@test "load_program is fatal when the program is missing" {
  local tool; tool=$(lib_at opt/tools progtool)
  run_snippet "$tool" 'load_program nowhere.awk; echo "kept going"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Program file not found or not readable"* ]]
  [[ "$output" == *"nowhere.awk"* ]]
  [[ "$output" != *"kept going"* ]]
}

@test "load_program is fatal when the program cannot be read" {
  # Root can read a mode-000 file, so -r is true there and the refusal is unreachable — which is the
  # case in the Linux coverage job.
  [ "${EUID:-$(id -u)}" -ne 0 ] || skip "mode 000 is still readable as root"
  local tool; tool=$(lib_at opt/tools progtool)
  local prog="$BATS_TEST_TMPDIR/opt/tools/locked.awk"
  printf 'BEGIN { print 1 }\n' > "$prog"
  chmod 000 "$prog"
  run_snippet "$tool" 'load_program locked.awk'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found or not readable"* ]]
  chmod 644 "$prog"
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

# ${#scalar[@]} is 1, so a length check alone accepts any non-empty string as an array and never
# verifies the type. A config writing DIRS="/one /two" instead of DIRS=(/one /two) would have passed
# validation and then been treated as a single path.
@test "validate_config rejects a plain string given as an array" {
  run_snippet "$LIB" 'DIRS="/one /two"; validate_config array:DIRS'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an array"* ]]
}

@test "validate_config rejects other scalar types given as an array" {
  run_snippet "$LIB" 'declare -i DIRS=5; validate_config array:DIRS'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an array"* ]]
  run_snippet "$LIB" 'declare -x DIRS=exported; validate_config array:DIRS'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an array"* ]]
}

@test "validate_config tells a wrong type apart from a missing value" {
  # The two failures are distinct problems and get distinct messages, so the report says which it is.
  run_snippet "$LIB" 'DIRS="single"; validate_config array:DIRS'
  [[ "$output" == *"must be an array"* ]]
  [[ "$output" != *"missing or empty"* ]]

  run_snippet "$LIB" 'DIRS=(); validate_config array:DIRS'
  [[ "$output" == *"missing or empty"* ]]
  [[ "$output" != *"must be an array"* ]]
}

@test "validate_config accepts an associative array" {
  run_snippet "$LIB" 'declare -A MAP=([k]=v); validate_config array:MAP'
  [ "$status" -eq 0 ]
}

@test "validate_config accepts an array carrying extra attributes" {
  run_snippet "$LIB" 'declare -ar DIRS=(one two); validate_config array:DIRS'
  [ "$status" -eq 0 ]
}

@test "validate_config accepts an array whose single element is empty" {
  # One empty element is still a populated array; the check is on length, not content.
  run_snippet "$LIB" 'DIRS=(""); validate_config array:DIRS'
  [ "$status" -eq 0 ]
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

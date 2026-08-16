#!/usr/bin/env bats
#
# scripts/lib/config.sh finds and validates a script's configuration. The failures that matter are silent
# ones: loading a different file than the caller named, or accepting a setting that is missing, since both
# leave a script running against defaults its operator believes they replaced.
#
# It declares core.sh as a dependency, so sourcing it gives the logging functions too.

load ../test_helper

setup() { setup_common; }

# --- load_config -----------------------------------------------------------------------------

@test "load_config reads a config beside the script" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$status" -eq 0 ]
  [ "$output" = "beside" ]
}

@test "load_config falls back to the install prefix's etc directory" {
  local tool; tool=$(lib_at usr/bin mytool config.sh)
  mkdir -p "$BATS_TEST_TMPDIR/usr/etc"
  echo 'VAL=prefix' > "$BATS_TEST_TMPDIR/usr/etc/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "prefix" ]
}

@test "load_config prefers the config beside the script over the prefix one" {
  local tool; tool=$(lib_at usr/bin mytool config.sh)
  mkdir -p "$BATS_TEST_TMPDIR/usr/etc"
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/usr/bin/mytool.conf"
  echo 'VAL=prefix' > "$BATS_TEST_TMPDIR/usr/etc/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "beside" ]
}

@test "load_config reports which file it read" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  echo 'VAL=x' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_func "$tool" load_config
  [[ "$output" == *"Loading configuration from: "*"/opt/tools/mytool.conf" ]]
}

@test "load_config fails when no config exists anywhere" {
  # A deliberately improbable name, so the /etc fallback cannot accidentally match.
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool config.sh)
  run_func "$tool" load_config
  [ "$status" -eq 1 ]
}

@test "load_config tolerates a config that reads an unset variable" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  printf 'VAL="${NOT_DEFINED_ANYWHERE:-}fallback"\n' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'set -o nounset; load_config >/dev/null; echo "$VAL"'
  [ "$status" -eq 0 ]
  [ "$output" = "fallback" ]
}

@test "load_config restores nounset after reading a config" {
  # load_config relaxes nounset around `source` so a config may reference unset variables; the
  # setting must be back on afterwards. Probed in a subshell so the abort does not become this
  # test's own exit status.
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  echo 'VAL=x' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'set -o nounset; load_config >/dev/null
    if (echo "${NEVER_SET}") 2>/dev/null; then echo "nounset lost"; else echo "nounset restored"; fi'
  [ "$status" -eq 0 ]
  [ "$output" = "nounset restored" ]
}

@test "a malformed config aborts a script running under errexit" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  printf 'VAL=(unclosed\n' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'set -o errexit; load_config >/dev/null; echo "kept going"'
  [ "$status" -ne 0 ]
  [[ "$output" != *"kept going"* ]]
}

# --- load_config: an explicitly named file ------------------------------------------------------

@test "CONFIG_FILE is loaded in preference to everything else" {
  local tool; tool=$(lib_at usr/bin mytool config.sh)
  mkdir -p "$BATS_TEST_TMPDIR/usr/etc"
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/usr/bin/mytool.conf"
  echo 'VAL=prefix' > "$BATS_TEST_TMPDIR/usr/etc/mytool.conf"
  echo 'VAL=named'  > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$status" -eq 0 ]
  [ "$output" = "named" ]
}

@test "CONFIG_FILE works where the search would find nothing" {
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool config.sh)
  echo 'VAL=named' > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "named" ]
}

@test "CONFIG_FILE reports which file it read" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  echo 'VAL=named' > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_func "$tool" load_config
  [[ "$output" == *"Loading configuration from: $BATS_TEST_TMPDIR/named.conf" ]]
}

# Naming a file excludes the alternatives, so an unreadable one must fail rather than quietly load a
# different config — which could point at different backup targets or hold different credentials.
@test "an unreadable CONFIG_FILE fails instead of falling back to the search" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_snippet "$tool" \
    'if load_config >/dev/null 2>&1; then echo "loaded [$VAL]"; else echo "refused"; fi'
  [ "$output" = "refused" ]
}

@test "an unreadable CONFIG_FILE says so" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_func "$tool" load_config
  [[ "$output" == *"CONFIG_FILE is set to"*"absent.conf"*"not readable"* ]]
}

# The two failures carry different statuses so a caller for whom a missing config is normal can still
# refuse a named one it cannot read.
@test "load_config distinguishes an unreadable CONFIG_FILE from no config at all" {
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool config.sh)
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_func "$tool" load_config
  [ "$status" -eq 2 ]
  run_func "$tool" load_config
  [ "$status" -eq 1 ]
}

# --- load_optional_config -----------------------------------------------------------------------

@test "load_optional_config succeeds when there is no config to find" {
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool config.sh)
  run_snippet "$tool" 'load_optional_config >/dev/null; echo "status=$?"'
  [ "$output" = "status=0" ]
}

@test "load_optional_config loads a config when one exists" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'load_optional_config >/dev/null; echo "$VAL"'
  [ "$output" = "beside" ]
}

# The whole point of the wrapper: a typo in CONFIG_FILE must not read as "no config", or the run
# proceeds on the defaults the caller thinks they overrode.
@test "load_optional_config refuses an unreadable CONFIG_FILE" {
  local tool; tool=$(lib_at opt/tools lib-common-bats-absent-tool config.sh)
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_snippet "$tool" \
    'if load_optional_config >/dev/null 2>&1; then echo "carried on"; else echo "refused"; fi'
  [ "$output" = "refused" ]
}

@test "load_optional_config lets the refusal reach stderr while stdout is dropped" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  echo 'VAL=named' > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_snippet "$tool" 'load_optional_config >/dev/null'
  [[ "$output" != *"Loading configuration from"* ]]
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" run_snippet "$tool" 'load_optional_config >/dev/null || true'
  [[ "$output" == *"CONFIG_FILE is set to"* ]]
}

@test "an empty CONFIG_FILE is ignored, leaving the search in charge" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  echo 'VAL=beside' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  CONFIG_FILE="" run_snippet "$tool" 'load_config >/dev/null; echo "$VAL"'
  [ "$output" = "beside" ]
}

@test "CONFIG_FILE keeps nounset relaxed while sourcing and restored after" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  printf 'VAL="${NOT_DEFINED:-}ok"\n' > "$BATS_TEST_TMPDIR/named.conf"
  CONFIG_FILE="$BATS_TEST_TMPDIR/named.conf" run_snippet "$tool" \
    'set -o nounset; load_config >/dev/null; echo "$VAL"
     if (echo "${NEVER_SET}") 2>/dev/null; then echo "nounset lost"; else echo "nounset restored"; fi'
  [ "${lines[0]}" = "ok" ]
  [ "${lines[1]}" = "nounset restored" ]
}

@test "load_config leaves a config's arrays usable" {
  local tool; tool=$(lib_at opt/tools mytool config.sh)
  printf 'DIRS=(one two three)\n' > "$BATS_TEST_TMPDIR/opt/tools/mytool.conf"
  run_snippet "$tool" 'load_config >/dev/null; echo "${#DIRS[@]}:${DIRS[1]}"'
  [ "$output" = "3:two" ]
}

# --- validate_config -------------------------------------------------------------------------

@test "validate_config accepts a non-empty string" {
  run_snippet "$LIB_DIR/config.sh" 'HOST=example.com; validate_config HOST'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate_config rejects an unset string" {
  run_func "$LIB_DIR/config.sh" validate_config HOST
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required setting 'HOST' is missing or empty."* ]]
}

@test "validate_config rejects an empty string" {
  run_snippet "$LIB_DIR/config.sh" 'HOST=""; validate_config HOST'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required setting 'HOST' is missing or empty."* ]]
}

@test "validate_config accepts a positive integer" {
  run_snippet "$LIB_DIR/config.sh" 'PORT=8080; validate_config int:PORT'
  [ "$status" -eq 0 ]
}

@test "validate_config rejects zero as a positive integer" {
  run_snippet "$LIB_DIR/config.sh" 'PORT=0; validate_config int:PORT'
  [ "$status" -eq 1 ]
  [[ "$output" == *"PORT must be a positive integer, got '0'."* ]]
}

@test "validate_config rejects a negative integer" {
  run_snippet "$LIB_DIR/config.sh" 'PORT=-5; validate_config int:PORT'
  [ "$status" -eq 1 ]
  [[ "$output" == *"got '-5'"* ]]
}

@test "validate_config rejects a non-numeric integer" {
  run_snippet "$LIB_DIR/config.sh" 'PORT=eighty; validate_config int:PORT'
  [ "$status" -eq 1 ]
  [[ "$output" == *"got 'eighty'"* ]]
}

@test "validate_config rejects a leading-zero integer" {
  run_snippet "$LIB_DIR/config.sh" 'PORT=07; validate_config int:PORT'
  [ "$status" -eq 1 ]
  [[ "$output" == *"got '07'"* ]]
}

@test "validate_config reports an unset integer with an empty value" {
  run_func "$LIB_DIR/config.sh" validate_config int:PORT
  [ "$status" -eq 1 ]
  [[ "$output" == *"PORT must be a positive integer, got ''."* ]]
}

@test "validate_config accepts a populated array" {
  run_snippet "$LIB_DIR/config.sh" 'DIRS=(a b); validate_config array:DIRS'
  [ "$status" -eq 0 ]
}

@test "validate_config rejects an empty array" {
  run_snippet "$LIB_DIR/config.sh" 'DIRS=(); validate_config array:DIRS'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required setting 'DIRS' is missing or empty."* ]]
}

@test "validate_config rejects an undeclared array" {
  run_func "$LIB_DIR/config.sh" validate_config array:DIRS
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required setting 'DIRS' is missing or empty."* ]]
}

# ${#scalar[@]} is 1, so a length check alone accepts any non-empty string as an array and never
# verifies the type. A config writing DIRS="/one /two" instead of DIRS=(/one /two) would have passed
# validation and then been treated as a single path.
@test "validate_config rejects a plain string given as an array" {
  run_snippet "$LIB_DIR/config.sh" 'DIRS="/one /two"; validate_config array:DIRS'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an array"* ]]
}

@test "validate_config rejects other scalar types given as an array" {
  run_snippet "$LIB_DIR/config.sh" 'declare -i DIRS=5; validate_config array:DIRS'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an array"* ]]
  run_snippet "$LIB_DIR/config.sh" 'declare -x DIRS=exported; validate_config array:DIRS'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an array"* ]]
}

@test "validate_config tells a wrong type apart from a missing value" {
  # The two failures are distinct problems and get distinct messages, so the report says which it is.
  run_snippet "$LIB_DIR/config.sh" 'DIRS="single"; validate_config array:DIRS'
  [[ "$output" == *"must be an array"* ]]
  [[ "$output" != *"missing or empty"* ]]

  run_snippet "$LIB_DIR/config.sh" 'DIRS=(); validate_config array:DIRS'
  [[ "$output" == *"missing or empty"* ]]
  [[ "$output" != *"must be an array"* ]]
}

@test "validate_config accepts an associative array" {
  run_snippet "$LIB_DIR/config.sh" 'declare -A MAP=([k]=v); validate_config array:MAP'
  [ "$status" -eq 0 ]
}

@test "validate_config accepts an array carrying extra attributes" {
  run_snippet "$LIB_DIR/config.sh" 'declare -ar DIRS=(one two); validate_config array:DIRS'
  [ "$status" -eq 0 ]
}

@test "validate_config accepts an array whose single element is empty" {
  # One empty element is still a populated array; the check is on length, not content.
  run_snippet "$LIB_DIR/config.sh" 'DIRS=(""); validate_config array:DIRS'
  [ "$status" -eq 0 ]
}

@test "validate_config rejects an unknown type" {
  run_snippet "$LIB_DIR/config.sh" 'V=x; validate_config bogus:V'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown validation type 'bogus' for 'V'."* ]]
}

@test "validate_config reports every failure, not just the first" {
  run_func "$LIB_DIR/config.sh" validate_config HOST int:PORT array:DIRS
  [ "$status" -eq 1 ]
  [[ "$output" == *"'HOST' is missing"* ]]
  [[ "$output" == *"PORT must be a positive integer"* ]]
  [[ "$output" == *"'DIRS' is missing"* ]]
}

@test "validate_config succeeds when every check passes" {
  run_snippet "$LIB_DIR/config.sh" 'HOST=h; PORT=1; DIRS=(a); validate_config HOST int:PORT array:DIRS'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate_config succeeds with nothing to check" {
  run_func "$LIB_DIR/config.sh" validate_config
  [ "$status" -eq 0 ]
}


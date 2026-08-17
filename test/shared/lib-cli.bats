#!/usr/bin/env bats
#
# scripts/lib/cli.sh holds the three ways a command line can be wrong, so that nine parsers report them
# alike: one wording for an unknown option, one for a missing value, one for a leftover argument — each with
# the usage beside it, since an error without the usage leaves the reader guessing.
#
# It is not a general option parser. Each script keeps its own option table and its own usage text — a
# generated usage reads worse than a written one, and a generic parser would have to reproduce every script's
# diagnostics to avoid changing them.

load ../test_helper

setup() {
  setup_common
  TOOL=$(lib_at opt/tools cli-user cli.sh)
}

########################################
# Evaluates a snippet with a show_usage the library can call, as every script defines one.
# Arguments:
#   snippet: Bash to run.
########################################
with_usage() {
  run_snippet "$TOOL" "show_usage() { echo 'Usage: cli-user [OPTIONS]'; }
$1"
}

# --- die_usage ---------------------------------------------------------------------------------

# The error and the usage together: an error alone leaves the reader guessing, and a usage alone buries it.
@test "die_usage reports the message and the usage, and exits 1" {
  with_usage 'die_usage "Unknown option \"-z\"."; echo "not reached"'
  [ "$status" -eq 1 ]
  [[ "$output" == *'Unknown option "-z".'* ]]
  [[ "$output" == *"Usage: cli-user"* ]]
  [[ "$output" != *"not reached"* ]]
}

@test "die_usage joins its arguments into one message" {
  with_usage 'die_usage "two" "parts"'
  [[ "$output" == *"two parts"* ]]
}

# --- require_option_value ----------------------------------------------------------------------

# Called as `require_option_value "$@"` from inside the option's own case arm, so what it sees is the option
# followed by whatever came after it.
@test "require_option_value accepts an option that has its value" {
  with_usage 'require_option_value --lang en; echo accepted'
  [ "$status" -eq 0 ]
  [ "$output" = "accepted" ]
}

# A trailing option with nothing after it would otherwise read the next option as its value — or, at the end
# of the line, an empty string.
@test "require_option_value refuses an option with nothing after it" {
  with_usage 'require_option_value --lang; echo "not reached"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Option '--lang' requires an argument."* ]]
  [[ "$output" != *"not reached"* ]]
}

@test "require_option_value refuses an empty value" {
  with_usage 'require_option_value --lang ""; echo "not reached"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an argument"* ]]
}

@test "require_option_value ignores anything past the value" {
  with_usage 'require_option_value --lang en --model base; echo accepted'
  [ "$status" -eq 0 ]
  [ "$output" = "accepted" ]
}

# --- reject_positionals ------------------------------------------------------------------------

@test "reject_positionals is silent when nothing is left" {
  with_usage 'reject_positionals; echo clean'
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

# A script that ignored a leftover argument would run with a command line its operator believes did
# something — a mistyped option, or a path where none belongs.
@test "reject_positionals refuses what is left over, naming it" {
  with_usage 'reject_positionals stray other; echo "not reached"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected arguments: stray other"* ]]
  [[ "$output" != *"not reached"* ]]
}

@test "reject_positionals refuses a single leftover argument" {
  with_usage 'reject_positionals stray'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected arguments: stray"* ]]
}

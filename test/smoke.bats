#!/usr/bin/env bats
#
# One invocation of every script, through its real command line.
#
# These are shallow by design. Under `set -o nounset` a typo in a rarely-taken branch, an unset
# variable on the usage path, or a syntax error anywhere in the file only shows up when the script is
# actually run, and nothing else in the suite runs all of them. Each test picks the cheapest
# invocation that reaches the script's own argument handling and stops there.
#
# Nothing here should reach an external command; if a stub records a call, an invocation chosen as
# "harmless" has started doing real work and needs revisiting.

load test_helper

setup() { setup_common; }

teardown() {
  # A smoke invocation that shells out has escaped its intended scope.
  if [ -s "$STUB_CALLS" ]; then
    printf 'smoke invocation unexpectedly called: %s\n' "$(cat "$STUB_CALLS")" >&2
    return 1
  fi
}

@test "smoke: photo-backup shows usage for -h" {
  run_script "$REPO_ROOT/scripts/photography/photo-backup/photo-backup.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "smoke: remove-sidecars shows usage for --help" {
  run_script "$REPO_ROOT/scripts/photography/remove-sidecars/remove-sidecars.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: remove-sidecars"* ]]
}

@test "smoke: local-backup shows usage for -h" {
  run_script "$REPO_ROOT/scripts/system/local-backup/local-backup.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: local-backup"* ]]
}

@test "smoke: mdcheck-progress shows usage for --help" {
  run_script "$REPO_ROOT/scripts/system/mdcheck-progress/mdcheck-progress.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: mdcheck-progress"* ]]
}

@test "smoke: nopasswd-sudo shows usage for --help" {
  run_script "$REPO_ROOT/scripts/system/nopasswd-sudo/nopasswd-sudo.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"{on|off|status}"* ]]
}

@test "smoke: prune-orphaned-torrents shows usage for --help" {
  run_script "$REPO_ROOT/scripts/system/prune-orphaned-torrents/prune-orphaned-torrents.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: prune-orphaned-torrents"* ]]
}

@test "smoke: compare-dirs shows usage for --help" {
  run_script "$REPO_ROOT/scripts/utility/compare-dirs/compare-dirs.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: compare-dirs"* ]]
}

@test "smoke: dmarc-report shows usage for --help" {
  run_script "$REPO_ROOT/scripts/utility/dmarc-report/dmarc-report.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: dmarc-report"* ]]
}

@test "smoke: subtitle-report shows usage for --help" {
  run_script "$REPO_ROOT/scripts/utility/subtitle-report/subtitle-report.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: subtitle-report"* ]]
}

@test "smoke: subtitle-sync shows usage for --help" {
  run_script "$REPO_ROOT/scripts/utility/subtitle-sync/subtitle-sync.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: subtitle-sync"* ]]
}

# unlock-pdf has no help flag at all; its argument check is the only reachable entry behaviour.
@test "smoke: unlock-pdf shows usage when given no argument" {
  run_script "$REPO_ROOT/scripts/utility/unlock-pdf/unlock-pdf.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"*"<input.pdf>"* ]]
}

@test "smoke: compile-includes shows usage for -h" {
  run_script "$REPO_ROOT/bin/compile-includes.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: compile-includes.sh"* ]]
}

@test "smoke: package-script refuses to run without arguments" {
  run_script "$REPO_ROOT/bin/package-script.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected exactly 2 arguments"* ]]
}

# The README and the column header are required; everything past them is an option, so the count is a
# minimum rather than an exact number.
@test "smoke: update-readme-table refuses to run without arguments" {
  run_script "$REPO_ROOT/bin/update-readme-table.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected at least 2 arguments"* ]]
}

@test "smoke: update-all-tables refuses an option it does not have" {
  run_script "$REPO_ROOT/bin/update-all-tables.sh" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

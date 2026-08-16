#!/usr/bin/env bats
#
# scripts/lib/platform.sh hides the one difference that would otherwise break every script on one of the two
# platforms this repository publishes to: `stat`'s flags are wholly different on Linux and macOS.
#
# The flavour is probed when the library loads, so these tests run the real thing against real files rather
# than stubbing stat — a stub would prove only that the probe was called, not that the flags chosen work
# here.

load ../test_helper

setup() {
  setup_common
  TOOL=$(lib_at opt/tools platform-user platform.sh)
  FILE="$BATS_TEST_TMPDIR/sized.bin"
  printf '0123456789' > "$FILE"
}

# --- stat_size ---------------------------------------------------------------------------------

@test "stat_size reports a real byte count" {
  run_snippet "$TOOL" "stat_size '$FILE'"
  [ "$output" = "10" ]
}

@test "stat_size on a file that does not exist fails rather than printing a number" {
  run_snippet "$TOOL" "stat_size '$BATS_TEST_TMPDIR/absent' 2>/dev/null || echo 'failed as expected'"
  [[ "$output" == *"failed as expected"* ]]
  [[ "$output" != *"0"* ]] || [[ "$output" == "failed as expected" ]]
}

# --- stat_mtime --------------------------------------------------------------------------------

@test "stat_mtime reports seconds since the epoch" {
  run_snippet "$TOOL" "stat_mtime '$FILE'"
  [[ "$output" =~ ^[0-9]{9,}$ ]]
}

@test "stat_mtime moves when the file is touched" {
  local before after
  run_snippet "$TOOL" "stat_mtime '$FILE'"
  before="$output"
  touch -t 202001010000.00 "$FILE"
  run_snippet "$TOOL" "stat_mtime '$FILE'"
  after="$output"
  [ "$before" != "$after" ]
}

# --- file_checksum -----------------------------------------------------------------------------

@test "file_checksum prints a bare sha256 digest" {
  run_snippet "$TOOL" "file_checksum '$FILE'"
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "identical contents hash the same, different contents differently" {
  local other="$BATS_TEST_TMPDIR/same.bin" changed="$BATS_TEST_TMPDIR/other.bin"
  printf '0123456789' > "$other"
  printf 'something else' > "$changed"
  run_snippet "$TOOL" "file_checksum '$FILE'"
  local first="$output"
  run_snippet "$TOOL" "file_checksum '$other'"
  [ "$output" = "$first" ]
  run_snippet "$TOOL" "file_checksum '$changed'"
  [ "$output" != "$first" ]
}

# A caller comparing checksums has to be able to find out that it cannot, rather than being handed a
# placeholder that makes every file look identical.
@test "has_checksum_tool answers for this machine" {
  run_snippet "$TOOL" "has_checksum_tool && echo available"
  [ "$output" = "available" ]
}

@test "file_checksum fails when no checksum tool exists" {
  local minimal="$BATS_TEST_TMPDIR/minimal-bin" cmd
  mkdir -p "$minimal"
  for cmd in bash basename dirname printf cat cut stat; do
    [ -e "$(command -v "$cmd" 2>/dev/null)" ] && ln -sf "$(command -v "$cmd")" "$minimal/$cmd"
  done
  run env PATH="$minimal" "$(command -v bash)" -c \
    "source '$TOOL'; file_checksum '$FILE' || echo 'no tool'"
  [[ "$output" == *"no tool"* ]]
}

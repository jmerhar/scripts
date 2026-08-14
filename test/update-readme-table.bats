#!/usr/bin/env bats
#
# update-readme-table.sh regenerates the script table in the downstream tap and APT repositories'
# READMEs from this repository's manifest. It edits a file in place during a release, so the failure
# to guard against is a splice that loses surrounding prose.
#
# Runs against a copy of the tool in a fake repository, so it reads a fixture manifest rather than
# the real one.

load test_helper

setup() {
  setup_common
  fake_repo_tool update-readme-table.sh
  TOOL="$FAKE_TOOL"
  README="$BATS_TEST_TMPDIR/README.md"

  cat > "$FAKE_REPO/scripts.yaml" <<'EOF'
defaults:
  author: "Test Author <test@example.com>"
  homepage: "https://github.com/example/scripts"
  license: "MIT"

scripts:
  zebra-tool:
    path: scripts/utility/zebra-tool.sh
    description: "Last in the manifest."
  alpha-tool:
    path: scripts/utility/alpha-tool.sh
    description: "First in the manifest."
EOF

  cat > "$README" <<'EOF'
# Heading

Text above the table.

<!-- BEGIN TABLE -->
old content that must go
<!-- END TABLE -->

Text below the table.
EOF
}

# --- Argument validation -----------------------------------------------------------------------

# yq reads the manifest, so without it the table would silently come out empty rather than wrong.
@test "a missing yq is reported rather than producing an empty table" {
  local readme="$FAKE_REPO/README.md"
  printf 'intro\n<!-- BEGIN TABLE -->\n<!-- END TABLE -->\n' > "$readme"
  local minimal="$BATS_TEST_TMPDIR/minimal-bin" cmd
  mkdir -p "$minimal"
  for cmd in bash basename dirname sed awk grep mktemp mv cat date printf; do
    [ -e "$(command -v "$cmd" 2>/dev/null)" ] && ln -sf "$(command -v "$cmd")" "$minimal/$cmd"
  done
  run env PATH="$minimal" "$(command -v bash)" "$FAKE_TOOL" "$readme" Script
  [ "$status" -eq 1 ]
  [[ "$output" == *"yq"*"required"* ]]
}

@test "refuses to run without both arguments" {
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected exactly 2 arguments."* ]]
  [[ "$output" == *"Usage:"* ]]

  run_script "$TOOL" "$README"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected exactly 2 arguments."* ]]
}

@test "reports a README that does not exist" {
  run_script "$TOOL" "$BATS_TEST_TMPDIR/absent.md" Formula
  [ "$status" -eq 1 ]
  [[ "$output" == *"README file not found:"* ]]
}

@test "reports a missing manifest" {
  rm "$FAKE_REPO/scripts.yaml"
  run_script "$TOOL" "$README" Formula
  [ "$status" -eq 1 ]
  [[ "$output" == *"Manifest not found:"* ]]
}

@test "reports that yq is required when it cannot be found" {
  # A PATH holding only what the script needs to get as far as its dependency check — it resolves its
  # own directory and timestamps its log lines before looking for yq. Emptying PATH entirely would
  # kill it at `dirname` and never reach the check being asserted.
  local minimal="$BATS_TEST_TMPDIR/minimal-bin" cmd
  mkdir -p "$minimal"
  for cmd in dirname basename date; do
    ln -sf "$(command -v "$cmd")" "$minimal/$cmd"
  done
  run env PATH="$minimal" "$(command -v bash)" "$TOOL" "$README" Formula
  [ "$status" -eq 1 ]
  [[ "$output" == *"'yq' is required but not found in PATH."* ]]
}

# --- Table generation --------------------------------------------------------------------------

@test "writes one row per manifest entry" {
  run_script "$TOOL" "$README" Formula
  [ "$status" -eq 0 ]
  run cat "$README"
  [[ "$output" == *'| `alpha-tool` | First in the manifest. |'* ]]
  [[ "$output" == *'| `zebra-tool` | Last in the manifest. |'* ]]
}

@test "uses the requested first-column header" {
  run_script "$TOOL" "$README" Package
  run cat "$README"
  [[ "$output" == *"| Package | Description |"* ]]
  [[ "$output" != *"| Formula |"* ]]
}

# Rows follow the manifest's own order rather than being sorted, so keeping scripts.yaml
# alphabetical is what keeps the published table alphabetical.
@test "rows follow the order of the manifest" {
  run_script "$TOOL" "$README" Formula
  run grep -n 'tool`' "$README"
  [[ "${lines[0]}" == *"zebra-tool"* ]]
  [[ "${lines[1]}" == *"alpha-tool"* ]]
}

@test "replaces the previous table content" {
  run_script "$TOOL" "$README" Formula
  run cat "$README"
  [[ "$output" != *"old content that must go"* ]]
}

@test "leaves the prose around the table untouched" {
  run_script "$TOOL" "$README" Formula
  run cat "$README"
  [[ "$output" == *"# Heading"* ]]
  [[ "$output" == *"Text above the table."* ]]
  [[ "$output" == *"Text below the table."* ]]
}

@test "keeps both markers so the table can be regenerated again" {
  run_script "$TOOL" "$README" Formula
  run cat "$README"
  [[ "$output" == *"<!-- BEGIN TABLE -->"* ]]
  [[ "$output" == *"<!-- END TABLE -->"* ]]
}

@test "running twice is idempotent" {
  run_script "$TOOL" "$README" Formula
  local once
  once=$(cat "$README")
  run_script "$TOOL" "$README" Formula
  [ "$status" -eq 0 ]
  [ "$(cat "$README")" = "$once" ]
}

@test "a README with no markers keeps its content and gains no table" {
  printf '# Just prose\n\nNothing to splice here.\n' > "$README"
  run_script "$TOOL" "$README" Formula
  [ "$status" -eq 0 ]
  run cat "$README"
  [[ "$output" == *"# Just prose"* ]]
  [[ "$output" == *"Nothing to splice here."* ]]
  [[ "$output" != *"| Formula |"* ]]
}

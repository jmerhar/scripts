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
    path: scripts/utility/zebra-tool/zebra-tool.sh
    summary: "Short form for the index."
    description: "Last in the manifest."
  alpha-tool:
    path: scripts/utility/alpha-tool/alpha-tool.sh
    description: "First in the manifest."
  linux-tool:
    path: scripts/system/linux-tool/linux-tool.sh
    summary: 'Runs an *arr thing | with a pipe.'
    description: "Only shipped to Debian."
    platforms: [debian]
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

# The README and the column header are both required; anything beyond them is an option, so the count is a
# minimum rather than an exact number.
@test "refuses to run without both arguments" {
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected at least 2 arguments."* ]]
  [[ "$output" == *"Usage:"* ]]

  run_script "$TOOL" "$README"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected at least 2 arguments."* ]]
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

# --- The documentation index shapes ------------------------------------------------------------

# The release path calls the tool with exactly two arguments, so that form must keep emitting a plain
# name and nothing else.
@test "the two-argument form emits no links and no third column" {
  run_script "$TOOL" "$README" "Formula"
  run cat "$README"
  [[ "$output" == *"| \`alpha-tool\` |"* ]]
  [[ "$output" != *"]("* ]]
  [[ "$output" != *"Location"* ]]
}

@test "--link repo points at each script's own directory" {
  run_script "$TOOL" "$README" "Script" --link repo
  run cat "$README"
  [[ "$output" == *"[\`alpha-tool\`](scripts/utility/alpha-tool/)"* ]]
}

@test "--link sibling points at a directory beside the topic README" {
  run_script "$TOOL" "$README" "Script" --link sibling
  run cat "$README"
  [[ "$output" == *"[\`alpha-tool\`](alpha-tool/)"* ]]
}

# The link comes from the manifest path, so a script in an unexpected place still links correctly rather
# than to a path assembled from its name.
@test "the link follows the manifest path rather than the script name" {
  python3 - "$FAKE_REPO/scripts.yaml" <<'PYEOF' || true
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t.replace("scripts/utility/alpha-tool/alpha-tool.sh", "scripts/elsewhere/moved/alpha-tool.sh"))
PYEOF
  run_script "$TOOL" "$README" "Script" --link repo
  run cat "$README"
  [[ "$output" == *"[\`alpha-tool\`](scripts/elsewhere/moved/)"* ]]
}

@test "--topic lists only that topic's scripts" {
  run_script "$TOOL" "$README" "Script" --topic system
  run cat "$README"
  [[ "$output" == *"linux-tool"* ]]
  [[ "$output" != *"alpha-tool"* ]]
  [[ "$output" != *"zebra-tool"* ]]
}

@test "--with-location names the directory in a third column" {
  run_script "$TOOL" "$README" "Script" --with-location
  run cat "$README"
  [[ "$output" == *"| Location |"* ]]
  [[ "$output" == *"\`scripts/utility/alpha-tool/\`"* ]]
}

# The two texts serve different readers: the package metadata runs long, the index wants one line.
@test "--field summary prefers the summary, falling back to the description" {
  run_script "$TOOL" "$README" "Script" --field summary
  run cat "$README"
  [[ "$output" == *"Short form for the index."* ]]
  [[ "$output" == *"First in the manifest."* ]]
}

# Derived from platforms rather than written into the text, so it cannot contradict what is published.
@test "--platform-note marks the scripts Homebrew never receives" {
  run_script "$TOOL" "$README" "Script" --platform-note
  run cat "$README"
  [[ "$output" == *"Only shipped to Debian. _(Linux only)_"* ]]
  [[ "$output" != *"First in the manifest. _(Linux only)_"* ]]
}

# A pipe would end the cell and a bare asterisk would open emphasis, so both are escaped rather than the
# manifest being expected to hold pre-escaped markdown.
@test "pipes and asterisks in the text are escaped" {
  run_script "$TOOL" "$README" "Script" --field summary
  run cat "$README"
  [[ "$output" == *'\*arr'* ]]
  [[ "$output" == *'\|'* ]]
}

# The escaping applies to the release form too, which is the one the downstream tap and APT READMEs are
# built with. A manifest description is plain prose, so a word it wraps in asterisks has to survive as
# written: `*only*` in a table cell otherwise renders as emphasis with the asterisks dropped. `*arr` and
# `*.jpg` are safe unescaped, since those asterisks are not flanked the way emphasis requires — which is
# exactly why the escaping cannot be judged by the descriptions that happen to exist today.
@test "the two-argument release form escapes the text as well" {
  cat >> "$FAKE_REPO/scripts.yaml" <<'EOF'
  star-tool:
    path: scripts/utility/star-tool/star-tool.sh
    description: "Deletes *only* the sidecars, never the RAW."
EOF
  run_script "$TOOL" "$README" "Formula"
  run cat "$README"
  [[ "$output" == *'\*only\*'* ]]
}

@test "--sort lists alphabetically instead of in manifest order" {
  run_script "$TOOL" "$README" "Script" --sort
  run bash -c "grep -oE '\`[a-z-]+-tool\`' '$README' | head -3 | tr -d '\`' | tr '\n' ' '"
  [ "$output" = "alpha-tool linux-tool zebra-tool " ]
}

@test "without --sort the manifest order is kept" {
  run_script "$TOOL" "$README" "Formula"
  run bash -c "grep -oE '\`[a-z-]+-tool\`' '$README' | head -3 | tr -d '\`' | tr '\n' ' '"
  [ "$output" = "zebra-tool alpha-tool linux-tool " ]
}

# --- Check mode --------------------------------------------------------------------------------

@test "--check leaves the file alone and succeeds when it is current" {
  run_script "$TOOL" "$README" "Formula"
  local before
  before=$(cat "$README")
  run_script "$TOOL" "$README" "Formula" --check
  [ "$status" -eq 0 ]
  [ "$(cat "$README")" = "$before" ]
}

@test "--check fails and does not rewrite when the table is stale" {
  run_script "$TOOL" "$README" "Formula"
  printf 'x\n' >> "$FAKE_REPO/scripts.yaml"
  python3 - "$README" <<'PYEOF' || true
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t.replace("alpha-tool", "stale-name", 1))
PYEOF
  local stale
  stale=$(cat "$README")
  run_script "$TOOL" "$README" "Formula" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"out of date"* ]]
  [ "$(cat "$README")" = "$stale" ]
}

@test "an unknown option is refused" {
  run_script "$TOOL" "$README" "Formula" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "--link refuses a mode it does not have" {
  run_script "$TOOL" "$README" "Formula" --link sideways
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be none, repo or sibling"* ]]
}

@test "an option that takes a value is refused without one" {
  run_script "$TOOL" "$README" "Formula" --topic
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a name"* ]]
}

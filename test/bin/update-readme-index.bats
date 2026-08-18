#!/usr/bin/env bats
#
# update-readme-index.sh regenerates the script index section in a README from the manifest.
# The index is one level-3 heading per script — the name (optionally linked), the manifest
# `description` as a paragraph, and a compact tagline of minimum bash version and
# dependencies — spliced between the BEGIN/END markers. So the failure to guard against is a
# splice that loses surrounding prose, and an index that misstates a script's metadata.
#
# Runs against a copy of the tool in a fake repository, so it reads a fixture manifest rather
# than the real one.

load ../test_helper

setup() {
  setup_common
  fake_repo_tool update-readme-index.sh
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
    description: "Last in the manifest."
    min_bash: "4.0"
    dependencies:
      common: [curl]
  alpha-tool:
    path: scripts/utility/alpha-tool/alpha-tool.sh
    description: "First in the manifest."
  linux-tool:
    path: scripts/system/linux-tool/linux-tool.sh
    description: "Runs an *arr thing | with a pipe. Only shipped to Debian."
    min_bash: "4.3"
    platforms: [debian]
    dependencies:
      debian: [mdadm]
EOF

  cat > "$README" <<'EOF'
# Heading

Text above the index.

<!-- BEGIN INDEX -->
old content that must go
<!-- END INDEX -->

Text below the index.
EOF
}

# --- Argument validation -----------------------------------------------------------------------

# yq reads the manifest, so without it the index would silently come out empty rather than wrong.
@test "a missing yq is reported rather than producing an empty index" {
  local readme="$FAKE_REPO/README.md"
  printf 'intro\n<!-- BEGIN INDEX -->\n<!-- END INDEX -->\n' > "$readme"
  local minimal="$BATS_TEST_TMPDIR/minimal-bin" cmd
  mkdir -p "$minimal"
  for cmd in bash basename dirname sed awk grep mktemp mv cat date printf; do
    [ -e "$(command -v "$cmd" 2>/dev/null)" ] && ln -sf "$(command -v "$cmd")" "$minimal/$cmd"
  done
  run env PATH="$minimal" "$(command -v bash)" "$FAKE_TOOL" "$readme"
  [ "$status" -eq 1 ]
  [[ "$output" == *"yq"*"required"* ]]
}

@test "refuses to run without a README file" {
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected a README file."* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "reports a README that does not exist" {
  run_script "$TOOL" "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"README file not found:"* ]]
}

@test "reports a missing manifest" {
  rm "$FAKE_REPO/scripts.yaml"
  run_script "$TOOL" "$README"
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
  run env PATH="$minimal" "$(command -v bash)" "$TOOL" "$README"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'yq' is required but not found in PATH."* ]]
}

# --- Index generation --------------------------------------------------------------------------

@test "writes one heading per manifest entry" {
  run_script "$TOOL" "$README"
  [ "$status" -eq 0 ]
  run cat "$README"
  [[ "$output" == *"### \`alpha-tool\`"* ]]
  [[ "$output" == *"### \`zebra-tool\`"* ]]
}

@test "replaces the previous index content" {
  run_script "$TOOL" "$README"
  run cat "$README"
  [[ "$output" != *"old content that must go"* ]]
}

@test "leaves the prose around the index untouched" {
  run_script "$TOOL" "$README"
  run cat "$README"
  [[ "$output" == *"# Heading"* ]]
  [[ "$output" == *"Text above the index."* ]]
  [[ "$output" == *"Text below the index."* ]]
}

@test "keeps both markers so the index can be regenerated again" {
  run_script "$TOOL" "$README"
  run cat "$README"
  [[ "$output" == *"<!-- BEGIN INDEX -->"* ]]
  [[ "$output" == *"<!-- END INDEX -->"* ]]
}

@test "running twice is idempotent" {
  run_script "$TOOL" "$README"
  local once
  once=$(cat "$README")
  run_script "$TOOL" "$README"
  [ "$status" -eq 0 ]
  [ "$(cat "$README")" = "$once" ]
}

@test "a README with no markers keeps its content and gains no index" {
  printf '# Just prose\n\nNothing to splice here.\n' > "$README"
  run_script "$TOOL" "$README"
  [ "$status" -eq 0 ]
  run cat "$README"
  [[ "$output" == *"# Just prose"* ]]
  [[ "$output" == *"Nothing to splice here."* ]]
  [[ "$output" != *"### \`"* ]]
}

# --- The link shapes ----------------------------------------------------------------------------

# The bare form — a downstream repo with nothing to link to — emits a plain name heading.
@test "the bare form emits a plain name heading with no link" {
  run_script "$TOOL" "$README"
  run cat "$README"
  [[ "$output" == *"### \`alpha-tool\`"* ]]
  [[ "$output" != *"]("* ]]
}

@test "--link repo points at each script's own directory" {
  run_script "$TOOL" "$README" --link repo
  run cat "$README"
  [[ "$output" == *"### [\`alpha-tool\`](scripts/utility/alpha-tool/)"* ]]
}

@test "--link sibling points at a directory beside the topic README" {
  run_script "$TOOL" "$README" --link sibling
  run cat "$README"
  [[ "$output" == *"### [\`alpha-tool\`](alpha-tool/)"* ]]
}

# The link comes from the manifest path, so a script in an unexpected place still links correctly rather
# than to a path assembled from its name.
@test "the link follows the manifest path rather than the script name" {
  python3 - "$FAKE_REPO/scripts.yaml" <<'PYEOF' || true
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t.replace("scripts/utility/alpha-tool/alpha-tool.sh", "scripts/elsewhere/moved/alpha-tool.sh"))
PYEOF
  run_script "$TOOL" "$README" --link repo
  run cat "$README"
  [[ "$output" == *"### [\`alpha-tool\`](scripts/elsewhere/moved/)"* ]]
}

@test "--topic lists only that topic's scripts" {
  run_script "$TOOL" "$README" --topic system
  run cat "$README"
  [[ "$output" == *"linux-tool"* ]]
  [[ "$output" != *"alpha-tool"* ]]
  [[ "$output" != *"zebra-tool"* ]]
}

# --- The metadata tagline ----------------------------------------------------------------------

# min_bash is shown only when declared: zebra-tool declares 4.0, alpha-tool declares none.
@test "the minimum bash version appears only when declared" {
  run_script "$TOOL" "$README"
  run cat "$README"
  [[ "$output" == *"`bash 4.0+`"* ]]
  [[ "$output" == *"`bash 4.3+`"* ]]
  # alpha-tool has no min_bash; its block must not carry a bash segment. The block runs from its
  # heading to the next heading, so the tagline of the following script is not included.
  local alpha_block
  alpha_block=$(awk '/^### `alpha-tool`/{f=1; next} /^### /{f=0} f' "$README")
  [[ "$alpha_block" != *"bash "* ]]
}

# Common deps are named flat; a script with none declares nothing, so no deps line at all.
@test "common dependencies are listed and a script with none emits no deps" {
  run_script "$TOOL" "$README"
  run cat "$README"
  [[ "$output" == *"deps: \`curl\`"* ]]
  # alpha-tool declares no dependencies and no min_bash, so its block has no tagline line. The
  # block runs from its heading to the next heading, since the blank lines within a block would
  # otherwise stop a range short of the tagline.
  local alpha_block
  alpha_block=$(awk '/^### `alpha-tool`/{f=1; next} /^### /{f=0} f' "$README")
  [[ "$alpha_block" != *"deps:"* ]]
}

# A script split across platforms names the shared deps first, then the platform-specific packages.
@test "platform-specific dependencies follow common ones in parentheses" {
  cat >> "$FAKE_REPO/scripts.yaml" <<'EOF'
  split-tool:
    path: scripts/utility/split-tool/split-tool.sh
    description: "Has deps on every platform."
    dependencies:
      common: [curl, jq]
      homebrew: [libxml2]
      debian: [libxml2-utils, unzip]
EOF
  run_script "$TOOL" "$README"
  run cat "$README"
  [[ "$output" == *"deps: \`curl\`, \`jq\` (+\`libxml2\` macOS, \`libxml2-utils\`, \`unzip\` Linux)"* ]]
}

# A script that declares platform-specific deps on both platforms but no common ones must join the
# two lists with a separator rather than run them together — a bare concatenation would emit
# `libxml2``libxml2-utils`, which no reader can parse.
@test "platform-specific deps without common ones are joined, not concatenated" {
  cat >> "$FAKE_REPO/scripts.yaml" <<'EOF'
  split-no-common:
    path: scripts/utility/split-no-common/split-no-common.sh
    description: "Has per-platform deps but no shared ones."
    dependencies:
      homebrew: [libxml2]
      debian: [libxml2-utils, unzip]
EOF
  run_script "$TOOL" "$README"
  [ "$status" -eq 0 ]
  run cat "$README"
  [[ "$output" == *"deps: \`libxml2\`, \`libxml2-utils\`, \`unzip\`"* ]]
  [[ "$output" != *"libxml2\`\`libxml2-utils"* ]]
}

# A script with no description cannot be documented in the index, and silently emitting a heading
# with an empty paragraph would produce a malformed block. The generator fails the build rather than
# publish a broken index.
@test "a script with an empty description fails the build" {
  cat >> "$FAKE_REPO/scripts.yaml" <<'EOF'
  empty-desc:
    path: scripts/utility/empty-desc/empty-desc.sh
    description: ""
EOF
  run_script "$TOOL" "$README"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty description"* ]]
}

# A single-platform script has no common deps to split from, so its packages are named flat — the
# platform annotation carries the platform, not the deps line.
@test "a single-platform script lists its deps without a parenthetical" {
  run_script "$TOOL" "$README"
  run cat "$README"
  [[ "$output" == *"deps: \`mdadm\`"* ]]
  [[ "$output" != *"(+`mdadm`"* ]]
}

# Derived from platforms rather than written into the text, so it cannot contradict what is published.
# The note is appended to the tagline line, not the description, so it is asserted against the block.
@test "--platform-note marks the scripts Homebrew never receives" {
  run_script "$TOOL" "$README" --platform-note
  run cat "$README"
  local linux_block alpha_block
  linux_block=$(awk '/^### `linux-tool`/{f=1; next} /^### /{f=0} f' "$README")
  alpha_block=$(awk '/^### `alpha-tool`/{f=1; next} /^### /{f=0} f' "$README")
  [[ "$linux_block" == *"_(Linux only)_"* ]]
  [[ "$alpha_block" != *"_(Linux only)_"* ]]
}

# --- Escaping in prose -------------------------------------------------------------------------

# The description is plain prose, not a table cell, so an asterisk and a pipe are not escaped: a
# backslash would render as a visible backslash in the paragraph, and neither character is special
# there. `*arr` and `|` survive as written.
@test "asterisks and pipes in the description are not escaped" {
  run_script "$TOOL" "$README"
  run cat "$README"
  [[ "$output" == *"Runs an *arr thing | with a pipe."* ]]
  [[ "$output" != *'\*arr'* ]]
  [[ "$output" != *'\|'* ]]
}

# --- Order --------------------------------------------------------------------------------------

@test "--sort lists alphabetically instead of in manifest order" {
  run_script "$TOOL" "$README" --sort
  run bash -c "grep -oE '### \`[a-z-]+-tool\`' '$README' | sed 's/### \`//; s/\`//' | tr '\n' ' '"
  [ "$output" = "alpha-tool linux-tool zebra-tool " ]
}

@test "without --sort the manifest order is kept" {
  run_script "$TOOL" "$README"
  run bash -c "grep -oE '### \`[a-z-]+-tool\`' '$README' | sed 's/### \`//; s/\`//' | tr '\n' ' '"
  [ "$output" = "zebra-tool alpha-tool linux-tool " ]
}

# --- Check mode --------------------------------------------------------------------------------

@test "--check leaves the file alone and succeeds when it is current" {
  run_script "$TOOL" "$README"
  local before
  before=$(cat "$README")
  run_script "$TOOL" "$README" --check
  [ "$status" -eq 0 ]
  [ "$(cat "$README")" = "$before" ]
}

@test "--check fails and does not rewrite when the index is stale" {
  run_script "$TOOL" "$README"
  printf 'x\n' >> "$FAKE_REPO/scripts.yaml"
  python3 - "$README" <<'PYEOF' || true
import sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
p.write_text(t.replace("alpha-tool", "stale-name", 1))
PYEOF
  local stale
  stale=$(cat "$README")
  run_script "$TOOL" "$README" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"out of date"* ]]
  [ "$(cat "$README")" = "$stale" ]
}

# --- Option validation -------------------------------------------------------------------------

@test "an unknown option is refused" {
  run_script "$TOOL" "$README" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "--link refuses a mode it does not have" {
  run_script "$TOOL" "$README" --link sideways
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be none, repo or sibling"* ]]
}

@test "an option that takes a value is refused without one" {
  run_script "$TOOL" "$README" --topic
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a name"* ]]
}

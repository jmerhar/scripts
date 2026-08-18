#!/usr/bin/env bats
#
# update-all-indexes.sh is the single caller of the index generator that knows which indexes this
# repository has: the root README and one per topic. Two things about it are worth testing — that the
# topic list comes from the manifest rather than from a hardcoded list, so a script under a new topic
# cannot go undocumented, and that --check reports every stale index rather than stopping at the first.
#
# Runs against a copy of both tools in a fake repository, so a fixture manifest and fixture READMEs
# stand in for the real ones.

load ../test_helper

setup() {
  setup_common
  # Both tools have to be present: update-all-indexes.sh resolves the generator beside itself.
  fake_repo_tool update-readme-index.sh
  fake_repo_tool update-all-indexes.sh
  TOOL="$FAKE_TOOL"

  cat > "$FAKE_REPO/scripts.yaml" <<'EOF'
defaults:
  author: "Test Author <test@example.com>"
  homepage: "https://github.com/example/scripts"
  license: "MIT"

scripts:
  alpha-tool:
    path: scripts/utility/alpha-tool/alpha-tool.sh
    description: "An alpha thing, at length."
  system-tool:
    path: scripts/system/system-tool/system-tool.sh
    description: "A system thing, at length."
  aardvark-tool:
    path: scripts/utility/aardvark-tool/aardvark-tool.sh
    description: "An aardvark thing, at length."
EOF

  make_index "$FAKE_REPO/README.md"
  make_index "$FAKE_REPO/scripts/utility/README.md"
  make_index "$FAKE_REPO/scripts/system/README.md"
}

########################################
# Writes a README containing empty table markers.
# Arguments:
#   path: File to create, with its parent directories.
########################################
make_index() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
# Heading

Intro prose.

<!-- BEGIN INDEX -->
<!-- END INDEX -->

Closing prose.
EOF
}

########################################
# Makes a README's index stale by hand-editing inside the markers.
#
# Text appended after the END marker would not do: the generator preserves everything outside the
# markers, so an addition there is prose rather than a stale index.
# Arguments:
#   path: README to edit.
########################################
corrupt_table() {
  awk '/<!-- BEGIN INDEX -->/ { print; print "### `ghost-tool`"; print ""; print "Not in the manifest."; next } { print }' \
    "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

# --- Which indexes get written -----------------------------------------------------------------

@test "the root index and every topic index are regenerated" {
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  run cat "$FAKE_REPO/README.md"
  [[ "$output" == *"alpha-tool"* ]]
  [[ "$output" == *"system-tool"* ]]
  run cat "$FAKE_REPO/scripts/utility/README.md"
  [[ "$output" == *"alpha-tool"* ]]
  [[ "$output" == *"aardvark-tool"* ]]
  [[ "$output" != *"system-tool"* ]]
  run cat "$FAKE_REPO/scripts/system/README.md"
  [[ "$output" == *"system-tool"* ]]
  [[ "$output" != *"alpha-tool"* ]]
}

@test "the root index links to each script's directory" {
  run_script "$TOOL"
  run cat "$FAKE_REPO/README.md"
  [[ "$output" == *"### [\`alpha-tool\`](scripts/utility/alpha-tool/)"* ]]
}

@test "a topic index links to its scripts as siblings" {
  run_script "$TOOL"
  run cat "$FAKE_REPO/scripts/utility/README.md"
  [[ "$output" == *"[\`alpha-tool\`](alpha-tool/)"* ]]
  [[ "$output" != *"scripts/utility/alpha-tool/"* ]]
}

@test "the full description is shown in the index" {
  run_script "$TOOL"
  run cat "$FAKE_REPO/README.md"
  [[ "$output" == *"An alpha thing, at length."* ]]
}

# Eleven scripts in manifest order are eleven rows in no order a reader can predict, so every index is
# sorted. The fixture's manifest lists aardvark-tool last precisely so sorting cannot look correct by
# coincidence.
@test "scripts are listed alphabetically rather than in manifest order" {
  run_script "$TOOL"
  local first second
  first=$(grep -n 'aardvark-tool' "$FAKE_REPO/scripts/utility/README.md" | head -1 | cut -d: -f1)
  second=$(grep -n 'alpha-tool' "$FAKE_REPO/scripts/utility/README.md" | head -1 | cut -d: -f1)
  [ "$first" -lt "$second" ]
  first=$(grep -n 'aardvark-tool' "$FAKE_REPO/README.md" | head -1 | cut -d: -f1)
  second=$(grep -n 'system-tool' "$FAKE_REPO/README.md" | head -1 | cut -d: -f1)
  [ "$first" -lt "$second" ]
}

# A script the manifest does not publish to Homebrew is one macOS cannot install, which a reader of the
# index needs to know before following the link.
@test "a Linux-only script is annotated in the index" {
  cat >> "$FAKE_REPO/scripts.yaml" <<'EOF'
  linux-tool:
    path: scripts/system/linux-tool/linux-tool.sh
    description: "A Linux thing, at length."
    platforms: [debian]
EOF
  run_script "$TOOL"
  run cat "$FAKE_REPO/README.md"
  # The root index links each script to its directory, so the heading is `### [`name`](dir/)`;
  # match a heading line containing the name, then read to the next heading or the END marker.
  local linux_block alpha_block
  linux_block=$(awk '/^### .*`linux-tool`/{f=1; next} /^### |<!-- END/{f=0} f' "$FAKE_REPO/README.md")
  alpha_block=$(awk '/^### .*`alpha-tool`/{f=1; next} /^### |<!-- END/{f=0} f' "$FAKE_REPO/README.md")
  [[ "$linux_block" == *"_(Linux only)_"* ]]
  [[ "$alpha_block" != *"_(Linux only)_"* ]]
}

@test "prose around the index is preserved" {
  run_script "$TOOL"
  run cat "$FAKE_REPO/scripts/system/README.md"
  [[ "$output" == *"Intro prose."* ]]
  [[ "$output" == *"Closing prose."* ]]
}

# The whole reason the topic list is derived from the manifest: adding a script under a new topic must
# not leave that topic's index unwritten, which a hardcoded list of topics would do silently.
@test "a script under a new topic gets that topic's index written" {
  cat >> "$FAKE_REPO/scripts.yaml" <<'EOF'
  net-tool:
    path: scripts/network/net-tool/net-tool.sh
    description: "A network thing, at length."
EOF
  make_index "$FAKE_REPO/scripts/network/README.md"
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  run cat "$FAKE_REPO/scripts/network/README.md"
  [[ "$output" == *"net-tool"* ]]
}

# A new topic whose index does not exist yet is a mistake to report, not to skip: skipping it would
# leave the script reachable only from the root index.
@test "a topic with no index file is an error naming the topic" {
  cat >> "$FAKE_REPO/scripts.yaml" <<'EOF'
  net-tool:
    path: scripts/network/net-tool/net-tool.sh
    description: "A network thing, at length."
EOF
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No index for topic 'network'"* ]]
}

# The remaining indexes still have to be written, or one missing topic README would leave the rest of
# the documentation half-generated.
@test "a missing topic index does not stop the other indexes being written" {
  cat >> "$FAKE_REPO/scripts.yaml" <<'EOF'
  net-tool:
    path: scripts/network/net-tool/net-tool.sh
    description: "A network thing, at length."
EOF
  run_script "$TOOL"
  [ "$status" -ne 0 ]
  run cat "$FAKE_REPO/scripts/utility/README.md"
  [[ "$output" == *"alpha-tool"* ]]
  run cat "$FAKE_REPO/scripts/system/README.md"
  [[ "$output" == *"system-tool"* ]]
}

# --- Check mode --------------------------------------------------------------------------------

@test "--check passes once the indexes are up to date" {
  run_script "$TOOL"
  run_script "$TOOL" --check
  [ "$status" -eq 0 ]
}

@test "--check fails on a hand-edited index and names the file" {
  run_script "$TOOL"
  corrupt_table "$FAKE_REPO/scripts/system/README.md"
  run_script "$TOOL" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/system/README.md is out of date"* ]]
  [[ "$output" == *"make docs"* ]]
}

# The realistic way an index goes stale: the manifest changed and nobody ran `make docs`.
@test "--check fails when the manifest has moved on" {
  run_script "$TOOL"
  run_script "$TOOL" --check
  [ "$status" -eq 0 ]
  sed -i.bak 's/An alpha thing, at length\./A renamed thing./' "$FAKE_REPO/scripts.yaml"
  run_script "$TOOL" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"A renamed thing."* ]]
}

@test "--check leaves the stale file untouched" {
  run_script "$TOOL"
  corrupt_table "$FAKE_REPO/README.md"
  local before after
  before=$(cat "$FAKE_REPO/README.md")
  run_script "$TOOL" --check
  [ "$status" -ne 0 ]
  after=$(cat "$FAKE_REPO/README.md")
  [ "$after" = "$before" ]
  [[ "$after" == *"ghost-tool"* ]]
}

# A --check run exists to be read by whoever has to fix it, so it reports every stale file rather than
# stopping at the first. A manifest edit makes every index stale at once, which is the case that
# would otherwise be reported one file per run.
@test "--check reports every stale index, not just the first" {
  run_script "$TOOL"
  sed -i.bak 's/at length\./at length, renamed./' "$FAKE_REPO/scripts.yaml"
  run_script "$TOOL" --check
  [ "$status" -ne 0 ]
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'is out of date'" _ "$output"
  [ "$output" = "3" ]
}

# --- Arguments and prerequisites ---------------------------------------------------------------

@test "an unknown option is refused with the usage" {
  run_script "$TOOL" --write-everything
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "a missing manifest is reported" {
  rm "$FAKE_REPO/scripts.yaml"
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Manifest not found"* ]]
}

# Without yq the topic list would come out empty and the run would report success having written only
# the root table.
@test "a missing yq is reported rather than producing empty indexes" {
  local minimal="$BATS_TEST_TMPDIR/minimal-bin" cmd
  mkdir -p "$minimal"
  for cmd in bash basename dirname sed awk grep sort mktemp mv cat date printf diff; do
    [ -e "$(command -v "$cmd" 2>/dev/null)" ] && ln -sf "$(command -v "$cmd")" "$minimal/$cmd"
  done
  run env PATH="$minimal" "$(command -v bash)" "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"yq"*"required"* ]]
}

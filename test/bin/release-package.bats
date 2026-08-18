#!/usr/bin/env bats
#
# release-package.sh decides which script a release publishes, and at what version, from the tag alone.
# That was 44 lines inside a workflow `run:` block, where the only way to exercise it was to cut a release
# — so a tag that parsed wrongly would publish the wrong thing, or nothing, with no earlier warning.
#
# The packager and `gh` are stubbed and asserted on by argv: what matters here is which name and version
# were packaged and which tag the tarball was uploaded to, not that packaging works, which its own suite
# covers.

load ../test_helper

setup() {
  setup_common
  fake_repo_tool release-package.sh
  TOOL="$FAKE_TOOL"

  cat > "$FAKE_REPO/scripts.yaml" <<'EOF'
scripts:
  alpha-tool:
    path: scripts/utility/alpha-tool/alpha-tool.sh
    description: "First."
  beta-tool:
    path: scripts/utility/beta-tool/beta-tool.sh
    description: "Second."
EOF

  # The fake bin/ mirrors the real one, so the packager there is a symlink to the real script. Replaced
  # with a recorder — through the helper, which removes the link rather than writing through it — because
  # this suite is about which packaging calls are made, not about packaging, which has its own suite.
  fake_repo_replace_tool package-script.sh <<EOF
#!/usr/bin/env bash
printf 'package-script %s\n' "\$*" >> "$STUB_CALLS"
# Writes to stdout as the real one does — dpkg-deb announces the package it builds — because this
# function's stdout is the commit message the caller captures.
echo "dpkg-deb: building package '\$1'"
mkdir -p "$FAKE_REPO/dist/tarballs"
: > "$FAKE_REPO/dist/tarballs/scripts-\$1-\$2.tar.gz"
EOF
  # gh reports its upload on stdout too.
  printf 'Successfully uploaded the asset\n' > "$STUB_FIXTURES/gh.stdout"

  # A repository with tags, since republish-all reads the newest tag per script.
  git_fixture_init "$FAKE_REPO"
  git -C "$FAKE_REPO" add -A
  git -C "$FAKE_REPO" commit --quiet -m "fixture"
}

########################################
# Tags the fixture repository.
# Arguments:
#   Tag names.
########################################
tag_repo() {
  local tag
  for tag in "$@"; do
    git -C "$FAKE_REPO" tag "$tag"
  done
}

# --- Tag parsing -------------------------------------------------------------------------------

@test "a release tag names the script and version to package" {
  run_script "$TOOL" release alpha-tool-v1.2.3
  [ "$status" -eq 0 ]
  stub_called 'package-script alpha-tool v1.2.3'
}

@test "the commit message names the script and version" {
  run_script "$TOOL" release alpha-tool-v1.2.3
  [[ "$output" == *"feat(alpha-tool): Release version v1.2.3"* ]]
}

# A script name may contain hyphens, so the split has to be at the last -v and not the first hyphen.
@test "a hyphenated script name is parsed whole" {
  run_script "$TOOL" release prune-orphaned-torrents-v10.20.30
  [ "$status" -eq 0 ]
  stub_called 'package-script prune-orphaned-torrents v10.20.30'
  [[ "$output" == *"feat(prune-orphaned-torrents):"* ]]
}

@test "the tarball is uploaded to the release the tag names" {
  run_script "$TOOL" release alpha-tool-v1.2.3
  stub_called 'gh release upload alpha-tool-v1.2.3 .*scripts-alpha-tool-v1.2.3.tar.gz --clobber'
}

# Publishing the wrong script, or a version the tarball name cannot match, is worse than a failed run.
@test "a tag without a version is refused before packaging" {
  run_script "$TOOL" release alpha-tool
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tag format is invalid"* ]]
  [ "$(stub_calls gh)" -eq 0 ]
  run bash -c "grep -c 'package-script' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "a two-part version is refused" {
  run_script "$TOOL" release alpha-tool-v1.2
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tag format is invalid"* ]]
}

@test "a version without the v prefix is refused" {
  run_script "$TOOL" release alpha-tool-1.2.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tag format is invalid"* ]]
}

@test "release without a tag is refused" {
  run_script "$TOOL" release
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a tag"* ]]
}

# --- Republishing everything -------------------------------------------------------------------

@test "republish-all packages the newest tag of every script" {
  tag_repo alpha-tool-v1.0.0 alpha-tool-v1.10.0 alpha-tool-v1.9.0 beta-tool-v2.0.0
  run_script "$TOOL" republish-all
  [ "$status" -eq 0 ]
  stub_called 'package-script alpha-tool v1.10.0'
  stub_called 'package-script beta-tool v2.0.0'
}

# Newest by version, not by string: v1.10.0 sorts before v1.9.0 lexically and after it numerically.
@test "the newest tag is chosen by version order" {
  tag_repo alpha-tool-v1.9.0 alpha-tool-v1.10.0
  run_script "$TOOL" republish-all
  stub_called 'package-script alpha-tool v1.10.0'
  run bash -c "grep -c 'package-script alpha-tool v1.9.0' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

# There is no release to upload a tarball to, so packaging it would produce an orphan artefact.
@test "a script with no tags is skipped, not packaged" {
  tag_repo alpha-tool-v1.0.0
  run_script "$TOOL" republish-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping beta-tool"* ]]
  run bash -c "grep -c 'package-script beta-tool' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "republish-all reports its own commit message" {
  tag_repo alpha-tool-v1.0.0
  run_script "$TOOL" republish-all
  [[ "$output" == *"chore: Republish latest version of all scripts"* ]]
}

@test "republish-all with no tags at all still succeeds" {
  run_script "$TOOL" republish-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"chore: Republish"* ]]
}

# --- The event-name interface ------------------------------------------------------------------

# The workflow passes github.event_name straight through, so the mapping from event to mode is made here
# rather than in a conditional in YAML.
@test "the workflow_dispatch event republishes everything" {
  tag_repo alpha-tool-v1.0.0
  run_script "$TOOL" workflow_dispatch
  [ "$status" -eq 0 ]
  stub_called 'package-script alpha-tool v1.0.0'
  [[ "$output" == *"chore: Republish"* ]]
}

@test "the release event with a tag publishes that one script" {
  run_script "$TOOL" release alpha-tool-v3.0.0
  [ "$status" -eq 0 ]
  stub_called 'package-script alpha-tool v3.0.0'
}

@test "an unknown mode is refused, naming what is expected" {
  run_script "$TOOL" push
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown mode 'push'"* ]]
  [[ "$output" == *"release"* ]]
}

# --- The commit message reaches the workflow ---------------------------------------------------

# The two downstream pushes are skipped when this output is empty, so a message that never arrives means a
# release that packages and then publishes nowhere.
@test "the commit message is appended to GITHUB_OUTPUT" {
  local out="$BATS_TEST_TMPDIR/github-output"
  : > "$out"
  GITHUB_OUTPUT="$out" run_script "$TOOL" release alpha-tool-v1.2.3
  [ "$status" -eq 0 ]
  run cat "$out"
  [ "$output" = "commit_message=feat(alpha-tool): Release version v1.2.3" ]
}

@test "without GITHUB_OUTPUT the message still goes to stdout" {
  run_script "$TOOL" release alpha-tool-v1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat(alpha-tool): Release version v1.2.3"* ]]
}

# stdout carries the message and nothing else, so a caller can capture it directly.
@test "progress goes to stderr, not stdout" {
  GITHUB_ACTIONS= run bash -c "'$TOOL' release alpha-tool-v1.2.3 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "feat(alpha-tool): Release version v1.2.3" ]
}

# The failure this guards against: the packager and gh both write to stdout, and this function's stdout is
# the commit message. A message that picked up one of their lines is written to $GITHUB_OUTPUT as a
# multi-line value, which Actions rejects — and both downstream pushes are skipped when that output is
# empty, so the release packages and then publishes nowhere.
@test "the commit message is one line even when the packager and gh are noisy" {
  local out="$BATS_TEST_TMPDIR/github-output"
  : > "$out"
  GITHUB_OUTPUT="$out" run_script "$TOOL" release alpha-tool-v1.2.3
  [ "$status" -eq 0 ]
  run cat "$out"
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "commit_message=feat(alpha-tool): Release version v1.2.3" ]
}

@test "a message that picked up another line is refused, naming the cause" {
  fake_repo_replace_tool package-script.sh <<EOF
#!/usr/bin/env bash
mkdir -p "$FAKE_REPO/dist/tarballs"
: > "$FAKE_REPO/dist/tarballs/scripts-\$1-\$2.tar.gz"
EOF
  # A message that already contains a newline: what a stray write into the captured stream produces.
  # noisy.sh sits in package/ beside the replaced package-script.sh, since release-package.sh invokes
  # its packager as a same-directory sibling.
  run bash -c "sed 's|feat(%s): Release version %s|feat(%s): stray\\nRelease %s|' '$TOOL' > '$FAKE_REPO/bin/package/noisy.sh'
    chmod +x '$FAKE_REPO/bin/package/noisy.sh'
    '$FAKE_REPO/bin/package/noisy.sh' release alpha-tool-v1.2.3"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a single line"* ]]
}

# --- Safety ------------------------------------------------------------------------------------

# The fixture bin/ is a directory of symlinks into the real one, so replacing a tool with `cat >` would
# follow the link and overwrite the repository's own copy. It has happened; this is what would catch it.
@test "replacing a tool in the fixture leaves the real one untouched" {
  fake_repo_replace_tool package-script.sh <<'EOF'
#!/usr/bin/env bash
echo replaced
EOF
  run cat "$REPO_ROOT/bin/package/package-script.sh"
  [[ "$output" == *"Creating Homebrew formula"* ]]
  [ "${#lines[@]}" -gt 100 ]
  run cat "$FAKE_REPO/bin/package/package-script.sh"
  [ "$output" = "#!/usr/bin/env bash
echo replaced" ]
}

# --- Usage -------------------------------------------------------------------------------------

@test "shows usage on request" {
  run_script "$TOOL" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: release-package.sh"* ]]
}

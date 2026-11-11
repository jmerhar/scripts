#!/usr/bin/env bats
#
# The walk that packages every manifest entry as a smoke test. Its job is to fail when the manifest and the
# packager stop agreeing — a new entry missing a field, or metadata that no longer matches the tree — before
# a release does. So what the tests check is that it visits every entry, and that it does not report success
# when it visited none or when a build failed.
#
# dpkg-deb is stubbed (absent on macOS), so the packager behaves the same on both platforms; yq is real,
# because reading the manifest is the point.

load ../test_helper

setup() {
  setup_common
  # fake_repo_tool mirrors the real bin/, so the packager and the compiler this walk shells out to are
  # already beside it.
  fake_repo_tool smoke-package-all.sh
  MANIFEST="$FAKE_REPO/scripts.yaml"
  mkdir -p "$FAKE_REPO/scripts/utility"
}

########################################
# Writes a manifest listing the named scripts, and creates each one.
# Arguments:
#   Script names.
########################################
make_manifest() {
  {
    printf 'defaults:\n'
    printf '  author: "Test <test@example.com>"\n'
    printf '  homepage: "https://example.com"\n'
    printf '  license: "MIT"\n'
    printf 'scripts:\n'
    local name
    for name in "$@"; do
      printf '  %s:\n' "$name"
      printf '    path: scripts/utility/%s.sh\n' "$name"
      printf '    description: "Does %s."\n' "$name"
      # Shaped like a real script where it matters here: it holds core.sh's version placeholder and
      # answers with its name and that version.
      printf '#!/usr/bin/env bash\nSCRIPT_VERSION="dev"\necho "%s ${SCRIPT_VERSION}"\n' "$name" > "$FAKE_REPO/scripts/utility/$name.sh"
      chmod +x "$FAKE_REPO/scripts/utility/$name.sh"
    done
  } > "$MANIFEST"
}

########################################
# Runs the walk in the fixture repository.
########################################
smoke_run() {
  run_script "$FAKE_TOOL" "$@"
}

# --- The walk ----------------------------------------------------------------------------------

@test "every manifest entry is packaged" {
  make_manifest alpha beta
  smoke_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Smoke-testing: alpha"* ]]
  [[ "$output" == *"Smoke-testing: beta"* ]]
  [[ "$output" == *"Packaged 2 script(s)."* ]]
}

@test "the artefacts land in the fixture's dist directory" {
  make_manifest alpha
  smoke_run
  [ -f "$FAKE_REPO/dist/homebrew/alpha.rb" ]
  ls "$FAKE_REPO/dist/tarballs"/*alpha*.tar.gz >/dev/null
}

@test "the throwaway version is used by default" {
  make_manifest alpha
  smoke_run
  ls "$FAKE_REPO/dist/tarballs"/*alpha*v0.0.0* >/dev/null
}

@test "an explicit version is honoured" {
  make_manifest alpha
  smoke_run v9.9.9
  ls "$FAKE_REPO/dist/tarballs"/*alpha*v9.9.9* >/dev/null
}

@test "each published script is asked for its version" {
  make_manifest alpha
  smoke_run v1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"Packaged 1 script(s)."* ]]
}

# Stands for a script whose --version is wrong or missing: whatever it prints instead fails the walk.
@test "a published script that misreports its version fails the walk" {
  make_manifest alpha beta
  printf '#!/usr/bin/env bash\nSCRIPT_VERSION="dev"\necho "usage: alpha <dir>"\n' > "$FAKE_REPO/scripts/utility/alpha.sh"
  smoke_run v1.2.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"alpha --version reported 'usage: alpha <dir>', expected 'alpha 1.2.3'."* ]]
  [[ "$output" != *"Smoke-testing: beta"* ]]
}

# A manifest entry whose script is missing is precisely the drift this exists to catch, so it has to fail
# rather than skip.
@test "an entry whose script is missing fails the walk" {
  make_manifest alpha
  rm "$FAKE_REPO/scripts/utility/alpha.sh"
  smoke_run
  [ "$status" -ne 0 ]
}

@test "a manifest listing no scripts is an error rather than a pass" {
  printf 'defaults:\n  author: "T <t@example.com>"\nscripts: {}\n' > "$MANIFEST"
  smoke_run
  [ "$status" -ne 0 ]
  [[ "$output" == *"lists no scripts"* ]]
}

@test "a missing manifest is reported" {
  rm -f "$MANIFEST"
  smoke_run
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest not found"* ]]
}

@test "the walk stops at the first failing build" {
  make_manifest alpha beta
  rm "$FAKE_REPO/scripts/utility/alpha.sh"
  smoke_run
  [ "$status" -ne 0 ]
  [[ "$output" != *"Packaged"* ]]
}

# --- Safety ------------------------------------------------------------------------------------

# The tool resolves the manifest and the packager relative to itself, so a test that reached the real
# repository would package the real scripts into the real dist/.
@test "the repository's own dist directory is untouched" {
  make_manifest alpha
  smoke_run
  [ ! -d "$REPO_ROOT/dist" ] || [ -z "$(find "$REPO_ROOT/dist" -name '*alpha*' -print -quit)" ]
}

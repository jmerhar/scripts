#!/usr/bin/env bats
#
# check-manifest.sh guards the properties that only break at a distance: a non-executable script still
# packages correctly and fails only for someone running it from a checkout, a missing shebang surfaces
# mid-release, a script with no README beside it is linked from the generated indexes to a directory
# that renders nothing, and an unregistered script is simply never published. Each is invisible until it
# is not, which is the whole reason for checking them mechanically.
#
# Runs a copy of the tool in a fake repository, so the fixtures are the manifest and tree it sees.

load ../test_helper

setup() {
  setup_common
  fake_repo_tool check-manifest.sh
  TOOL="$FAKE_TOOL"
  mkdir -p "$FAKE_REPO/scripts/utility" "$FAKE_REPO/scripts/lib"
}

########################################
# Writes a sound script into the fake repository: executable, with a shebang and a README beside it.
#
# Mirrors the real tree, where each script has its own directory under a topic.
# Arguments:
#   name: Script name, created at scripts/utility/<name>/<name>.sh.
########################################
good_script() {
  mkdir -p "$FAKE_REPO/scripts/utility/$1"
  printf '#!/usr/bin/env bash\necho hi\n' > "$FAKE_REPO/scripts/utility/$1/$1.sh"
  chmod +x "$FAKE_REPO/scripts/utility/$1/$1.sh"
  printf '# `%s`\n\nWhat it does.\n' "$1" > "$FAKE_REPO/scripts/utility/$1/README.md"
}

########################################
# Writes a script with the given body, in a sound directory with a README beside it.
#
# Separate from good_script so a test about a bad shebang fails for that reason alone rather than also
# tripping the documentation check.
# Arguments:
#   name: Script name.
#   body: File contents.
########################################
script_with_body() {
  mkdir -p "$FAKE_REPO/scripts/utility/$1"
  printf '%s' "$2" > "$FAKE_REPO/scripts/utility/$1/$1.sh"
  printf '# `%s`\n\nWhat it does.\n' "$1" > "$FAKE_REPO/scripts/utility/$1/README.md"
}

########################################
# Prints the path of a script created by good_script, relative to the repository.
# Arguments:
#   name: Script name.
########################################
script_path() {
  printf 'scripts/utility/%s/%s.sh' "$1" "$1"
}

########################################
# Writes a manifest registering the named scripts, all under scripts/utility.
# Arguments:
#   Script names to register.
########################################
manifest_with() {
  {
    printf 'scripts:\n'
    local name
    for name in "$@"; do
      printf '  %s:\n    path: %s\n    description: "x"\n' "$name" "$(script_path "$name")"
    done
  } > "$FAKE_REPO/scripts.yaml"
}

# --- The happy path ----------------------------------------------------------------------------

@test "passes when every registered script exists, is executable and has a shebang" {
  good_script alpha
  good_script beta
  manifest_with alpha beta
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 2 registered script(s)"* ]]
}

# --- The executable rule -----------------------------------------------------------------------

@test "fails when a registered script is not executable" {
  good_script alpha
  chmod -x "$FAKE_REPO/$(script_path alpha)"
  manifest_with alpha
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/utility/alpha/alpha.sh is not executable"* ]]
}

@test "the executable rule names every offender, not just the first" {
  good_script alpha
  good_script beta
  chmod -x "$FAKE_REPO/$(script_path alpha)" "$FAKE_REPO/$(script_path beta)"
  manifest_with alpha beta
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alpha.sh is not executable"* ]]
  [[ "$output" == *"beta.sh is not executable"* ]]
  [[ "$output" == *"2 manifest problem(s)"* ]]
}

# --- The shebang rule --------------------------------------------------------------------------

@test "fails when a registered script has no shebang" {
  script_with_body alpha 'echo hi'
  chmod +x "$FAKE_REPO/$(script_path alpha)"
  manifest_with alpha
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not start with a shebang"* ]]
}

@test "a script both non-executable and shebangless is reported once, for both reasons" {
  script_with_body alpha 'echo hi'
  chmod -x "$FAKE_REPO/$(script_path alpha)"
  manifest_with alpha
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not executable"* ]]
  [[ "$output" == *"does not start with a shebang"* ]]
  [[ "$output" == *"1 manifest problem(s)"* ]]
}

# --- The documentation rule --------------------------------------------------------------------

# The generated indexes link a script to its directory, and GitHub renders a directory by showing its
# README. Without one the link resolves and displays nothing, which no amount of generating the indexes
# from the manifest would catch.
@test "fails when a registered script has no README beside it" {
  good_script alpha
  rm "$FAKE_REPO/scripts/utility/alpha/README.md"
  manifest_with alpha
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/utility/alpha/README.md is missing"* ]]
  [[ "$output" == *"renders no documentation"* ]]
}

# A README for one script says nothing about another's, so the check is per directory rather than per
# topic.
@test "a README beside one script does not satisfy another" {
  good_script alpha
  good_script beta
  rm "$FAKE_REPO/scripts/utility/beta/README.md"
  manifest_with alpha beta
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/utility/beta/README.md is missing"* ]]
  [[ "$output" != *"scripts/utility/alpha/README.md is missing"* ]]
}

# --- Missing and malformed entries -------------------------------------------------------------

@test "fails when a registered path does not exist" {
  manifest_with ghost
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"points to missing file: scripts/utility/ghost/ghost.sh"* ]]
}

@test "fails when an entry has no path at all" {
  printf 'scripts:\n  alpha:\n    description: "no path"\n' > "$FAKE_REPO/scripts.yaml"
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no path"* ]]
}

@test "reports a missing manifest" {
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Manifest not found:"* ]]
}

# --- The library rule --------------------------------------------------------------------------

@test "fails when the shared library is marked executable" {
  good_script alpha
  manifest_with alpha
  printf '# shellcheck shell=bash\n' > "$FAKE_REPO/scripts/lib/common.sh"
  chmod +x "$FAKE_REPO/scripts/lib/common.sh"
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is executable, but the library is sourced, not run"* ]]
}

@test "passes with a non-executable shared library" {
  good_script alpha
  manifest_with alpha
  printf '# shellcheck shell=bash\n' > "$FAKE_REPO/scripts/lib/common.sh"
  chmod -x "$FAKE_REPO/scripts/lib/common.sh"
  run_script "$TOOL"
  [ "$status" -eq 0 ]
}

@test "passes when there is no library directory at all" {
  good_script alpha
  manifest_with alpha
  rmdir "$FAKE_REPO/scripts/lib"
  run_script "$TOOL"
  [ "$status" -eq 0 ]
}

# --- Unregistered scripts ----------------------------------------------------------------------

# A warning rather than an error: work in progress under scripts/ is legitimate, and so is the harness
# run-coverage.sh places there for the duration of a run.
@test "warns about an unregistered script without failing" {
  good_script alpha
  good_script stray
  manifest_with alpha
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/utility/stray/stray.sh is not registered"* ]]
}

@test "does not warn about the shared library" {
  good_script alpha
  manifest_with alpha
  printf '# shellcheck shell=bash\n' > "$FAKE_REPO/scripts/lib/common.sh"
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" != *"common.sh is not registered"* ]]
}

@test "does not warn about a config file beside a script" {
  good_script alpha
  manifest_with alpha
  printf 'SETTING=1\n' > "$FAKE_REPO/scripts/utility/alpha/alpha.conf"
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" != *"alpha.conf"* ]]
}

# --- CI annotations ----------------------------------------------------------------------------

@test "emits GitHub Actions annotations when running under Actions" {
  good_script alpha
  chmod -x "$FAKE_REPO/$(script_path alpha)"
  manifest_with alpha
  GITHUB_ACTIONS=true run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
}

# GITHUB_ACTIONS is set for the whole job when the suite runs in CI, so it has to be cleared explicitly
# rather than assumed absent — otherwise this passes only on a developer machine.
@test "emits no annotations outside Actions" {
  good_script alpha
  chmod -x "$FAKE_REPO/$(script_path alpha)"
  manifest_with alpha
  GITHUB_ACTIONS= run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not executable"* ]]
  [[ "$output" != *"::error::"* ]]
}

# --- Usage and against the real manifest -------------------------------------------------------

@test "shows usage on request" {
  run_script "$TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: check-manifest.sh"* ]]
}

# The check earns its place only if it holds for this repository; a failure here means a published
# script cannot be run from a checkout.
@test "this repository's own manifest passes" {
  run_script "$REPO_ROOT/bin/lint/check-manifest.sh"
  [ "$status" -eq 0 ]
}

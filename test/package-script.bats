#!/usr/bin/env bats
#
# package-script.sh turns a manifest entry into the three release artefacts. It runs only at release
# time, so a fault here is discovered by whoever installs the result — a wrong dependency, a bad
# formula class name or a missing config file is not visible until then.
#
# Every test runs a copy of the tool inside a fake repository, so it reads a fixture manifest and
# writes into the test's own directory rather than the real dist/. dpkg-deb is stubbed, which is what
# makes the Debian half testable at all: the real tool does not exist on macOS, and the script
# silently skips .deb generation when it cannot find it.

load test_helper

setup() {
  setup_common
  fake_repo_tool package-script.sh
  TOOL="$FAKE_TOOL"
  mkdir -p "$FAKE_REPO/scripts/utility"
  printf '#!/usr/bin/env bash\necho hello\n' > "$FAKE_REPO/scripts/utility/my-tool.sh"
}

########################################
# Writes the fake repository's manifest.
# Inputs:
#   The manifest YAML, read from stdin.
########################################
manifest() {
  cat > "$FAKE_REPO/scripts.yaml"
}

########################################
# Writes a manifest describing a single script, with optional extra per-script keys.
# Arguments:
#   Extra YAML lines to nest under the script entry, already indented.
########################################
default_manifest() {
  {
    cat <<'EOF'
defaults:
  author: "Test Author <test@example.com>"
  homepage: "https://github.com/example/scripts"
  license: "MIT"

scripts:
  my-tool:
    path: scripts/utility/my-tool.sh
    description: "Does a thing."
EOF
    printf '%s\n' "$@"
  } > "$FAKE_REPO/scripts.yaml"
}

# --- Argument and manifest validation ----------------------------------------------------------

@test "refuses to run without both arguments" {
  default_manifest
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected exactly 2 arguments"* ]]

  run_script "$TOOL" my-tool
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected exactly 2 arguments"* ]]
}

@test "reports a missing manifest" {
  run_script "$TOOL" my-tool v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Manifest not found:"* ]]
}

@test "reports a script that is not in the manifest" {
  default_manifest
  run_script "$TOOL" absent-tool v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Script 'absent-tool' not found in manifest."* ]]
}

@test "reports a manifest entry whose file is missing" {
  manifest <<'EOF'
defaults:
  author: "A <a@example.com>"
  homepage: "https://example.com"
  license: "MIT"
scripts:
  my-tool:
    path: scripts/utility/gone.sh
    description: "Does a thing."
EOF
  run_script "$TOOL" my-tool v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"Script file not found:"*"gone.sh"* ]]
}

# --- Tarball -----------------------------------------------------------------------------------

@test "creates a versioned tarball containing the script" {
  default_manifest
  run_script "$TOOL" my-tool v1.2.3
  [ "$status" -eq 0 ]
  [ -f "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.2.3.tar.gz" ]
  run tar -tzf "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.2.3.tar.gz"
  [[ "$output" == *"scripts-my-tool-v1.2.3/my-tool.sh"* ]]
}

@test "includes an adjacent config file, discovered by convention" {
  default_manifest
  printf 'SETTING=value\n' > "$FAKE_REPO/scripts/utility/my-tool.conf"
  run_script "$TOOL" my-tool v1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found config file:"* ]]
  run tar -tzf "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.0.0.tar.gz"
  [[ "$output" == *"my-tool.conf"* ]]
}

@test "omits a config file named after something other than the script" {
  default_manifest
  printf 'SETTING=value\n' > "$FAKE_REPO/scripts/utility/unrelated.conf"
  run_script "$TOOL" my-tool v1.0.0
  run tar -tzf "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.0.0.tar.gz"
  [[ "$output" != *"unrelated.conf"* ]]
}

# --- Homebrew formula --------------------------------------------------------------------------

@test "writes a formula with the metadata from the manifest" {
  default_manifest
  run_script "$TOOL" my-tool v1.2.3
  [ "$status" -eq 0 ]
  local formula="$FAKE_REPO/dist/homebrew/my-tool.rb"
  [ -f "$formula" ]
  run cat "$formula"
  [[ "$output" == *'desc "Does a thing."'* ]]
  [[ "$output" == *'homepage "https://github.com/example/scripts"'* ]]
  [[ "$output" == *'license "MIT"'* ]]
}

@test "the formula version drops the tag's v prefix" {
  default_manifest
  run_script "$TOOL" my-tool v1.2.3
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *'version "1.2.3"'* ]]
}

@test "the formula class name is the script name in CamelCase" {
  default_manifest
  run_script "$TOOL" my-tool v1.0.0
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *"class MyTool < Formula"* ]]
}

@test "the formula URL points at the matching release tag" {
  default_manifest
  run_script "$TOOL" my-tool v1.2.3
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *'url "https://github.com/example/scripts/releases/download/my-tool-v1.2.3/scripts-my-tool-v1.2.3.tar.gz"'* ]]
}

@test "the formula checksum matches the tarball that was built" {
  default_manifest
  run_script "$TOOL" my-tool v1.0.0
  local tarball="$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.0.0.tar.gz"
  local expected
  # Same order of preference as the script, so this holds on Linux and macOS alike.
  if command -v sha256sum >/dev/null 2>&1; then
    expected=$(sha256sum "$tarball" | awk '{print $1}')
  else
    expected=$(shasum -a 256 "$tarball" | awk '{print $1}')
  fi
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *"sha256 \"${expected}\""* ]]
}

@test "the formula installs the script under its published name" {
  default_manifest
  run_script "$TOOL" my-tool v1.0.0
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *'bin.install "my-tool.sh" => "my-tool"'* ]]
}

@test "the formula installs a config file when there is one" {
  default_manifest
  printf 'SETTING=value\n' > "$FAKE_REPO/scripts/utility/my-tool.conf"
  run_script "$TOOL" my-tool v1.0.0
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *'etc.install "my-tool.conf" => "my-tool.conf"'* ]]
}

@test "the formula has no etc.install line without a config file" {
  default_manifest
  run_script "$TOOL" my-tool v1.0.0
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" != *"etc.install"* ]]
}

@test "the formula lists common and homebrew dependencies, and no debian ones" {
  default_manifest '    dependencies:' '      common: [jq]' '      homebrew: [coreutils]' '      debian: [libjq1]'
  run_script "$TOOL" my-tool v1.0.0
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *'depends_on "jq"'* ]]
  [[ "$output" == *'depends_on "coreutils"'* ]]
  [[ "$output" != *"libjq1"* ]]
}

@test "a description containing quotes is escaped for the formula" {
  manifest <<'EOF'
defaults:
  author: "A <a@example.com>"
  homepage: "https://example.com"
  license: "MIT"
scripts:
  my-tool:
    path: scripts/utility/my-tool.sh
    description: 'Handles "quoted" text.'
EOF
  run_script "$TOOL" my-tool v1.0.0
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *'desc "Handles \"quoted\" text."'* ]]
}

# --- Debian package ----------------------------------------------------------------------------

@test "builds a versioned deb and hands the staging tree to dpkg-deb" {
  default_manifest
  run_script "$TOOL" my-tool v1.2.3
  [ "$status" -eq 0 ]
  [ -f "$FAKE_REPO/dist/debian/my-tool_1.2.3_all.deb" ]
  stub_called "dpkg-deb --root-owner-group --build"
}

@test "the deb control file carries the manifest metadata" {
  default_manifest
  run_script "$TOOL" my-tool v1.2.3
  run cat "$STUB_FIXTURES/dpkg-deb.control"
  [[ "$output" == *"Package: my-tool"* ]]
  [[ "$output" == *"Version: 1.2.3"* ]]
  [[ "$output" == *"Architecture: all"* ]]
  [[ "$output" == *"Maintainer: Test Author <test@example.com>"* ]]
  [[ "$output" == *"Homepage: https://github.com/example/scripts"* ]]
  [[ "$output" == *"Description: Does a thing."* ]]
}

@test "the deb merges common and debian dependencies, and no homebrew ones" {
  default_manifest '    dependencies:' '      common: [jq]' '      homebrew: [coreutils]' '      debian: [libjq1]'
  run_script "$TOOL" my-tool v1.0.0
  run cat "$STUB_FIXTURES/dpkg-deb.control"
  [[ "$output" == *"Depends: jq, libjq1"* ]]
  [[ "$output" != *"coreutils"* ]]
}

@test "the deb omits the Depends field when nothing is required" {
  default_manifest
  run_script "$TOOL" my-tool v1.0.0
  run cat "$STUB_FIXTURES/dpkg-deb.control"
  [[ "$output" != *"Depends:"* ]]
}

@test "the deb installs the script into usr/local/bin under its published name" {
  default_manifest
  run_script "$TOOL" my-tool v1.0.0
  run cat "$STUB_FIXTURES/dpkg-deb.contents"
  [[ "$output" == *"./usr/local/bin/my-tool"* ]]
}

@test "the deb registers a config file as a conffile so upgrades keep local edits" {
  default_manifest
  printf 'SETTING=value\n' > "$FAKE_REPO/scripts/utility/my-tool.conf"
  run_script "$TOOL" my-tool v1.0.0
  run cat "$STUB_FIXTURES/dpkg-deb.conffiles"
  [ "$output" = "/usr/local/etc/my-tool.conf" ]
  run cat "$STUB_FIXTURES/dpkg-deb.contents"
  [[ "$output" == *"./usr/local/etc/my-tool.conf"* ]]
}

@test "the deb has no conffiles entry without a config file" {
  default_manifest
  run_script "$TOOL" my-tool v1.0.0
  [ ! -f "$STUB_FIXTURES/dpkg-deb.conffiles" ]
}

# --- The platforms filter ----------------------------------------------------------------------

@test "publishing to both channels is the default" {
  default_manifest
  run_script "$TOOL" my-tool v1.0.0
  [ -f "$FAKE_REPO/dist/homebrew/my-tool.rb" ]
  [ -f "$FAKE_REPO/dist/debian/my-tool_1.0.0_all.deb" ]
}

@test "platforms debian skips the Homebrew formula" {
  default_manifest '    platforms: [debian]'
  run_script "$TOOL" my-tool v1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping Homebrew formula"* ]]
  [ ! -f "$FAKE_REPO/dist/homebrew/my-tool.rb" ]
  [ -f "$FAKE_REPO/dist/debian/my-tool_1.0.0_all.deb" ]
}

@test "platforms homebrew skips the Debian package" {
  default_manifest '    platforms: [homebrew]'
  run_script "$TOOL" my-tool v1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping Debian package"* ]]
  [ -f "$FAKE_REPO/dist/homebrew/my-tool.rb" ]
  [ ! -f "$FAKE_REPO/dist/debian/my-tool_1.0.0_all.deb" ]
  [ "$(stub_calls dpkg-deb)" -eq 0 ]
}

# --- Pieces worth checking directly ------------------------------------------------------------

@test "find_config_file reports an adjacent config and nothing otherwise" {
  printf 'x\n' > "$FAKE_REPO/scripts/utility/my-tool.conf"
  run_func "$TOOL" find_config_file "$FAKE_REPO/scripts/utility" my-tool
  [ "$output" = "$FAKE_REPO/scripts/utility/my-tool.conf" ]
  run_func "$TOOL" find_config_file "$FAKE_REPO/scripts/utility" other-tool
  [ -z "$output" ]
}

@test "build_tarball_url follows the per-script tag convention" {
  run_func "$TOOL" build_tarball_url "https://example.com/repo" my-tool v2.0.0
  [ "$output" = "https://example.com/repo/releases/download/my-tool-v2.0.0/scripts-my-tool-v2.0.0.tar.gz" ]
}

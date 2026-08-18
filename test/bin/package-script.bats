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

load ../test_helper

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

# --- The minimum bash version ------------------------------------------------------------------

# The manifest value drives three separate things, and the point of deriving them from one field is
# that they cannot disagree: the guard compiled into the script, the versioned Debian dependency, and
# the Homebrew dependency plus shebang rewrite.

@test "a script with no min_bash gets no guard and no bash dependency" {
  default_manifest
  run_script "$TOOL" my-tool v1.0.0
  [ "$status" -eq 0 ]
  run tar -xzOf "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.0.0.tar.gz" scripts-my-tool-v1.0.0/my-tool.sh
  [[ "$output" != *"BASH_VERSINFO"* ]]
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" != *'depends_on "bash"'* ]]
  [[ "$output" != *"inreplace"* ]]
  run cat "$STUB_FIXTURES/dpkg-deb.control"
  [[ "$output" != *"bash"* ]]
}

@test "min_bash compiles a version guard into the published script" {
  default_manifest '    min_bash: "4.3"'
  run_script "$TOOL" my-tool v1.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"compiling a version guard"* ]]
  run tar -xzOf "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.0.0.tar.gz" scripts-my-tool-v1.0.0/my-tool.sh
  [[ "$output" == *"BASH_VERSINFO[0] < 4"* ]]
  [[ "$output" == *"BASH_VERSINFO[1] < 3"* ]]
  [[ "$output" == *"requires bash 4.3 or newer"* ]]
}

# Asserted against the file's real line numbers rather than bats' `lines` array, which drops blank
# lines and so cannot express "directly after the shebang".
@test "the guard sits directly after the shebang, ahead of anything it must protect" {
  default_manifest '    min_bash: "4.0"'
  run_script "$TOOL" my-tool v1.0.0
  local published="$BATS_TEST_TMPDIR/published.sh"
  tar -xzOf "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.0.0.tar.gz" \
    scripts-my-tool-v1.0.0/my-tool.sh > "$published"
  [ "$(sed -n '1p' "$published")" = "#!/usr/bin/env bash" ]
  [[ "$(sed -n '3p' "$published")" == "# Requires bash 4.0"* ]]
  [[ "$(sed -n '5p' "$published")" == "if (( BASH_VERSINFO"* ]]
}

########################################
# Packages my-tool and prints the path of the published script it produced.
# Extracted under its published basename, so a message the guard builds from `basename "$0"` reads as
# it would for a user running the installed script.
# Arguments:
#   Extra manifest lines for the entry, as default_manifest takes them.
# Outputs:
#   Prints the path of the extracted published script.
########################################
publish_and_extract() {
  default_manifest "$@"
  run_script "$TOOL" my-tool v1.0.0
  [ "$status" -eq 0 ] || { echo "packaging failed: $output" >&2; return 1; }
  local dir="$BATS_TEST_TMPDIR/published"
  mkdir -p "$dir"
  tar -xzOf "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.0.0.tar.gz" \
    scripts-my-tool-v1.0.0/my-tool.sh > "$dir/my-tool.sh"
  printf '%s' "$dir/my-tool.sh"
}

@test "the published script is syntactically valid" {
  local published; published=$(publish_and_extract '    min_bash: "4.0"')
  run bash -n "$published"
  [ "$status" -eq 0 ]
}

# The guard is asserted against a version it cannot satisfy rather than against an old interpreter.
# Demanding a version no bash has makes the refusal reproducible on any machine — testing it by running
# /bin/bash would only ever assert whatever that happens to be, and would silently assert nothing
# wherever /bin/bash is current.
@test "the guard refuses a bash older than required" {
  local published; published=$(publish_and_extract '    min_bash: "99.0"')
  run bash "$published" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires bash 99.0 or newer"* ]]
  [[ "$output" == *"running ${BASH_VERSION}"* ]]
}

@test "the guard names the running version in its refusal" {
  local published; published=$(publish_and_extract '    min_bash: "99.9"')
  run bash "$published"
  [[ "$output" == *"my-tool.sh requires bash 99.9 or newer"* ]]
}

@test "the guard lets a satisfied requirement through to the script" {
  local published; published=$(publish_and_extract '    min_bash: "4.0"')
  run bash "$published"
  [ "$status" -eq 0 ]
  # my-tool.sh's whole body is `echo hello`, so reaching it proves the guard stood aside.
  [ "$output" = "hello" ]
}

@test "the guard compares the minor version, not just the major" {
  # A guard checking only the major would let this through on any bash 5.
  local published; published=$(publish_and_extract "    min_bash: \"${BASH_VERSINFO[0]}.99\"")
  run bash "$published"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires bash ${BASH_VERSINFO[0]}.99 or newer"* ]]
}

# A guard written with a bash 4 construct would still run on bash 5, so no amount of running it here
# would reveal the problem. The detector that check-bash-version.sh uses on the scripts is applied to
# the guard itself: it must need nothing beyond baseline bash.
@test "the guard itself uses no feature newer than the bash it rejects" {
  local published; published=$(publish_and_extract '    min_bash: "4.3"')
  # The guard is the block between the shebang and the script's own body.
  sed -n "2,9p" "$published" > "$BATS_TEST_TMPDIR/guard-only.sh"
  grep -q 'BASH_VERSINFO' "$BATS_TEST_TMPDIR/guard-only.sh"

  run_func "$REPO_ROOT/bin/lint/check-bash-version.sh" required_version "$BATS_TEST_TMPDIR/guard-only.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# The only assertion that runs a genuinely old bash. A pinned image is a known version, unlike
# /bin/bash; skipped where Docker is unavailable rather than quietly asserting nothing.
@test "the guard refuses bash 3.2 in practice" {
  command -v docker >/dev/null 2>&1 || skip "docker not available to run a pinned old bash"
  docker info >/dev/null 2>&1 || skip "docker not running"
  local published; published=$(publish_and_extract '    min_bash: "4.0"')
  run docker run --rm -v "$published:/published.sh:ro" bash:3.2 bash /published.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires bash 4.0 or newer"* ]]
  [[ "$output" == *"running 3.2"* ]]
}

@test "every channel ships the same guarded content" {
  default_manifest '    min_bash: "4.0"'
  run_script "$TOOL" my-tool v1.0.0
  tar -xzOf "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.0.0.tar.gz" \
    scripts-my-tool-v1.0.0/my-tool.sh > "$BATS_TEST_TMPDIR/from-tarball"
  # The deb stub records the staging tree, so the installed copy can be compared against it.
  run grep -c 'usr/local/bin/my-tool' "$STUB_FIXTURES/dpkg-deb.contents"
  [ "$output" -eq 1 ]
  run grep -c 'BASH_VERSINFO' "$BATS_TEST_TMPDIR/from-tarball"
  [ "$output" -eq 1 ]
}

@test "min_bash becomes a versioned Debian dependency" {
  default_manifest '    min_bash: "4.3"'
  run_script "$TOOL" my-tool v1.0.0
  run cat "$STUB_FIXTURES/dpkg-deb.control"
  [[ "$output" == *"Depends: bash (>= 4.3)"* ]]
}

@test "the bash dependency merges with the script's own Debian dependencies" {
  default_manifest '    min_bash: "4.0"' '    dependencies:' '      common: [jq]' '      debian: [libjq1]'
  run_script "$TOOL" my-tool v1.0.0
  run cat "$STUB_FIXTURES/dpkg-deb.control"
  [[ "$output" == *"Depends: bash (>= 4.0), jq, libjq1"* ]]
}

@test "min_bash becomes a plain Homebrew dependency, since it has no version constraints" {
  default_manifest '    min_bash: "4.3"'
  run_script "$TOOL" my-tool v1.0.0
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *'depends_on "bash"'* ]]
  # There is no versioned bash formula to point at, so the version must not appear here.
  [[ "$output" != *'depends_on "bash@'* ]]
}

# env bash resolves through PATH, and a launchd or cron job has no Homebrew directory on its PATH —
# so on macOS it would find the 3.2 in /bin. The rewrite is what makes the dependency effective.
@test "the formula repoints the shebang at the brewed bash" {
  default_manifest '    min_bash: "4.0"'
  run_script "$TOOL" my-tool v1.0.0
  run cat "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [[ "$output" == *'inreplace bin/"my-tool"'* ]]
  [[ "$output" == *'%r{^#!/usr/bin/env bash$}'* ]]
  [[ "$output" == *'"#!#{Formula["bash"].opt_bin}/bash"'* ]]
}

@test "the generated formula is valid Ruby" {
  default_manifest '    min_bash: "4.0"' '    dependencies:' '      common: [jq]'
  run_script "$TOOL" my-tool v1.0.0
  if ! command -v ruby >/dev/null 2>&1; then
    skip "ruby not available to syntax-check the formula"
  fi
  run ruby -c "$FAKE_REPO/dist/homebrew/my-tool.rb"
  [ "$status" -eq 0 ]
}

@test "a major-only min_bash is treated as major.0" {
  default_manifest '    min_bash: "5"'
  run_script "$TOOL" my-tool v1.0.0
  [ "$status" -eq 0 ]
  run tar -xzOf "$FAKE_REPO/dist/tarballs/scripts-my-tool-v1.0.0.tar.gz" scripts-my-tool-v1.0.0/my-tool.sh
  [[ "$output" == *"BASH_VERSINFO[0] < 5"* ]]
  [[ "$output" == *"BASH_VERSINFO[1] < 0"* ]]
}

@test "prepare_script refuses a file with no shebang, rather than guarding the wrong line" {
  printf 'echo no shebang here\n' > "$FAKE_REPO/scripts/utility/headless.sh"
  run_func "$TOOL" prepare_script "$FAKE_REPO/scripts/utility/headless.sh" "4.0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not start with a shebang"* ]]
}

@test "prepare_script copies a script through untouched when nothing is required" {
  run_func "$TOOL" prepare_script "$FAKE_REPO/scripts/utility/my-tool.sh" ""
  [ "$status" -eq 0 ]
  run diff "$output" "$FAKE_REPO/scripts/utility/my-tool.sh"
  [ "$status" -eq 0 ]
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


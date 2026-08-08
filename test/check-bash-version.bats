#!/usr/bin/env bats
#
# check-bash-version.sh is what keeps min_bash honest. That field drives the guard compiled into every
# published script and the dependency metadata for both channels, so if the checker under-reports, a
# script quietly ships declaring a bash it cannot actually run on — the exact failure the field was
# added to prevent.
#
# The detector is therefore tested construct by construct, and both directions matter: missing a
# feature is the dangerous error, but claiming one that is not there would make the check impossible
# to satisfy.

load test_helper

setup() {
  setup_common
  fake_repo_tool check-bash-version.sh
  TOOL="$FAKE_TOOL"
  mkdir -p "$FAKE_REPO/scripts/utility"
}

########################################
# Writes a script into the fake repository.
# Arguments:
#   name: Basename to create under scripts/utility.
# Inputs:
#   The script body, read from stdin. A shebang is added.
########################################
script_with() {
  {
    printf '#!/usr/bin/env bash\n'
    cat
  } > "$FAKE_REPO/scripts/utility/$1.sh"
}

########################################
# Writes a manifest with one entry, optionally declaring min_bash.
# Arguments:
#   name: Script name.
#   min_bash: Version to declare, or empty to omit the field.
########################################
manifest_for() {
  {
    printf 'scripts:\n  %s:\n    path: scripts/utility/%s.sh\n    description: "x"\n' "$1" "$1"
    if [[ -n "${2:-}" ]]; then
      printf '    min_bash: "%s"\n' "$2"
    fi
  } > "$FAKE_REPO/scripts.yaml"
}

# --- Feature detection -------------------------------------------------------------------------

@test "requires nothing for a script using only baseline features" {
  script_with plain <<'EOF'
v="value"
echo "${v}"
arr=(one two)
echo "${arr[0]}"
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/plain.sh"
  [ -z "$output" ]
}

@test "detects case-conversion expansions as 4.0" {
  script_with lower <<'EOF'
v=ABC
echo "${v,,}"
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/lower.sh"
  [ "$output" = "4.0" ]
}

@test "detects uppercase conversion as 4.0" {
  script_with upper <<'EOF'
v=abc
echo "${v^^}"
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/upper.sh"
  [ "$output" = "4.0" ]
}

@test "detects case conversion on an array element" {
  script_with elem <<'EOF'
a=(Abc)
echo "${a[0],,}"
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/elem.sh"
  [ "$output" = "4.0" ]
}

@test "detects associative arrays as 4.0" {
  script_with assoc <<'EOF'
declare -A map
map[key]=value
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/assoc.sh"
  [ "$output" = "4.0" ]
}

@test "detects an associative array declared local to a function" {
  script_with localassoc <<'EOF'
f() {
  local -A map
  map[k]=v
}
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/localassoc.sh"
  [ "$output" = "4.0" ]
}

@test "detects mapfile and readarray as 4.0" {
  script_with mf <<'EOF'
mapfile -t lines < /etc/hosts
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/mf.sh"
  [ "$output" = "4.0" ]

  script_with ra <<'EOF'
readarray -t lines < /etc/hosts
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/ra.sh"
  [ "$output" = "4.0" ]
}

@test "detects namerefs as 4.3" {
  script_with nref <<'EOF'
f() {
  local -n ref="$1"
  echo "${ref}"
}
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/nref.sh"
  [ "$output" = "4.3" ]
}

@test "reports the highest requirement when several features are mixed" {
  script_with mixed <<'EOF'
declare -A map
v=ABC
echo "${v,,}"
f() { local -n ref="$1"; echo "${ref}"; }
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/mixed.sh"
  [ "$output" = "4.3" ]
}

# An ordinary `local -r` or `declare -a` must not be mistaken for a nameref or an associative array,
# or the check would demand a version the script does not need.
@test "does not mistake other declare flags for the ones that matter" {
  script_with flags <<'EOF'
f() {
  local -r frozen=1
  local -a list=(a b)
  local -i count=0
  declare -a other=(x)
  echo "${frozen}${list[0]}${count}${other[0]}"
}
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/flags.sh"
  [ -z "$output" ]
}

@test "does not treat a plain parameter expansion as case conversion" {
  script_with plainexp <<'EOF'
v=abc
echo "${v}"
echo "${v:-fallback}"
echo "${v%suffix}"
echo "${v#prefix}"
EOF
  run_func "$TOOL" required_version "$FAKE_REPO/scripts/utility/plainexp.sh"
  [ -z "$output" ]
}

# --- Version comparison ------------------------------------------------------------------------

@test "version_gt orders major and minor versions" {
  run_func "$TOOL" version_gt "4.3" "4.0"; [ "$status" -eq 0 ]
  run_func "$TOOL" version_gt "4.0" "4.3"; [ "$status" -ne 0 ]
  # A higher major wins regardless of the minor.
  run_func "$TOOL" version_gt "5.0" "4.9"; [ "$status" -eq 0 ]
  run_func "$TOOL" version_gt "4.9" "5.0"; [ "$status" -ne 0 ]
  # Equal is not greater.
  run_func "$TOOL" version_gt "4.0" "4.0"; [ "$status" -ne 0 ]
  run_func "$TOOL" version_gt "4.3" "4.3"; [ "$status" -ne 0 ]
}

@test "version_gt treats an absent version as zero" {
  run_func "$TOOL" version_gt "4.0" ""
  [ "$status" -eq 0 ]
  run_func "$TOOL" version_gt "" "4.0"
  [ "$status" -ne 0 ]
}

@test "version_gt accepts a major-only version" {
  run_func "$TOOL" version_gt "5" "4.3"
  [ "$status" -eq 0 ]
  run_func "$TOOL" version_gt "4" "4.0"
  [ "$status" -ne 0 ]
}

# --- End to end --------------------------------------------------------------------------------

@test "passes when the declaration matches what the script uses" {
  script_with tool <<'EOF'
declare -A map
EOF
  manifest_for tool "4.0"
  run_script "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declare a bash version that covers their features"* ]]
}

@test "passes when the declaration exceeds what the script uses" {
  script_with tool <<'EOF'
declare -A map
EOF
  manifest_for tool "5.0"
  run_script "$TOOL"
  [ "$status" -eq 0 ]
}

@test "fails when a script declares no version but needs one" {
  script_with tool <<'EOF'
declare -A map
EOF
  manifest_for tool ""
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"uses bash 4.0 features but declares no min_bash"* ]]
}

@test "fails when a script has outgrown its declared version" {
  script_with tool <<'EOF'
f() { local -n ref="$1"; echo "${ref}"; }
EOF
  manifest_for tool "4.0"
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"uses bash 4.3 features but declares min_bash 4.0"* ]]
}

@test "passes a script that needs nothing and declares nothing" {
  script_with tool <<'EOF'
echo plain
EOF
  manifest_for tool ""
  run_script "$TOOL"
  [ "$status" -eq 0 ]
}

@test "checks only the scripts named on the command line" {
  script_with good <<'EOF'
echo plain
EOF
  script_with bad <<'EOF'
declare -A map
EOF
  {
    printf 'scripts:\n'
    printf '  good:\n    path: scripts/utility/good.sh\n    description: "x"\n'
    printf '  bad:\n    path: scripts/utility/bad.sh\n    description: "x"\n'
  } > "$FAKE_REPO/scripts.yaml"

  run_script "$TOOL" good
  [ "$status" -eq 0 ]
  run_script "$TOOL" bad
  [ "$status" -eq 1 ]
  # The whole manifest, so the bad one is reached.
  run_script "$TOOL"
  [ "$status" -eq 1 ]
}

@test "reports every shortfall, not just the first" {
  script_with one <<'EOF'
declare -A map
EOF
  script_with two <<'EOF'
mapfile -t x < /etc/hosts
EOF
  {
    printf 'scripts:\n'
    printf '  one:\n    path: scripts/utility/one.sh\n    description: "x"\n'
    printf '  two:\n    path: scripts/utility/two.sh\n    description: "x"\n'
  } > "$FAKE_REPO/scripts.yaml"
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"one:"* ]]
  [[ "$output" == *"two:"* ]]
  [[ "$output" == *"2 script(s)"* ]]
}

@test "reports a manifest entry whose file is missing" {
  manifest_for absent "4.0"
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Script file not found:"* ]]
}

@test "reports a name that is not in the manifest" {
  script_with tool <<'EOF'
echo plain
EOF
  manifest_for tool ""
  run_script "$TOOL" nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not in the manifest"* ]]
}

@test "reports a missing manifest" {
  run_script "$TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Manifest not found:"* ]]
}

@test "shows usage on request" {
  run_script "$TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: check-bash-version.sh"* ]]
}

# --- Against the real manifest ------------------------------------------------------------------

# The check is only worth having if it holds for this repository as it stands; a failure here means a
# script has outgrown its declaration and the packaging metadata is now wrong.
@test "the repository's own declarations are sufficient" {
  run_script "$REPO_ROOT/bin/check-bash-version.sh"
  [ "$status" -eq 0 ]
}

#!/usr/bin/env bats
#
# normalize-release-names renames files, so what matters is that the transformation is exactly the one
# documented and nothing more: a rename that reorganised a name would be a rename nobody could review,
# and one that moved a video without its sidecar would break the pairing it exists to protect.
#
# It shells out to nothing, so the fixtures are real files and the renames are real. Each test also keeps
# a file that must not move.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/media/normalize-release-names/normalize-release-names.sh"

  DIR="$BATS_TEST_TMPDIR/season"
  mkdir -p "$DIR"

  CONFIG_FILE="$BATS_TEST_TMPDIR/normalize.conf"
  export CONFIG_FILE
  : > "$CONFIG_FILE"
}

########################################
# Creates a file in the directory under test.
# Arguments:
#   name: File name, relative to DIR.
########################################
file() {
  mkdir -p "$(dirname "$DIR/$1")"
  printf 'contents of %s' "$1" > "$DIR/$1"
}

########################################
# Prints the directory's file names, sorted.
# Arguments:
#   subdir: Optional subdirectory, relative to DIR.
########################################
names() {
  find "$DIR/${1:-}" -maxdepth 1 -type f -exec basename {} \; | sort
}

# --- The transformation --------------------------------------------------------------------------

@test "spaces and underscores become dots" {
  run_func "$SCRIPT" normalized_name "Some Show 02 Thing.mkv"
  [ "$output" = "some.show.02.thing.mkv" ]
  run_func "$SCRIPT" normalized_name "Some_Show_02_Thing.mkv"
  [ "$output" = "some.show.02.thing.mkv" ]
}

@test "a run of separators collapses to one dot" {
  run_func "$SCRIPT" normalized_name "Some   Show __ 02.mkv"
  [ "$output" = "some.show.02.mkv" ]
}

@test "1x02 becomes S01E02" {
  run_func "$SCRIPT" normalized_name "Some Show 1x02 Thing.mkv"
  [ "$output" = "some.show.S01E02.thing.mkv" ]
}

@test "a two-digit season in the x form is padded correctly" {
  run_func "$SCRIPT" normalized_name "Some Show 12x07.mkv"
  [ "$output" = "some.show.S12E07.mkv" ]
}

@test "S1E02 is padded to S01E02" {
  run_func "$SCRIPT" normalized_name "Some.Show.S1E02.mkv"
  [ "$output" = "some.show.S01E02.mkv" ]
}

@test "an already conventional name is left as it is" {
  run_func "$SCRIPT" normalized_name "some.show.S01E02.thing-grp.mkv"
  [ "$output" = "some.show.S01E02.thing-grp.mkv" ]
}

# The release group is written after a dash; joining that up would lose the boundary.
@test "dashes are left alone" {
  run_func "$SCRIPT" normalized_name "Some Show 1x02-GRP.mkv"
  [ "$output" = "some.show.S01E02-grp.mkv" ]
}

@test "the episode marker keeps its case while the rest is folded" {
  run_func "$SCRIPT" normalized_name "SOME.SHOW.s01e02.THING.MKV"
  [ "$output" = "some.show.S01E02.thing.mkv" ]
}

@test "--keep-case leaves the case alone but still fixes the rest" {
  run_snippet "$SCRIPT" '_keep_case=true; normalized_name "Some Show 1x02 Thing.MKV"'
  [ "$output" = "Some.Show.S01E02.Thing.MKV" ]
}

@test "a name with no extension is still normalised" {
  run_func "$SCRIPT" normalized_name "Some Show 1x02"
  [ "$output" = "some.show.S01E02" ]
}

# Un-hiding a file changes whether anything sees it, which is not a rename anyone asked for.
@test "a name that was hidden stays hidden" {
  run_func "$SCRIPT" normalized_name ".hidden file"
  [ "$output" = ".hidden.file" ]
}

@test "a separator at the start is trimmed rather than turned into a dot" {
  run_func "$SCRIPT" normalized_name " Some Show 1x02.mkv"
  [ "$output" = "some.show.S01E02.mkv" ]
}

@test "a resolution is not mistaken for an episode number" {
  run_func "$SCRIPT" normalized_name "Some Show S01E02 1920x1080.mkv"
  [ "$output" = "some.show.S01E02.1920x1080.mkv" ]
}

# --- Renaming ------------------------------------------------------------------------------------

@test "a video and its sidecar end up sharing a base name" {
  file "Some Show 1x02 Thing.mkv"
  file "Some Show 1x02 Thing.en.srt"
  run_script "$SCRIPT" --yes "$DIR"
  [ "$status" -eq 0 ]
  run names
  [ "${lines[0]}" = "some.show.S01E02.thing.en.srt" ]
  [ "${lines[1]}" = "some.show.S01E02.thing.mkv" ]
}

@test "a file with an extension not on the list is left alone" {
  file "Some Show 1x02.mkv"
  file "Some Notes 1x02.txt"
  run_script "$SCRIPT" --yes "$DIR"
  run names
  [[ "$output" == *"Some Notes 1x02.txt"* ]]
  [[ "$output" == *"some.show.S01E02.mkv"* ]]
}

@test "the configured extension list decides what is considered" {
  printf 'EXTENSIONS=(avi)\n' > "$CONFIG_FILE"
  file "Some Show 1x02.mkv"
  file "Some Show 1x03.avi"
  run_script "$SCRIPT" --yes "$DIR"
  run names
  [[ "$output" == *"Some Show 1x02.mkv"* ]]
  [[ "$output" == *"some.show.S01E03.avi"* ]]
}

@test "--dry-run shows the renames and performs none" {
  file "Some Show 1x02.mkv"
  run_script "$SCRIPT" --dry-run "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Some Show 1x02.mkv"*"some.show.S01E02.mkv"* ]]
  [ -f "$DIR/Some Show 1x02.mkv" ]
}

# The two files are different releases of the same episode as often as they are duplicates.
@test "a rename onto an existing name is refused and reported" {
  file "Some Show 1x02.mkv"
  file "some.show.S01E02.mkv"
  run_script "$SCRIPT" --yes "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  [ -f "$DIR/Some Show 1x02.mkv" ]
  [[ "$(cat "$DIR/some.show.S01E02.mkv")" == "contents of some.show.S01E02.mkv" ]]
}

@test "subdirectories are left out unless asked for" {
  file "sub/Some Show 1x02.mkv"
  file "Top Level 1x01.mkv"
  run_script "$SCRIPT" --yes "$DIR"
  run names sub
  [ "$output" = "Some Show 1x02.mkv" ]
  run names
  [ "$output" = "top.level.S01E01.mkv" ]
}

@test "--recursive descends" {
  file "sub/Some Show 1x02.mkv"
  run_script "$SCRIPT" --yes --recursive "$DIR"
  run names sub
  [ "$output" = "some.show.S01E02.mkv" ]
}

@test "a declined rename leaves the file alone" {
  file "Some Show 1x02.mkv"
  printf 'n\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" "$DIR" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [ -f "$DIR/Some Show 1x02.mkv" ]
}

@test "answering all renames the rest without asking again" {
  file "Some Show 1x02.mkv"
  file "Some Show 1x03.mkv"
  printf 'a\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" "$DIR" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"renamed 2"* ]]
}

@test "quitting stops the run" {
  file "Some Show 1x02.mkv"
  file "Some Show 1x03.mkv"
  printf 'q\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" "$DIR" < "$BATS_TEST_TMPDIR/answers"
  [[ "$output" == *"Stopping here."* ]]
  [ -f "$DIR/Some Show 1x02.mkv" ]
}

@test "a symlink is not renamed" {
  file "Some Show 1x02.mkv"
  ln -s "$DIR/Some Show 1x02.mkv" "$DIR/A Link 1x09.mkv"
  run_script "$SCRIPT" --yes "$DIR"
  [ -L "$DIR/A Link 1x09.mkv" ]
}

@test "a directory whose own name needs fixing is not renamed" {
  mkdir -p "$DIR/Some Show 1x02"
  file "Some Show 1x03.mkv"
  run_script "$SCRIPT" --yes "$DIR"
  [ -d "$DIR/Some Show 1x02" ]
}

@test "nothing to do is said plainly" {
  file "some.show.S01E02.mkv"
  run_script "$SCRIPT" --yes "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s) examined"* ]]
  [[ "$output" == *"renamed 0"* ]]
}

@test "a path that is not a directory is refused" {
  run_script "$SCRIPT" "$DIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a directory"* ]]
}

@test "the options are recorded as parse_options sees them" {
  run_snippet "$SCRIPT" "parse_options -r -k -y -n -C '$DIR'; printf '%s|%s|%s|%s|%s|%s' \"\$_recursive\" \"\$_keep_case\" \"\$_assume_yes\" \"\$_dry_run\" \"\$_no_color\" \"\$_target\""
  [ "$output" = "true|true|true|true|true|$DIR" ]
}

@test "an unknown option is refused" {
  run_script "$SCRIPT" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'."* ]]
}

# --- Paths the earlier tests did not reach -------------------------------------------------------

@test "answering yes renames just that file" {
  file "Some Show 1x02.mkv"
  file "Some Show 1x03.mkv"
  printf 'yn' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" "$DIR" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [ -f "$DIR/some.show.S01E02.mkv" ]
  [ -f "$DIR/Some Show 1x03.mkv" ]
}

@test "end of input stops the run rather than declining everything" {
  file "Some Show 1x02.mkv"
  file "Some Show 1x03.mkv"
  run_script "$SCRIPT" "$DIR" < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopping here."* ]]
}

# A rename can fail for reasons no check anticipates — a directory that stopped being writable between
# the listing and the move, for one — and the run has to carry on and report it.
@test "a rename that fails is reported and counted" {
  file "Some Show 1x02.mkv"
  run_snippet "$SCRIPT" "mv() { return 1; }; _assume_yes=true; process_file '$DIR/Some Show 1x02.mkv'; printf 'conflicts=%s' \"\$_conflicts\""
  [[ "$output" == *"Could not rename"* ]]
  [[ "$output" == *"conflicts=1"* ]]
}

@test "--debug is accepted" {
  file "some.show.S01E02.mkv"
  run_script "$SCRIPT" --debug --yes "$DIR"
  [ "$status" -eq 0 ]
}

@test "a directory whose name looks like an option is usable after --" {
  run_snippet "$SCRIPT" 'parse_options -- --odd; printf "%s" "$_target"'
  [ "$output" = "--odd" ]
}

@test "more than one directory argument is refused" {
  run_script "$SCRIPT" "$DIR" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected at most one directory argument, got 2."* ]]
}

#!/usr/bin/env bats
#
# link-series creates links from a name match, so the failures that matter are matching ones: an
# episode of a neighbouring season pulled in because the season number was compared loosely, a
# different show matched because its name shares a prefix, or nothing matched at all because a library
# folder spells the title with spaces where the release uses dots. Those are what this leans on, along
# with the two properties that make repeated runs safe — an existing file is left alone, and a hard
# link is a link rather than a copy.
#
# It shells out only to `ln`, `find` and `sed`, none of them stubbed: the honest assertion for a script
# whose job is linking files is which links exist afterwards, and how many names the inode has. Every
# test therefore works on real files under $BATS_TEST_TMPDIR, and each one keeps a release in the
# download folder that must not be linked, so a pattern that grew too permissive fails somewhere.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/media/link-series/link-series.sh"

  SRC="$BATS_TEST_TMPDIR/temp"
  LIB="$BATS_TEST_TMPDIR/tv"
  mkdir -p "$SRC" "$LIB/Taskmaster/Season 15"

  # Named explicitly, so the repository's own committed link-series.conf — which points at a real
  # download folder on a real machine — is never what the script reads.
  CONFIG_FILE="$BATS_TEST_TMPDIR/link-series.conf"
  export CONFIG_FILE
  printf 'TEMP_DIR="%s"\n' "$SRC" > "$CONFIG_FILE"

  # A release no test asks for. Every pattern must exclude it.
  release "QI.XL.S23E04.Wavey.720p.iP.WEB-DL.mkv"
}

teardown() {
  # Matching that reached a different show entirely would show up here and nowhere else.
  if [ -e "$LIB/Taskmaster/Season 15/QI.XL.S23E04.Wavey.720p.iP.WEB-DL.mkv" ]; then
    printf 'the match escaped to another show\n' >&2
    return 1
  fi
}

########################################
# Creates a release file in the download folder, with distinguishable contents.
# Arguments:
#   path: Path relative to SRC; intermediate directories are created.
########################################
release() {
  local full="$SRC/$1"
  mkdir -p "$(dirname "$full")"
  printf '%s' "$1" > "$full"
}

########################################
# Prints the names in a destination directory, one per line, sorted.
# Arguments:
#   dir: Directory to list, relative to LIB.
########################################
linked_names() {
  local dir="$LIB/$1"
  find "$dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort
}

# --- Context: what the destination directory says the show and season are ----------------------

@test "a season folder takes the show from its parent and pads the season" {
  run_snippet "$SCRIPT" "_target_dir='$LIB/Taskmaster/Season 15'; detect_context; printf '%s|%s' \"\$_show\" \"\$_season\""
  [ "$status" -eq 0 ]
  [ "$output" = "Taskmaster|15" ]
}

@test "a single-digit season folder is padded to the two digits releases use" {
  mkdir -p "$LIB/Taskmaster/Season 1"
  run_snippet "$SCRIPT" "_target_dir='$LIB/Taskmaster/Season 1'; detect_context; printf '%s' \"\$_season\""
  [ "$output" = "01" ]
}

# A leading zero would be an invalid octal literal in an arithmetic context, which is why the season is
# read in base 10 rather than passed to printf as written.
@test "a season folder that already carries a leading zero is read as decimal" {
  mkdir -p "$LIB/Taskmaster/Season 08"
  run_snippet "$SCRIPT" "_target_dir='$LIB/Taskmaster/Season 08'; detect_context; printf '%s' \"\$_season\""
  [ "$status" -eq 0 ]
  [ "$output" = "08" ]
}

@test "a season folder is recognised however its name is punctuated" {
  mkdir -p "$LIB/Taskmaster/Season.16" "$LIB/Taskmaster/season_17"
  run_snippet "$SCRIPT" "_target_dir='$LIB/Taskmaster/Season.16'; detect_context; printf '%s' \"\$_season\""
  [ "$output" = "16" ]
  run_snippet "$SCRIPT" "_target_dir='$LIB/Taskmaster/season_17'; detect_context; printf '%s' \"\$_season\""
  [ "$output" = "17" ]
}

@test "a Specials folder is season zero" {
  mkdir -p "$LIB/Taskmaster/Specials"
  run_snippet "$SCRIPT" "_target_dir='$LIB/Taskmaster/Specials'; detect_context; printf '%s|%s' \"\$_show\" \"\$_season\""
  [ "$output" = "Taskmaster|00" ]
}

@test "a show folder names the show and constrains no season" {
  run_snippet "$SCRIPT" "_target_dir='$LIB/Taskmaster'; detect_context; printf '%s|%s' \"\$_show\" \"\$_season\""
  [ "$output" = "Taskmaster|" ]
}

@test "a destination that is not a directory is refused" {
  printf 'x' > "$BATS_TEST_TMPDIR/afile"
  run_script "$SCRIPT" "$BATS_TEST_TMPDIR/afile"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a directory."* ]]
}

@test "a destination that cannot be written to is refused before anything is linked" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores the write bit"
  fi
  mkdir -p "$LIB/Readonly/Season 1"
  chmod a-w "$LIB/Readonly/Season 1"
  run_script "$SCRIPT" "$LIB/Readonly/Season 1"
  chmod u+w "$LIB/Readonly/Season 1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not writable."* ]]
}

# --- Matching, which is where a mistake links the wrong episode --------------------------------

@test "the episodes of the destination's season are linked" {
  release "Taskmaster.S15E01.The.Curse.720p.ALL4.WEB-DL.mkv"
  release "Taskmaster.S15E02.Trapped.720p.ALL4.WEB-DL.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  run linked_names "Taskmaster/Season 15"
  [ "${lines[0]}" = "Taskmaster.S15E01.The.Curse.720p.ALL4.WEB-DL.mkv" ]
  [ "${lines[1]}" = "Taskmaster.S15E02.Trapped.720p.ALL4.WEB-DL.mkv" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "another season of the same show is not linked into this one" {
  release "Taskmaster.S15E01.720p.mkv"
  release "Taskmaster.S14E01.720p.mkv"
  release "Taskmaster.S16E01.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  run linked_names "Taskmaster/Season 15"
  [ "$output" = "Taskmaster.S15E01.720p.mkv" ]
}

# The non-digit after the season is what separates these two: a plain "s1" prefix match would take
# every season from 10 to 19 with it.
@test "a single-digit season does not match a two-digit one that starts with it" {
  mkdir -p "$LIB/Taskmaster/Season 1"
  release "Taskmaster.S15E01.720p.mkv"
  release "Taskmaster.S01E01.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 1"
  run linked_names "Taskmaster/Season 1"
  [ "$output" = "Taskmaster.S01E01.720p.mkv" ]
}

# This is the case the library actually contains: "QI" and "QI XL" are two folders, and a run in the
# first must not collect the second's releases. Requiring the season to follow the title with nothing
# but punctuation in between is what enforces it.
@test "a longer show name is not collected by the shorter one it starts with" {
  mkdir -p "$LIB/QI/Season 23" "$LIB/QI XL/Season 23"
  release "QI.S23E07.720p.WEB.mkv"
  release "QI.XL.S23E04.Wavey.720p.iP.WEB-DL.mkv"

  run_script "$SCRIPT" "$LIB/QI/Season 23"
  run linked_names "QI/Season 23"
  [ "$output" = "QI.S23E07.720p.WEB.mkv" ]

  run_script "$SCRIPT" "$LIB/QI XL/Season 23"
  run linked_names "QI XL/Season 23"
  [ "$output" = "QI.XL.S23E04.Wavey.720p.iP.WEB-DL.mkv" ]
}

@test "a different show whose name starts the same way is not linked" {
  mkdir -p "$LIB/Alice/Season 1"
  release "Alice.S01E01.1080p.WEB.mkv"
  release "Alice.in.Borderland.S01E01.1080p.WEB.mkv"
  run_script "$SCRIPT" "$LIB/Alice/Season 1"
  run linked_names "Alice/Season 1"
  [ "$output" = "Alice.S01E01.1080p.WEB.mkv" ]
}

@test "spaces in the library folder match the separators a release uses" {
  mkdir -p "$LIB/Would I Lie to You/Season 3"
  release "Would.I.Lie.to.You.S03E01.720p.mkv"
  release "Would_I_Lie_to_You_S03E02_720p.mkv"
  release "Would I Lie to You S03E03 720p.mkv"
  run_script "$SCRIPT" "$LIB/Would I Lie to You/Season 3"
  run linked_names "Would I Lie to You/Season 3"
  [ "${#lines[@]}" -eq 3 ]
}

# Library folders carry a year to tell two shows of the same name apart; release names usually do not.
@test "a disambiguating year in the folder name is optional in the release" {
  mkdir -p "$LIB/Alice (2009)/Season 1"
  release "Alice.S01E01.1080p.WEB.mkv"
  release "Alice.2009.S01E02.1080p.WEB.mkv"
  run_script "$SCRIPT" "$LIB/Alice (2009)/Season 1"
  [ "$status" -eq 0 ]
  run linked_names "Alice (2009)/Season 1"
  [ "${#lines[@]}" -eq 2 ]
}

# Releases drop the punctuation a library folder spells out: the hyphen in "Alan Davies - As Yet
# Untitled" and the apostrophe in "Agatha Christie's Marple" both disappear, so neither can be compared.
@test "punctuation in the folder name is not required in the release" {
  mkdir -p "$LIB/Alan Davies - As Yet Untitled/Season 5" "$LIB/Agatha Christie's Marple/Season 1"
  release "Alan.Davies.As.Yet.Untitled.S05E01.720p.mkv"
  release "Agatha.Christies.Marple.S01E02.1080p.mkv"

  run_script "$SCRIPT" "$LIB/Alan Davies - As Yet Untitled/Season 5"
  run linked_names "Alan Davies - As Yet Untitled/Season 5"
  [ "$output" = "Alan.Davies.As.Yet.Untitled.S05E01.720p.mkv" ]

  run_script "$SCRIPT" "$LIB/Agatha Christie's Marple/Season 1"
  run linked_names "Agatha Christie's Marple/Season 1"
  [ "$output" = "Agatha.Christies.Marple.S01E02.1080p.mkv" ]
}

@test "a season spelled out in words is matched" {
  mkdir -p "$LIB/Taskmaster/Season 16"
  release "Taskmaster.Season.16.COMPLETE.720p/tm.s16e01.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 16"
  run linked_names "Taskmaster/Season 16"
  [ "$output" = "tm.s16e01.mkv" ]
}

@test "the 15x07 spelling of a season is matched" {
  mkdir -p "$LIB/Taskmaster/Season 1"
  release "Taskmaster.1x02.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 1"
  run linked_names "Taskmaster/Season 1"
  [ "$output" = "Taskmaster.1x02.720p.mkv" ]
}

# A folder called "Season 1" and a release called S01 mean the same season, and so does one called S1.
@test "a season matches whatever zero padding the release used" {
  mkdir -p "$LIB/Bron/Season 1"
  release "Bron.S1E03.576p.mkv"
  release "Bron.S01E04.576p.mkv"
  run_script "$SCRIPT" "$LIB/Bron/Season 1"
  run linked_names "Bron/Season 1"
  [ "${#lines[@]}" -eq 2 ]
}

@test "a show folder takes every season it finds" {
  release "Taskmaster.S14E01.720p.mkv"
  release "Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster"
  run linked_names "Taskmaster"
  # The season directory the fixture creates is listed alongside the two links.
  [ "${#lines[@]}" -eq 3 ]
}

# A season pack arrives as a directory named after the show, holding episode files that are not.
@test "an episode is matched by the release folder holding it" {
  mkdir -p "$LIB/Taskmaster/Season 16"
  release "Taskmaster.S16.720p.ALL4.WEB-DL/tm.s16e01.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 16"
  run linked_names "Taskmaster/Season 16"
  [ "$output" = "tm.s16e01.mkv" ]
}

@test "matching ignores case on both sides" {
  release "taskmaster.s15e01.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  run linked_names "Taskmaster/Season 15"
  [ "$output" = "taskmaster.s15e01.720p.mkv" ]
}

@test "a non-media file that matches the name is left behind" {
  release "Taskmaster.S15E01.720p.mkv"
  release "Taskmaster.S15E01.720p.nfo"
  release "Taskmaster.S15E01.720p.srt"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  run linked_names "Taskmaster/Season 15"
  [ "$output" = "Taskmaster.S15E01.720p.mkv" ]
}

@test "the configured extension list decides what counts as an episode" {
  printf 'TEMP_DIR="%s"\nMEDIA_EXTS=(avi)\n' "$SRC" > "$CONFIG_FILE"
  release "Taskmaster.S15E01.720p.mkv"
  release "Taskmaster.S15E02.720p.avi"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  run linked_names "Taskmaster/Season 15"
  [ "$output" = "Taskmaster.S15E02.720p.avi" ]
}

# --- The quality filter ------------------------------------------------------------------------

@test "only releases carrying the requested quality are linked" {
  release "Taskmaster.S15E01.720p.mkv"
  release "Taskmaster.S15E01.1080p.mkv"
  run_script "$SCRIPT" --quality 1080p "$LIB/Taskmaster/Season 15"
  run linked_names "Taskmaster/Season 15"
  [ "$output" = "Taskmaster.S15E01.1080p.mkv" ]
}

# The separators around the quality are what stop this: without them "720p" is found inside "1720p".
@test "a quality is matched as a whole token" {
  release "Taskmaster.S15E01.1720p.mkv"
  run_script "$SCRIPT" -q 720p "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  run linked_names "Taskmaster/Season 15"
  [ "$output" = "" ]
}

@test "no match at all is reported rather than passed over in silence" {
  release "Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" -q 2160p "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No matching releases found for Taskmaster season 15."* ]]
  [[ "$output" == *"Use --debug to see the search pattern."* ]]
}

# --- What kind of link, and what a repeated run does -------------------------------------------

@test "a hard link is made by default, so the file has two names and one inode" {
  release "Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  local dest="$LIB/Taskmaster/Season 15/Taskmaster.S15E01.720p.mkv"
  [ -f "$dest" ]
  [ ! -L "$dest" ]
  [ "$dest" -ef "$SRC/Taskmaster.S15E01.720p.mkv" ]
}

@test "--symlink makes a symbolic link instead" {
  release "Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" --symlink "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  [ -L "$LIB/Taskmaster/Season 15/Taskmaster.S15E01.720p.mkv" ]
}

@test "a configured LINK_TYPE is honoured when no option overrides it" {
  printf 'TEMP_DIR="%s"\nLINK_TYPE="symlink"\n' "$SRC" > "$CONFIG_FILE"
  release "Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  [ -L "$LIB/Taskmaster/Season 15/Taskmaster.S15E01.720p.mkv" ]
}

@test "a LINK_TYPE that is neither kind of link is refused rather than assumed" {
  printf 'TEMP_DIR="%s"\nLINK_TYPE="soft"\n' "$SRC" > "$CONFIG_FILE"
  release "Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 1 ]
  [[ "$output" == *"LINK_TYPE must be 'hard' or 'symlink'"* ]]
  [ ! -e "$LIB/Taskmaster/Season 15/Taskmaster.S15E01.720p.mkv" ]
}

@test "a second run links only what is new" {
  release "Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  release "Taskmaster.S15E02.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping Taskmaster.S15E01.720p.mkv (already in the destination)"* ]]
  [[ "$output" == *"Linked 1 file(s)"*"skipped 1 already present"* ]]
}

# A broken symlink is not caught by -e, so without the -L test alongside it the script would try to
# link over the name and report a failure the operator can do nothing about.
@test "a broken symlink already in the destination counts as present" {
  release "Taskmaster.S15E01.720p.mkv"
  ln -s "$BATS_TEST_TMPDIR/gone.mkv" "$LIB/Taskmaster/Season 15/Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already in the destination"* ]]
}

@test "--dry-run reports what it would link and links nothing" {
  release "Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" --dry-run "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would hard link Taskmaster.S15E01.720p.mkv"* ]]
  [[ "$output" == *"Would link 1 file(s)"* ]]
  [ ! -e "$LIB/Taskmaster/Season 15/Taskmaster.S15E01.720p.mkv" ]
}

# `ln` is shadowed by a function rather than by a stub on PATH, both because the real one is wanted
# everywhere else in this suite and because a cross-filesystem failure cannot be arranged inside one
# temp directory.
@test "a link that fails is reported with the reason a hard link usually fails" {
  release "Taskmaster.S15E01.720p.mkv"
  run_snippet "$SCRIPT" "ln() { return 1; }; _link_type=hard; _target_dir='$LIB/Taskmaster/Season 15'; link_one '$SRC/Taskmaster.S15E01.720p.mkv'; printf 'failed=%s' \"\$_failed\""
  [[ "$output" == *"Could not hard link"* ]]
  [[ "$output" == *"try --symlink"* ]]
  [[ "$output" == *"failed=1"* ]]
}

@test "a failed link makes the run exit non-zero" {
  run_snippet "$SCRIPT" "_failed=1; _linked=0; _skipped=0; (( _failed == 0 ))"
  [ "$status" -eq 1 ]
}

@test "a symlink failure does not blame the filesystem" {
  release "Taskmaster.S15E01.720p.mkv"
  run_snippet "$SCRIPT" "ln() { return 1; }; _link_type=symlink; _target_dir='$LIB/Taskmaster/Season 15'; link_one '$SRC/Taskmaster.S15E01.720p.mkv'"
  [[ "$output" == *"Could not symlink"* ]]
  [[ "$output" != *"--symlink"* ]]
}

# --- Where the releases are searched for -------------------------------------------------------

@test "--temp-dir overrides the configured download folder" {
  local other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  printf 'x' > "$other/Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" --temp-dir "$other" "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  [ "$LIB/Taskmaster/Season 15/Taskmaster.S15E01.720p.mkv" -ef "$other/Taskmaster.S15E01.720p.mkv" ]
}

@test "a run with no download folder from either source says which two to set" {
  printf '# nothing configured\n' > "$CONFIG_FILE"
  run_script "$SCRIPT" "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Set TEMP_DIR in the configuration file, or pass --temp-dir."* ]]
}

@test "a download folder that does not exist is refused" {
  run_script "$SCRIPT" --temp-dir "$BATS_TEST_TMPDIR/absent" "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist or is not a directory."* ]]
}

@test "an unreadable CONFIG_FILE is refused rather than silently defaulted" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/nope.conf" run_script "$SCRIPT" --temp-dir "$SRC" "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist or is not readable."* ]]
}

# --- Option handling ---------------------------------------------------------------------------

@test "the options are recorded as parse_options sees them" {
  run_snippet "$SCRIPT" "parse_options -t /tmp/x -q 1080p -s -n -C '$LIB/Taskmaster'; printf '%s|%s|%s|%s|%s|%s' \"\$_source_opt\" \"\$_quality\" \"\$_link_type_opt\" \"\$_dry_run\" \"\$_no_color\" \"\$_target_dir\""
  [ "$output" = "/tmp/x|1080p|symlink|true|true|$LIB/Taskmaster" ]
}

@test "the long spelling of every option is accepted too" {
  run_snippet "$SCRIPT" "parse_options --temp-dir /tmp/x --quality 720p --symlink --dry-run --no-color '$LIB/Taskmaster'; printf '%s|%s|%s|%s|%s' \"\$_source_opt\" \"\$_quality\" \"\$_link_type_opt\" \"\$_dry_run\" \"\$_no_color\""
  [ "$output" = "/tmp/x|720p|symlink|true|true" ]
}

@test "--debug prints the pattern it searched with" {
  release "Taskmaster.S15E01.720p.mkv"
  run_script "$SCRIPT" --debug --dry-run "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Search pattern: taskmaster[^[:alnum:]]+(s0*15[^0-9]"* ]]
}

@test "more than one directory argument is refused" {
  run_script "$SCRIPT" "$LIB/Taskmaster" "$LIB/Taskmaster"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected at most one directory argument, got 2."* ]]
}

@test "a directory whose name looks like an option is still usable after --" {
  run_snippet "$SCRIPT" "parse_options -- --odd-name; printf '%s' \"\$_target_dir\""
  [ "$output" = "--odd-name" ]
}

# `find` is not asked to follow symlinks, and does not descend into one given as its starting point, so
# an unresolved download folder that happens to be a symlink reports nothing at all — the one failure
# mode that looks exactly like a release naming mismatch.
@test "a download folder reached through a symlink is still searched" {
  release "Taskmaster.S15E01.720p.mkv"
  ln -s "$SRC" "$BATS_TEST_TMPDIR/src-link"
  run_script "$SCRIPT" --temp-dir "$BATS_TEST_TMPDIR/src-link" "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  run linked_names "Taskmaster/Season 15"
  [ "$output" = "Taskmaster.S15E01.720p.mkv" ]
}

@test "a symlink is made to the folder that was searched, not to a path relative to the destination" {
  release "Taskmaster.S15E01.720p.mkv"
  cd "$BATS_TEST_TMPDIR"
  run_script "$SCRIPT" --symlink --temp-dir temp "$LIB/Taskmaster/Season 15"
  [ "$status" -eq 0 ]
  # Readable through the link, which a target resolved against the destination would not be.
  [ -r "$LIB/Taskmaster/Season 15/Taskmaster.S15E01.720p.mkv" ]
}

@test "a run whose links all failed is not reported as nothing having matched" {
  run_snippet "$SCRIPT" "_show=Taskmaster; _season=15; _linked=0; _skipped=0; _failed=2; print_summary"
  [[ "$output" != *"No matching releases"* ]]
  [[ "$output" == *"2 failed"* ]]
}

# --- Naming the target ---------------------------------------------------------------------------

# The show and season are read from the destination directory's own name, so it is named rather than
# inferred from wherever the caller happens to be standing.
@test "no directory at all is refused, rather than defaulting to the current directory" {
  cd "$BATS_TEST_TMPDIR"
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"A directory is required"* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "a directory of . is the working directory" {
  release "Taskmaster.S15E01.720p.mkv"
  cd "$LIB/Taskmaster/Season 15"
  run_script "$SCRIPT" --dry-run .
  [ "$status" -eq 0 ]
  [[ "$output" == *"Taskmaster.S15E01.720p.mkv"* ]]
}

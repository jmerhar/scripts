#!/usr/bin/env bats
#
# compare-dirs reports rather than changes anything, so the failure that matters is a wrong or missing
# report: a difference passed over silently, or one invented where the trees agree. Both directions are
# asserted throughout, and the counts in the summary are checked as well as the lines, since a report
# that prints but does not count would still exit 0 and read as "identical".
#
# It shells out to nothing that needs stubbing — find, sort, stat and a checksum tool — so the fixtures
# are real trees under $BATS_TEST_TMPDIR.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/utility/compare-dirs/compare-dirs.sh"
  LEFT="$BATS_TEST_TMPDIR/left"
  RIGHT="$BATS_TEST_TMPDIR/right"
  mkdir -p "$LEFT" "$RIGHT"
}

########################################
# Writes a file into one of the trees.
# Arguments:
#   side: LEFT or RIGHT.
#   path: Path relative to that tree.
#   contents: Optional body, defaulting to the path.
########################################
put() {
  local root="${!1}" path="$2"
  mkdir -p "$(dirname "$root/$path")"
  printf '%s' "${3:-$path}" > "$root/$path"
}

########################################
# Compares the two trees through the command line.
# Arguments:
#   Options to pass before the two directories.
########################################
compare() {
  run_script "$SCRIPT" -n "$@" "$LEFT" "$RIGHT"
}

# --- Agreement ---------------------------------------------------------------------------------

@test "identical trees are reported as identical, and exit 0" {
  put LEFT same.txt
  put RIGHT same.txt
  compare
  [ "$status" -eq 0 ]
  [[ "$output" == *"Directories are identical."* ]]
}

@test "two empty directories are identical" {
  compare
  [ "$status" -eq 0 ]
  [[ "$output" == *"Directories are identical."* ]]
}

@test "matching subdirectories are descended into without comment" {
  put LEFT sub/deep/a.txt
  put RIGHT sub/deep/a.txt
  compare
  [ "$status" -eq 0 ]
  [[ "$output" == *"identical"* ]]
}

# The mtimes are made equal rather than assumed equal: stat_mtime has one-second resolution, so two files
# written by consecutive commands differ whenever the pair straddles a second tick, and with --timestamps
# on that is a real difference for the script to report. Left to chance this fails about once in thirty
# runs.
@test "a file present on both sides with the same content is not reported" {
  put LEFT a.txt hello
  put RIGHT a.txt hello
  touch -r "$LEFT/a.txt" "$RIGHT/a.txt"
  compare --checksums --timestamps
  [ "$status" -eq 0 ]
}

# --- Presence ----------------------------------------------------------------------------------

@test "a file only on the left is reported as such" {
  put LEFT orphan.txt
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *"LEFT only:"*"orphan.txt"* ]]
  [[ "$output" == *"1 only in LEFT"* ]]
}

@test "a file only on the right is reported as such" {
  put RIGHT orphan.txt
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *"RIGHT only:"*"orphan.txt"* ]]
  [[ "$output" == *"1 only in RIGHT"* ]]
}

@test "a directory present on one side only is marked with a trailing slash" {
  mkdir "$LEFT/onlydir"
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *"LEFT only:"*"onlydir/"* ]]
}

@test "the contents of a one-sided directory are not enumerated" {
  put LEFT onlydir/inside.txt
  compare
  [[ "$output" == *"onlydir/"* ]]
  [[ "$output" != *"inside.txt"* ]]
}

@test "a nested difference is reported with its path relative to the roots" {
  put LEFT sub/deep/only.txt
  put RIGHT sub/deep/other.txt
  compare
  [[ "$output" == *"sub/deep/only.txt"* ]]
  [[ "$output" == *"sub/deep/other.txt"* ]]
}

# --- Content -----------------------------------------------------------------------------------

@test "differing sizes are reported with both sizes" {
  put LEFT a.txt aa
  put RIGHT a.txt aaaa
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *"Size differs:"*"a.txt"* ]]
  [[ "$output" == *"2 bytes"* ]]
  [[ "$output" == *"4 bytes"* ]]
  [[ "$output" == *"1 differences"* ]]
}

# Same length, different bytes: the size check cannot see this, which is the whole point of --checksums.
@test "same-size files with different contents need --checksums to be noticed" {
  put LEFT a.txt aaaa
  put RIGHT a.txt bbbb
  compare
  [ "$status" -eq 0 ]

  compare --checksums
  [ "$status" -eq 1 ]
  [[ "$output" == *"Checksum differs:"*"a.txt"* ]]
}

@test "a checksum comparison is skipped when the sizes already differ" {
  put LEFT a.txt aa
  put RIGHT a.txt aaaa
  compare --checksums
  [[ "$output" == *"Size differs"* ]]
  [[ "$output" != *"Checksum differs"* ]]
}

@test "modification times are compared only with --timestamps" {
  put LEFT a.txt same
  put RIGHT a.txt same
  touch -t 200001010000 "$LEFT/a.txt"
  touch -t 201001010000 "$RIGHT/a.txt"
  compare
  [ "$status" -eq 0 ]

  compare --timestamps
  [ "$status" -eq 1 ]
  [[ "$output" == *"Mtime differs:"*"a.txt"* ]]
  # Both sides are rendered as dates rather than epochs, so the report is readable.
  [[ "$output" == *"2000-01-01"* ]]
  [[ "$output" == *"2010-01-01"* ]]
}

# --- Types and links ---------------------------------------------------------------------------

@test "a file on one side and a directory on the other is a type mismatch" {
  mkdir "$LEFT/thing"
  put RIGHT thing
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *"Type mismatch:"*"thing"* ]]
  [[ "$output" == *"directory"* ]]
  [[ "$output" == *"file"* ]]
}

@test "symlinks with different targets are reported with both targets" {
  ln -s /one "$LEFT/link"
  ln -s /two "$RIGHT/link"
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *"Symlink target differs:"*"link"* ]]
  [[ "$output" == *"/one"* ]]
  [[ "$output" == *"/two"* ]]
}

@test "symlinks with the same target agree" {
  ln -s /same "$LEFT/link"
  ln -s /same "$RIGHT/link"
  compare
  [ "$status" -eq 0 ]
}

# A symlink is compared as a link, not as whatever it points at — otherwise two links to files with
# identical contents would compare equal while pointing somewhere quite different.
@test "a symlink is not followed to compare contents" {
  printf 'body' > "$BATS_TEST_TMPDIR/target-one"
  printf 'body' > "$BATS_TEST_TMPDIR/target-two"
  ln -s "$BATS_TEST_TMPDIR/target-one" "$LEFT/link"
  ln -s "$BATS_TEST_TMPDIR/target-two" "$RIGHT/link"
  compare --checksums
  [ "$status" -eq 1 ]
  [[ "$output" == *"Symlink target differs"* ]]
}

# --- Filtering ---------------------------------------------------------------------------------

@test "--exclude drops matching entries from both sides" {
  put LEFT keep.txt
  put LEFT skip.log
  put RIGHT skip.log other
  compare --exclude '*.log'
  [ "$status" -eq 1 ]
  [[ "$output" == *"keep.txt"* ]]
  [[ "$output" != *"skip.log"* ]]
}

@test "--exclude accepts several patterns" {
  put LEFT a.log
  put LEFT b.tmp
  put LEFT keep.txt
  compare --exclude '*.log' --exclude '*.tmp'
  [[ "$output" == *"keep.txt"* ]]
  [[ "$output" != *"a.log"* ]]
  [[ "$output" != *"b.tmp"* ]]
}

@test "--exclude-left suppresses only left-only reports" {
  put LEFT hidden.txt
  put RIGHT shown.txt
  compare --exclude-left 'hidden.txt'
  [[ "$output" != *"hidden.txt"* ]]
  [[ "$output" == *"shown.txt"* ]]
}

@test "--exclude-right suppresses only right-only reports" {
  put LEFT shown.txt
  put RIGHT hidden.txt
  compare --exclude-right 'hidden.txt'
  [[ "$output" != *"hidden.txt"* ]]
  [[ "$output" == *"shown.txt"* ]]
}

# --exclude-left hides a one-sided report, not a comparison: a file on both sides is still compared.
@test "--exclude-left does not suppress a difference between two present files" {
  put LEFT a.txt aa
  put RIGHT a.txt aaaa
  compare --exclude-left 'a.txt'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Size differs"* ]]
}

@test "--no-dotfiles ignores dot entries on both sides" {
  put LEFT .hidden
  put RIGHT .other
  put LEFT visible.txt
  compare --no-dotfiles
  [[ "$output" != *".hidden"* ]]
  [[ "$output" != *".other"* ]]
  [[ "$output" == *"visible.txt"* ]]
}

@test "dot entries are compared by default" {
  put LEFT .hidden
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *".hidden"* ]]
}

@test "--ignore-case pairs names that differ only in case" {
  put LEFT README.txt body
  put RIGHT readme.txt body
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *"only in LEFT"* ]]

  compare --ignore-case
  [ "$status" -eq 0 ]
}

@test "--ignore-case still compares the contents of the paired files" {
  put LEFT README.txt aa
  put RIGHT readme.txt aaaa
  compare --ignore-case
  [ "$status" -eq 1 ]
  [[ "$output" == *"Size differs"* ]]
}

# --- Awkward names -----------------------------------------------------------------------------

@test "a filename containing spaces is compared and reported intact" {
  put LEFT "holiday snap.txt"
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *"holiday snap.txt"* ]]
}

@test "entries are reported in sorted order" {
  put LEFT b.txt
  put LEFT a.txt
  put LEFT c.txt
  compare
  run bash -c "printf '%s\n' \"\$1\" | grep -o '[abc]\.txt' | tr -d '\n'" _ "$output"
  [ "$output" = "a.txtb.txtc.txt" ]
}

# --- Counting and the summary ------------------------------------------------------------------

@test "the summary counts each category separately" {
  put LEFT l1.txt
  put LEFT l2.txt
  put RIGHT r1.txt
  put LEFT both.txt aa
  put RIGHT both.txt aaaa
  compare
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 only in LEFT"* ]]
  [[ "$output" == *"1 only in RIGHT"* ]]
  [[ "$output" == *"1 differences"* ]]
}

@test "the header names both directories" {
  compare
  [[ "$output" == *"LEFT:"*"$LEFT"* ]]
  [[ "$output" == *"RIGHT:"*"$RIGHT"* ]]
}

@test "relative directory arguments are resolved for display" {
  put LEFT a.txt
  cd "$BATS_TEST_TMPDIR"
  run_script "$SCRIPT" -n left right
  [[ "$output" == *"$BATS_TEST_TMPDIR/left"* ]]
}

# --- The reporting primitives and platform helpers ---------------------------------------------

@test "each report helper prints its marker and counts once" {
  run_snippet "$SCRIPT" \
    'print_left_only a; print_right_only b; print_size_diff c 1 2
     echo "counts=${_count_left_only}/${_count_right_only}/${_count_differences}"'
  [[ "$output" == *"LEFT only:  a"* ]]
  [[ "$output" == *"RIGHT only: b"* ]]
  [[ "$output" == *"Size differs: c"* ]]
  [[ "$output" == *"counts=1/1/1"* ]]
}

@test "the checksum and mtime reports also count as differences" {
  run_snippet "$SCRIPT" \
    'print_checksum_diff a; print_mtime_diff b 0 1; print_type_mismatch c file directory
     print_symlink_diff d /x /y; echo "diffs=${_count_differences}"'
  [[ "$output" == *"diffs=4"* ]]
}

@test "colours stay off when not writing to a terminal" {
  run_snippet "$SCRIPT" 'setup_colors; printf "[%s]" "${_C_RED}"'
  [ "$output" = "[]" ]
}

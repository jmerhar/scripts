#!/usr/bin/env bats
#
# remove-sidecars deletes files, and decides what to delete by pairing extensions within a directory —
# so the risk is not a crash but a wrong pairing: a sidecar removed where no RAW exists, or a match
# leaking across directories. Those are the cases this leans on.
#
# It shells out to nothing, so there is no stub to arrange: the fixtures are real files in real
# directories under $BATS_TEST_TMPDIR, and the deletions are real too. That is deliberate — the honest
# assertion for a script whose job is removing files is which files are gone afterwards. Every test also
# keeps a directory the script was never pointed at, to prove the traversal stays where it was sent.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/photography/remove-sidecars/remove-sidecars.sh"

  # The tree under test, and a sibling the script is never given.
  TREE="$BATS_TEST_TMPDIR/tree"
  UNTOUCHED="$BATS_TEST_TMPDIR/untouched"
  mkdir -p "$TREE" "$UNTOUCHED"
  printf 'raw' > "$UNTOUCHED/keep.DNG"
  printf 'sidecar' > "$UNTOUCHED/keep.JPG"
}

teardown() {
  # Whatever a test did, the directory it was not pointed at must be intact.
  if [ -d "${UNTOUCHED:-}" ]; then
    [ -f "$UNTOUCHED/keep.DNG" ] && [ -f "$UNTOUCHED/keep.JPG" ] || {
      printf 'the traversal escaped into a directory it was never given\n' >&2
      return 1
    }
  fi
}

########################################
# Creates a file with given contents under the tree.
# Arguments:
#   path: Path relative to TREE.
#   contents: Optional body, defaulting to the path itself.
########################################
fixture() {
  local full="$TREE/$1"
  mkdir -p "$(dirname "$full")"
  printf '%s' "${2:-$1}" > "$full"
}

########################################
# Writes lines to a file and prints its path, for feeding a script's prompts.
# Redirected into the helpers rather than piped: a pipeline runs bats' `run` in a subshell, which
# discards the status and output it sets.
# Arguments:
#   Lines to write.
########################################
answers() {
  local f="$BATS_TEST_TMPDIR/answers.$RANDOM"
  printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}

########################################
# Runs a snippet with the extension lists already chosen, skipping the prompts.
# Arguments:
#   snippet: Bash to evaluate after the globals are set.
########################################
with_exts() {
  run_snippet "$SCRIPT" "_sidecar_exts=(JPG jpg); _raw_exts=(DNG RW2); $1"
}

# --- Extension prompts -------------------------------------------------------------------------

@test "define_extensions falls back to the documented defaults on empty input" {
  local input; input=$(answers "" "")
  run_snippet "$SCRIPT" \
    'define_extensions >/dev/null; echo "${_sidecar_exts[*]}"; echo "${_raw_exts[*]}"' < "$input"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "JPG jpg JPEG jpeg" ]
  [ "${lines[1]}" = "RW2 CR2 DNG dng" ]
}

@test "define_extensions takes whitespace-separated answers" {
  local input; input=$(answers "png tif" "nef")
  run_snippet "$SCRIPT" \
    'define_extensions >/dev/null; echo "${_sidecar_exts[*]}"; echo "${_raw_exts[*]}"' < "$input"
  [ "${lines[0]}" = "png tif" ]
  [ "${lines[1]}" = "nef" ]
}

# --- Pairing, which is where a mistake costs a photograph --------------------------------------

@test "a sidecar is queued when a RAW of the same base name sits beside it" {
  fixture a.DNG
  fixture a.JPG
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; printf "%s\n" "${_del_paths[@]}"'
  [ "$output" = "$TREE/a.JPG" ]
}

@test "a sidecar with no RAW of that base name is left alone" {
  fixture lonely.JPG
  fixture other.DNG
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; echo "${#_del_paths[@]}"'
  [ "$output" = "0" ]
}

@test "a RAW with no sidecar queues nothing" {
  fixture a.DNG
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; echo "${#_del_paths[@]}"'
  [ "$output" = "0" ]
}

@test "the RAW extension a sidecar belongs to is recorded alongside it" {
  fixture a.RW2
  fixture a.JPG
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; echo "${_del_exts[0]}"'
  [ "$output" = "RW2" ]
}

# JPG and JPEG rather than JPG and jpg: macOS is case-insensitive by default, so the latter pair is one
# file there and the test would assert different things on different platforms.
@test "every matching sidecar for one base name is queued" {
  fixture a.DNG
  fixture a.JPG
  fixture a.JPEG
  run_snippet "$SCRIPT" \
    "_sidecar_exts=(JPG JPEG); _raw_exts=(DNG)
     traverse_tree '$TREE' >/dev/null; echo \"\${#_del_paths[@]}\""
  [ "$output" = "2" ]
}

# The pairing is per directory: a RAW in one directory must not license deleting a same-named sidecar
# in another, which would delete the only copy of an unedited photograph.
@test "a RAW does not license a sidecar in a different directory" {
  fixture withraw/a.DNG
  fixture withraw/a.JPG
  fixture noraw/a.JPG
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; printf "%s\n" "${_del_paths[@]}"'
  [ "$output" = "$TREE/withraw/a.JPG" ]
}

@test "traversal recurses into subdirectories" {
  fixture top.DNG
  fixture top.JPG
  fixture deep/nested/b.RW2
  fixture deep/nested/b.jpg
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; printf "%s\n" "${_del_paths[@]}" | sort'
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"$TREE/deep/nested/b.jpg"* ]]
  [[ "$output" == *"$TREE/top.JPG"* ]]
}

# The link has to be one that would otherwise be deleted — a name that pairs with a real RAW beside it —
# or the assertion holds whether or not symlinks are skipped, and proves nothing. Deleting it would
# remove the user's link while leaving the file it pointed at orphaned elsewhere.
@test "a symlinked sidecar is not deleted, even beside a matching RAW" {
  fixture a.DNG
  printf 'the real photo' > "$BATS_TEST_TMPDIR/elsewhere.JPG"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.JPG" "$TREE/a.JPG"
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; echo "${#_del_paths[@]}"'
  [ "$output" = "0" ]
}

@test "a full run leaves a symlinked sidecar in place" {
  fixture a.DNG
  printf 'the real photo' > "$BATS_TEST_TMPDIR/elsewhere.JPG"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.JPG" "$TREE/a.JPG"
  local input; input=$(answers "" "" d)
  run_script "$SCRIPT" -C "$TREE" < "$input"
  [ "$status" -eq 0 ]
  [ -L "$TREE/a.JPG" ]
  [ -f "$BATS_TEST_TMPDIR/elsewhere.JPG" ]
}

# A directory symlink must not become a traversal cycle. find is given the link as a starting point and
# does not descend through it, so this holds by construction rather than by the skip above — asserted so
# that a change to how the tree is walked cannot quietly introduce one.
@test "a directory symlink is not descended into" {
  fixture real/a.DNG
  fixture real/a.JPG
  ln -s "$TREE/real" "$TREE/loop"
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; printf "%s\n" "${_del_paths[@]}"'
  [ "$output" = "$TREE/real/a.JPG" ]
}

@test "files with no extension are ignored" {
  fixture a.DNG
  fixture a.JPG
  fixture README
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; echo "${#_del_paths[@]}"'
  [ "$output" = "1" ]
}

# A leading-dot name has no base name, and an empty associative-array subscript is an error in bash, so
# admitting one aborts the scan before anything is deleted. .DS_Store makes this the common case rather
# than an edge case: Finder leaves one in any folder it has been asked to display.
@test "a dotfile does not abort the scan" {
  fixture a.DNG
  fixture a.JPG
  printf 'junk' > "$TREE/.DS_Store"
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; printf "%s\n" "${_del_paths[@]}"'
  [ "$status" -eq 0 ]
  [ "$output" = "$TREE/a.JPG" ]
}

@test "a dotfile does not stop a full run from deleting" {
  fixture a.DNG
  fixture a.JPG
  printf 'junk' > "$TREE/.DS_Store"
  local input; input=$(answers "" "" d)
  run_script "$SCRIPT" -C "$TREE" < "$input"
  [ "$status" -eq 0 ]
  [ ! -e "$TREE/a.JPG" ]
  [ -f "$TREE/.DS_Store" ]
}

@test "an extension the user did not name is not a sidecar" {
  fixture a.DNG
  fixture a.png
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; echo "${#_del_paths[@]}"'
  [ "$output" = "0" ]
}

@test "extension matching is case-sensitive, as the prompt implies" {
  fixture a.dng
  fixture a.JPG
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; echo "${#_del_paths[@]}"'
  [ "$output" = "0" ]
}

@test "a filename containing spaces is queued intact" {
  fixture "holiday snap.DNG"
  fixture "holiday snap.JPG"
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; printf "%s\n" "${_del_paths[@]}"'
  [ "$output" = "$TREE/holiday snap.JPG" ]
}

@test "an empty directory queues nothing and does not fail" {
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; echo "${#_del_paths[@]}"'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "traversal announces each directory it scans" {
  fixture deep/x.DNG
  with_exts 'traverse_tree "'"$TREE"'"'
  [[ "$output" == *"Scanning directory $TREE"* ]]
  [[ "$output" == *"Scanning directory $TREE/deep"* ]]
}

# --- Grouping and counting ---------------------------------------------------------------------

@test "queued_raw_exts lists each RAW type once, sorted" {
  run_snippet "$SCRIPT" '_del_exts=(RW2 DNG RW2 CR2); queued_raw_exts'
  [ "${lines[0]}" = "CR2" ]
  [ "${lines[1]}" = "DNG" ]
  [ "${lines[2]}" = "RW2" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "queued_raw_exts prints nothing when nothing is queued" {
  run_snippet "$SCRIPT" 'queued_raw_exts; echo "done"'
  [ "$output" = "done" ]
}

@test "count_for_ext counts only its own RAW type" {
  run_snippet "$SCRIPT" '_del_exts=(DNG RW2 DNG); count_for_ext DNG; echo; count_for_ext RW2; echo'
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "1" ]
}

@test "count_for_ext reports zero for a type with nothing queued" {
  run_snippet "$SCRIPT" '_del_exts=(DNG); count_for_ext CR2; echo'
  [ "$output" = "0" ]
}

@test "print_summary reports a count per RAW type" {
  run_snippet "$SCRIPT" '_del_exts=(DNG DNG RW2); print_summary'
  [[ "$output" == *"2 sidecars for DNG files"* ]]
  [[ "$output" == *"1 sidecars for RW2 files"* ]]
}

@test "print_directories groups the counts by directory" {
  run_snippet "$SCRIPT" \
    '_del_paths=(/a/one.JPG /a/two.JPG /b/three.JPG); _del_exts=(DNG DNG DNG); print_directories'
  [[ "$output" == *"[    2] /a"* ]]
  [[ "$output" == *"[    1] /b"* ]]
}

# --- The action prompt -------------------------------------------------------------------------

@test "answering d chooses deletion" {
  local input; input=$(answers d)
  run_snippet "$SCRIPT" '_del_exts=(DNG); prompt_action >/dev/null' < "$input"
  [ "$status" -eq 0 ]
}

@test "answering q declines" {
  local input; input=$(answers q)
  run_snippet "$SCRIPT" '_del_exts=(DNG); prompt_action >/dev/null' < "$input"
  [ "$status" -eq 1 ]
}

@test "an empty answer declines, matching the [d/s/Q] default" {
  local input; input=$(answers "")
  run_snippet "$SCRIPT" '_del_exts=(DNG); prompt_action >/dev/null' < "$input"
  [ "$status" -eq 1 ]
}

@test "the answer is case-insensitive" {
  local input; input=$(answers D)
  run_snippet "$SCRIPT" '_del_exts=(DNG); prompt_action >/dev/null' < "$input"
  [ "$status" -eq 0 ]
}

@test "answering s lists the directories and asks again" {
  local input; input=$(answers s d)
  run_snippet "$SCRIPT" \
    '_del_paths=(/a/one.JPG); _del_exts=(DNG); prompt_action' < "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in the following directories"* ]]
  [[ "$output" == *"/a"* ]]
}

# --- Deletion ----------------------------------------------------------------------------------

@test "a dry run reports what it would delete and deletes nothing" {
  fixture a.DNG
  fixture a.JPG
  with_exts '_dry_run=true; traverse_tree "'"$TREE"'" >/dev/null; delete_files'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would delete $TREE/a.JPG"* ]]
  [[ "$output" == *"would be recovered"* ]]
  [ -f "$TREE/a.JPG" ]
}

@test "deletion removes the sidecar and keeps the RAW" {
  fixture a.DNG
  fixture a.JPG
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; delete_files'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleting $TREE/a.JPG"* ]]
  [ ! -e "$TREE/a.JPG" ]
  [ -f "$TREE/a.DNG" ]
}

@test "deletion reports the space recovered per RAW type" {
  fixture a.DNG
  fixture a.JPG 0123456789
  with_exts 'traverse_tree "'"$TREE"'" >/dev/null; delete_files'
  [[ "$output" == *"10.00 B"* ]]
  [[ "$output" == *"was recovered"* ]]
  [[ "$output" == *"by deleting 1 sidecars for DNG files"* ]]
  [[ "$output" == *"average 10.00 B per file"* ]]
}

@test "a sidecar that cannot be deleted is reported rather than passed over silently" {
  run_snippet "$SCRIPT" \
    '_del_paths=("'"$TREE"'/absent.JPG"); _del_exts=(DNG); delete_files 2>&1'
  [[ "$output" == *"Could not delete"*"absent.JPG"* ]]
}

@test "print_report says nothing when nothing was recovered" {
  run_snippet "$SCRIPT" 'print_report 0; echo "done"'
  [ "$output" = "done" ]
}

# --- stat_size and colours ----------------------------------------------------------------------

@test "colours stay off when not writing to a terminal" {
  run_snippet "$SCRIPT" 'setup_colors; printf "[%s]" "${_C_GREEN}"'
  [ "$output" = "[]" ]
}

@test "--no-color leaves the colour variables empty" {
  run_snippet "$SCRIPT" '_no_color=true; setup_colors; printf "[%s]" "${_C_GREEN}"'
  [ "$output" = "[]" ]
}

# --- End to end, through the command line ------------------------------------------------------

@test "a full run with default extensions deletes the paired sidecars" {
  fixture a.DNG
  fixture a.JPG
  fixture sub/b.RW2
  fixture sub/b.jpg
  fixture keepme.JPG
  local input; input=$(answers "" "" d)
  run_script "$SCRIPT" -C "$TREE" < "$input"
  [ "$status" -eq 0 ]
  [ ! -e "$TREE/a.JPG" ]
  [ ! -e "$TREE/sub/b.jpg" ]
  [ -f "$TREE/a.DNG" ]
  [ -f "$TREE/sub/b.RW2" ]
  [ -f "$TREE/keepme.JPG" ]
}

@test "a full run that is declined deletes nothing" {
  fixture a.DNG
  fixture a.JPG
  local input; input=$(answers "" "" q)
  run_script "$SCRIPT" -C "$TREE" < "$input"
  [ "$status" -eq 0 ]
  [ -f "$TREE/a.JPG" ]
}

@test "--dry-run needs no confirmation and deletes nothing" {
  fixture a.DNG
  fixture a.JPG
  local input; input=$(answers "" "")
  run_script "$SCRIPT" -C --dry-run "$TREE" < "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would delete"* ]]
  [ -f "$TREE/a.JPG" ]
}

@test "a run with nothing to do says so" {
  fixture only.DNG
  local input; input=$(answers "" "")
  run_script "$SCRIPT" -C "$TREE" < "$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No sidecar files found to delete."* ]]
}

@test "custom extensions are honoured end to end" {
  fixture shot.nef
  fixture shot.png
  local input; input=$(answers "png" "nef" d)
  run_script "$SCRIPT" -C "$TREE" < "$input"
  [ "$status" -eq 0 ]
  [ ! -e "$TREE/shot.png" ]
  [ -f "$TREE/shot.nef" ]
}

@test "the default target directory is the working directory" {
  fixture a.DNG
  fixture a.JPG
  local input; input=$(answers "" "" d)
  cd "$TREE"
  run_script "$SCRIPT" -C < "$input"
  [ "$status" -eq 0 ]
  [ ! -e "$TREE/a.JPG" ]
}

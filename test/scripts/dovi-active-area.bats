#!/usr/bin/env bats
#
# dovi-active-area rewrites multi-gigabyte files in place, so two properties matter more than any
# other: it must read the metadata correctly, and it must never destroy a file it could not replace.
#
# The reading is tested against JSON shaped exactly as the real tools emit it — mediainfo's HDR_Format
# with its trailing separator, and dovi_tool's L5 block nested under the display-management version the
# RPU happens to use — because that shape is the thing a tool upgrade breaks, and a jq path that stops
# matching reports every file as clean rather than failing.
#
# The rewriting is tested through the stubs, which record what was asked of each tool. The assertions
# that matter are the ones about the source file: it exists, unchanged, after every failure mode.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/media/dovi-active-area/dovi-active-area.sh"

  LIB="$BATS_TEST_TMPDIR/films"
  mkdir -p "$LIB"

  # Named explicitly, so the repository's own committed conf is never what the script reads.
  CONFIG_FILE="$BATS_TEST_TMPDIR/dovi-active-area.conf"
  export CONFIG_FILE
  : > "$CONFIG_FILE"
}

########################################
# Creates a fake Matroska file with recognisable contents.
# Arguments:
#   name: File name relative to LIB.
########################################
film() {
  printf 'original matroska bytes' > "$LIB/$1"
}

########################################
# Makes mediainfo report a Dolby Vision video track.
# Arguments:
#   profile: Optional HDR_Format_Profile, defaulting to the real "dvhe.08 / " shape.
########################################
mediainfo_says_dv() {
  local profile="${1:-dvhe.08 / }"
  stub_outputs mediainfo <<JSON
{"media":{"track":[
  {"@type":"General","Format":"Matroska"},
  {"@type":"Video","CodecID":"V_MPEGH/ISO/HEVC","HDR_Format":"Dolby Vision, Version 1.0, Profile 8.1, dvhe.08.06, BL+RPU / SMPTE ST 2086","HDR_Format_Profile":"${profile}"}
]}}
JSON
}

########################################
# Makes dovi_tool report an active area for one RPU file.
#
# Keyed on the RPU's name because a run reads two of them: the sample taken from the source, and the
# rewritten RPU the verification reads back. The JSON carries dovi_tool's progress line ahead of the
# document, which is what the script has to strip before jq sees it.
# Arguments:
#   rpu: Basename of the RPU file being answered for.
#   left, right, top, bottom: The offsets to report.
#   container: Optional metadata container key, defaulting to the CM v2.9 one.
########################################
dovi_reports() {
  local rpu="$1" left="$2" right="$3" top="$4" bottom="$5" container="${6:-cmv29_metadata}"
  cat > "$STUB_FIXTURES/dovi_tool.info.${rpu}.stdout" <<JSON
Parsing RPU file...
{
  "dovi_profile": 8,
  "vdr_dm_data": {
    "${container}": {
      "ext_metadata_blocks": [
        {"Level1": {"min_pq": 0}},
        {"Level5": {"active_area_left_offset": ${left}, "active_area_right_offset": ${right}, "active_area_top_offset": ${top}, "active_area_bottom_offset": ${bottom}}}
      ]
    }
  }
}
JSON
}

########################################
# Makes mkvmerge report a video track, as the remux needs it.
# Arguments:
#   id: Track id, defaulting to 0.
#   duration: default_duration in nanoseconds, defaulting to 24fps.
########################################
mkvmerge_reports_track() {
  local id="${1:-0}" duration="${2:-41666666}"
  stub_outputs mkvmerge <<JSON
{"tracks":[
  {"id":${id},"type":"video","codec":"HEVC/H.265/MPEG-H","properties":{"default_duration":${duration},"language":"eng","track_name":null}},
  {"id":9,"type":"audio","codec":"E-AC-3","properties":{"language":"eng"}}
]}
JSON
}

# --- Reading the metadata, which is what a tool upgrade breaks ----------------------------------

@test "the Dolby Vision profile is read from mediainfo's video track" {
  film movie.mkv
  mediainfo_says_dv
  run_func "$SCRIPT" dv_profile "$LIB/movie.mkv"
  [ "$status" -eq 0 ]
  [ "$output" = "dvhe.08" ]
}

@test "a file with no Dolby Vision metadata yields no profile" {
  film movie.mkv
  stub_outputs mediainfo <<'JSON'
{"media":{"track":[{"@type":"Video","CodecID":"V_MPEGH/ISO/HEVC","HDR_Format":"SMPTE ST 2086, HDR10"}]}}
JSON
  run_func "$SCRIPT" dv_profile "$LIB/movie.mkv"
  [ "$output" = "" ]
}

@test "a file with no video track at all yields no profile" {
  film movie.mkv
  stub_outputs mediainfo <<'JSON'
{"media":{"track":[{"@type":"General","Format":"Matroska"},{"@type":"Audio","Format":"FLAC"}]}}
JSON
  run_func "$SCRIPT" dv_profile "$LIB/movie.mkv"
  [ "$output" = "" ]
}

@test "the active area is read from the L5 block" {
  dovi_reports probe.bin 0 0 210 210
  run_func "$SCRIPT" read_active_area "$BATS_TEST_TMPDIR/probe.bin" 100
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '0\t0\t210\t210')" ]
}

# The block moves between metadata containers with the display-management version, which is why the
# program searches the document instead of naming a path. A tool that knew only cmv29 would report every
# CM v4.0 file as declaring nothing.
@test "the active area is found under either display-management container" {
  dovi_reports probe.bin 0 0 132 132 cmv40_metadata
  run_func "$SCRIPT" read_active_area "$BATS_TEST_TMPDIR/probe.bin" 100
  [ "$output" = "$(printf '0\t0\t132\t132')" ]
}

@test "an RPU with no L5 block reads as no active area" {
  cat > "$STUB_FIXTURES/dovi_tool.info.probe.bin.stdout" <<'JSON'
Parsing RPU file...
{"dovi_profile": 5, "vdr_dm_data": {"cmv29_metadata": {"ext_metadata_blocks": [{"Level1": {"min_pq": 0}}]}}}
JSON
  run_func "$SCRIPT" read_active_area "$BATS_TEST_TMPDIR/probe.bin" 100
  [ "$output" = "" ]
}

@test "only a non-zero offset counts as a declared area" {
  run_func "$SCRIPT" declares_area "$(printf '0\t0\t0\t0')"
  [ "$status" -eq 1 ]
  run_func "$SCRIPT" declares_area ""
  [ "$status" -eq 1 ]
  run_func "$SCRIPT" declares_area "$(printf '0\t0\t210\t210')"
  [ "$status" -eq 0 ]
  run_func "$SCRIPT" declares_area "$(printf '8\t0\t0\t0')"
  [ "$status" -eq 0 ]
}

@test "the video track properties a remux must restate are read from mkvmerge" {
  film movie.mkv
  mkvmerge_reports_track 0 41666666
  run_func "$SCRIPT" video_track "$LIB/movie.mkv"
  [ "$output" = "$(printf '0\t41666666\teng\t')" ]
}

@test "a file with no video track yields no track properties" {
  film movie.mkv
  stub_outputs mkvmerge <<'JSON'
{"tracks":[{"id":0,"type":"audio","codec":"FLAC","properties":{"language":"eng"}}]}
JSON
  run_func "$SCRIPT" video_track "$LIB/movie.mkv"
  [ "$output" = "" ]
}

# --- Reporting ---------------------------------------------------------------------------------

@test "a file that declares an active area is reported with its offsets" {
  film movie.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 210 210
  run_script "$SCRIPT" "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"movie.mkv: dvhe.08, active area 0 0 210 210"* ]]
  [[ "$output" == *"1 Dolby Vision file(s) of 1 examined; 1 declare an active area."* ]]
  [[ "$output" == *"Pass --fix"* ]]
}

@test "a file that declares nothing is reported as clean" {
  film movie.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 0 0
  run_script "$SCRIPT" "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"movie.mkv: dvhe.08, no active area declared"* ]]
  [[ "$output" == *"0 declare an active area"* ]]
}

@test "a non-Dolby-Vision file is counted and passed over" {
  film movie.mkv
  stub_outputs mediainfo <<'JSON'
{"media":{"track":[{"@type":"Video","HDR_Format":"SMPTE ST 2086, HDR10"}]}}
JSON
  run_script "$SCRIPT" "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 Dolby Vision file(s) of 1 examined"* ]]
  [[ "$output" == *"1 file(s) carried no Dolby Vision metadata."* ]]
  run stub_calls dovi_tool
  [ "$output" = "0" ]
}

@test "the report reads no metadata from a file it was not pointed at" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  printf 'x' > "$BATS_TEST_TMPDIR/elsewhere/other.mkv"
  film movie.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 0 0
  run_script "$SCRIPT" "$LIB"
  run bash -c "grep -c 'other.mkv' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "a single file may be named instead of a directory" {
  film movie.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 210 210
  run_script "$SCRIPT" "$LIB/movie.mkv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 Dolby Vision file(s) of 1 examined"* ]]
}

@test "a file that is not Matroska is refused" {
  printf 'x' > "$BATS_TEST_TMPDIR/movie.mp4"
  run_script "$SCRIPT" "$BATS_TEST_TMPDIR/movie.mp4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a Matroska file"* ]]
}

@test "a path that does not exist is refused" {
  run_script "$SCRIPT" "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "the sample length reaches ffmpeg as a duration" {
  film movie.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 0 0
  run_script "$SCRIPT" --sample 4 "$LIB"
  stub_called 'ffmpeg .*-to 00:00:4'
}

@test "the requested frame reaches dovi_tool" {
  film movie.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 0 0
  run_script "$SCRIPT" --frame 7 "$LIB"
  stub_called 'dovi_tool info -f 7'
}

@test "a sample length that is not a positive number is refused" {
  run_script "$SCRIPT" --sample 0 "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive whole number of seconds"* ]]
}

# --- Rewriting: the tool sequence ---------------------------------------------------------------

@test "the rewrite extracts, zeroes, verifies, injects and remuxes, in that order" {
  film movie.mkv
  mkvmerge_reports_track
  # The rewritten RPU is what the verification reads, and it must come back zeroed.
  dovi_reports rpu-zeroed.bin 0 0 0 0
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 0 ]
  run bash -c "grep -oE '^(mkvextract|dovi_tool|mkvmerge)' '$STUB_CALLS' | tr '\n' ' '"
  # mkvmerge is asked for the track properties first, and does the remux last.
  [ "$output" = "mkvmerge mkvextract dovi_tool dovi_tool dovi_tool dovi_tool mkvmerge " ]
}

@test "the video track id from mkvmerge is the one extracted" {
  film movie.mkv
  mkvmerge_reports_track 3
  dovi_reports rpu-zeroed.bin 0 0 0 0
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 0 ]
  stub_called 'mkvextract tracks .*3:'
}

# A raw HEVC stream has no timing of its own, so a remux that does not restate the frame duration
# leaves mkvmerge guessing — and a wrong guess desynchronises every audio track in the file.
@test "the remux restates the source's frame duration and language" {
  film movie.mkv
  mkvmerge_reports_track 0 20833333
  dovi_reports rpu-zeroed.bin 0 0 0 0
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  stub_called 'mkvmerge .*--default-duration 0:20833333ns'
  stub_called 'mkvmerge .*--language 0:eng'
}

@test "the rewritten file takes the original's name" {
  film movie.mkv
  mkvmerge_reports_track
  dovi_reports rpu-zeroed.bin 0 0 0 0
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 0 ]
  [ -f "$LIB/movie.mkv" ]
  run cat "$LIB/movie.mkv"
  [ "$output" = "stub matroska" ]
  [ ! -e "$LIB/movie.mkv.orig" ]
}

@test "--keep-original leaves the source beside the rewrite" {
  film movie.mkv
  mkvmerge_reports_track
  dovi_reports rpu-zeroed.bin 0 0 0 0
  run_snippet "$SCRIPT" "_keep_original=true; _scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 0 ]
  run cat "$LIB/movie.mkv.orig"
  [ "$output" = "original matroska bytes" ]
  run cat "$LIB/movie.mkv"
  [ "$output" = "stub matroska" ]
}

@test "no working directory is left behind" {
  film movie.mkv
  mkvmerge_reports_track
  dovi_reports rpu-zeroed.bin 0 0 0 0
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  run bash -c "find '$LIB' -maxdepth 1 -name '.dovi-active-area.*' | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

# --- Rewriting: every failure must cost the work and not the file -------------------------------

@test "a file whose video track cannot be extracted is left alone" {
  film movie.mkv
  mkvmerge_reports_track
  stub_fails mkvextract
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed while extracting the video track"* ]]
  [[ "$output" == *"The file is untouched."* ]]
  run cat "$LIB/movie.mkv"
  [ "$output" = "original matroska bytes" ]
}

@test "a failed remux leaves the original in place" {
  film movie.mkv
  mkvmerge_reports_track
  dovi_reports rpu-zeroed.bin 0 0 0 0
  stub_fails mkvmerge
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 1 ]
  run cat "$LIB/movie.mkv"
  [ "$output" = "original matroska bytes" ]
}

# The verification is the whole reason the original survives a rewrite that silently did nothing.
@test "an RPU that still declares an area after editing is refused, and the file kept" {
  film movie.mkv
  mkvmerge_reports_track
  dovi_reports rpu-zeroed.bin 0 0 210 210
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed while verifying the rewritten RPU"* ]]
  run cat "$LIB/movie.mkv"
  [ "$output" = "original matroska bytes" ]
  run bash -c "grep -c 'mkvmerge -o' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "a file mkvmerge reports no video track for is refused before any work" {
  film movie.mkv
  stub_outputs mkvmerge <<'JSON'
{"tracks":[{"id":0,"type":"audio","codec":"FLAC","properties":{"language":"eng"}}]}
JSON
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no video track that mkvmerge recognises"* ]]
  run bash -c "grep -c 'mkvextract' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

# Nearly every file in the library this serves is a hard link to a torrent still being seeded, so a
# rewrite that wrote through the inode would fail the tracker's hash check on a file the user never
# meant to touch. The replacement therefore has to land on a new inode — which is what mv does and what
# cp would not.
@test "the copy a torrent is seeding is left byte-for-byte alone" {
  film movie.mkv
  ln "$LIB/movie.mkv" "$BATS_TEST_TMPDIR/seeding.mkv"
  mkvmerge_reports_track
  dovi_reports rpu-zeroed.bin 0 0 0 0
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/seeding.mkv"
  [ "$output" = "original matroska bytes" ]
  # A shared inode would make these equal, and the seeding copy would carry the rewrite.
  [ ! "$LIB/movie.mkv" -ef "$BATS_TEST_TMPDIR/seeding.mkv" ]
}

@test "--keep-original leaves the seeding copy's inode intact" {
  film movie.mkv
  ln "$LIB/movie.mkv" "$BATS_TEST_TMPDIR/seeding.mkv"
  mkvmerge_reports_track
  dovi_reports rpu-zeroed.bin 0 0 0 0
  run_snippet "$SCRIPT" "_keep_original=true; _scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 0 ]
  # The kept original is the same inode the torrent has, so nothing was copied to keep it.
  [ "$LIB/movie.mkv.orig" -ef "$BATS_TEST_TMPDIR/seeding.mkv" ]
  run cat "$BATS_TEST_TMPDIR/seeding.mkv"
  [ "$output" = "original matroska bytes" ]
}

@test "a file with more than one name is warned about" {
  film movie.mkv
  ln "$LIB/movie.mkv" "$LIB/linked.mkv"
  mkvmerge_reports_track
  dovi_reports rpu-zeroed.bin 0 0 0 0
  run_snippet "$SCRIPT" "_scratch='$BATS_TEST_TMPDIR/scratch'; mkdir -p \$_scratch; fix_file '$LIB/movie.mkv'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has 2 names (hard links)"* ]]
}

# --- Rewriting: what it takes to get there ------------------------------------------------------

@test "--dry-run names what it would rewrite and calls no rewriting tool" {
  film movie.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 210 210
  run_script "$SCRIPT" --fix --dry-run "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would zero the active area"* ]]
  [[ "$output" == *"Would rewrite 1 file(s)."* ]]
  run bash -c "grep -cE 'mkvextract|mkvmerge' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
  run cat "$LIB/movie.mkv"
  [ "$output" = "original matroska bytes" ]
}

@test "a declined file is not rewritten" {
  film movie.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 210 210
  printf 'n\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" --fix "$LIB" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  run cat "$LIB/movie.mkv"
  [ "$output" = "original matroska bytes" ]
}

@test "answering all rewrites the rest without asking again" {
  film a.mkv
  film b.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 210 210
  dovi_reports rpu-zeroed.bin 0 0 0 0
  mkvmerge_reports_track
  # mkvmerge is asked for its JSON and for the remux; the JSON fixture answers both harmlessly.
  printf 'a\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" --fix "$LIB" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rewrote 2 file(s)."* ]]
}

@test "quitting stops the run where it stands" {
  film a.mkv
  film b.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 210 210
  printf 'q\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" --fix "$LIB" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopping here."* ]]
  [[ "$output" == *"Rewrote 0 file(s)."* ]]
}

# With no stdin there is nothing to answer with, and treating that as "no" for every file would look
# like a completed run that decided against everything.
@test "end of input stops the run rather than declining everything" {
  film a.mkv
  film b.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 210 210
  run_script "$SCRIPT" --fix "$LIB" < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopping here."* ]]
}

@test "--yes needs --fix to mean anything" {
  run_script "$SCRIPT" --yes "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--yes only means something with --fix."* ]]
}

@test "--keep-original needs --fix to mean anything" {
  run_script "$SCRIPT" --keep-original "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--keep-original only means something with --fix."* ]]
}

@test "a missing dovi_tool is reported with where to get it" {
  film movie.mkv
  run_snippet "$SCRIPT" "_dovi_tool=definitely-not-installed; check_deps"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required tool(s): definitely-not-installed"* ]]
  [[ "$output" == *"github.com/quietvoid/dovi_tool/releases"* ]]
}

@test "a configured DOVI_TOOL_BIN is what gets run" {
  film movie.mkv
  ln -sf "$TEST_DIR/stubs/_stub" "$BATS_TEST_TMPDIR/my-dovi_tool"
  printf 'DOVI_TOOL_BIN="%s"\n' "$BATS_TEST_TMPDIR/my-dovi_tool" > "$CONFIG_FILE"
  mediainfo_says_dv
  run_script "$SCRIPT" "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'my-dovi_tool extract-rpu'
}

@test "the options are recorded as parse_options sees them" {
  run_snippet "$SCRIPT" "parse_options -f -y -k -n -s 5 --frame 3 -C '$LIB'; printf '%s|%s|%s|%s|%s|%s|%s|%s' \"\$_fix\" \"\$_assume_yes\" \"\$_keep_original\" \"\$_dry_run\" \"\$_sample_opt\" \"\$_frame_opt\" \"\$_no_color\" \"\$_target\""
  [ "$output" = "true|true|true|true|5|3|true|$LIB" ]
}

@test "an unknown option is refused" {
  run_script "$SCRIPT" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'."* ]]
}

@test "more than one path argument is refused" {
  run_script "$SCRIPT" "$LIB" "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected at most one path argument, got 2."* ]]
}

# log_debug writes to standard output, which for a function whose output is its return value means the
# diagnostic lands inside the value. A run with --debug therefore has to produce the same verdict as one
# without it.
@test "--debug does not corrupt the metadata it is reporting on" {
  film movie.mkv
  mediainfo_says_dv
  dovi_reports probe.bin 0 0 210 210
  run_script "$SCRIPT" --debug "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"movie.mkv: dvhe.08, active area 0 0 210 210"* ]]
  [[ "$output" == *"Sampling 10s"* ]]
}

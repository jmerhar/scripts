#!/usr/bin/env bats
#
# transcode-audio re-encodes audio, which cannot be undone, and writes files into a library whose
# members are mostly hard links to seeding torrents. So the assertions that matter are: it converts only
# what needs converting, it never writes through an existing file, and it refuses to give a converted
# name to a file whose audio did not actually change.
#
# ffmpeg and ffprobe are stubbed. ffprobe answers per file, because a run inspects two — the source and
# the result it verifies — and the whole point of the verification is that those two can disagree.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/media/transcode-audio/transcode-audio.sh"

  LIB="$BATS_TEST_TMPDIR/tv"
  mkdir -p "$LIB"

  CONFIG_FILE="$BATS_TEST_TMPDIR/transcode-audio.conf"
  export CONFIG_FILE
  : > "$CONFIG_FILE"
}

########################################
# Creates a fake Matroska file with recognisable contents.
# Arguments:
#   name: File name relative to LIB.
########################################
film() {
  printf 'original bytes' > "$LIB/$1"
}

########################################
# Makes ffprobe report audio streams for one file.
#
# Shaped as the real document is, empty "programs" and "stream_groups" wrappers included. Which fields
# ffprobe emits depends on what -show_entries asked for, so a fixture shaped to suit the filter rather
# than to match ffprobe can pass while the real interface does not answer at all.
# Arguments:
#   name: Basename the answer applies to.
#   Remaining arguments are "codec:channels" pairs, in stream order.
########################################
probe_audio() {
  local name="$1"
  shift
  local json='{"programs":[],"stream_groups":[],"streams":[' first=true pair codec channels
  for pair in "$@"; do
    codec="${pair%%:*}"
    channels="${pair##*:}"
    [[ "$first" == true ]] || json+=','
    first=false
    json+="{\"codec_type\":\"audio\",\"codec_name\":\"${codec}\",\"channels\":${channels}}"
  done
  json+=']}'
  printf '%s\n' "$json" > "$STUB_FIXTURES/ffprobe.${name}.stdout"
}

# --- Deciding what needs converting -------------------------------------------------------------

@test "audio streams are read as codec and channel count, in order" {
  film movie.mkv
  probe_audio movie.mkv eac3:6 eac3:2
  run_func "$SCRIPT" audio_streams "$LIB/movie.mkv"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'eac3\t6')" ]
  [ "${lines[1]}" = "$(printf 'eac3\t2')" ]
}

# The field list is part of the contract: naming any field in -show_entries makes ffprobe emit only those,
# so a filter that selects on a field nobody asked for sees no streams at all and every file reads as
# already converted.
@test "ffprobe is asked for every field the filter reads" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  run_func "$SCRIPT" audio_streams "$LIB/movie.mkv"
  [ "$status" -eq 0 ]
  stub_called 'ffprobe .*-show_entries stream=codec_type,codec_name,channels'
}

@test "a stream with no channel count reported falls back to stereo" {
  film movie.mkv
  printf '%s\n' '{"streams":[{"codec_type":"audio","codec_name":"eac3"}]}' > "$STUB_FIXTURES/ffprobe.movie.mkv.stdout"
  run_func "$SCRIPT" audio_streams "$LIB/movie.mkv"
  [ "$output" = "$(printf 'eac3\t2')" ]
}

@test "a file whose every audio track is already the target codec needs nothing" {
  run_snippet "$SCRIPT" "_format=ac3; needs_transcode \"\$(printf 'ac3\\t6\\nac3\\t2')\""
  [ "$status" -eq 1 ]
}

@test "one track in another codec is enough to need converting" {
  run_snippet "$SCRIPT" "_format=ac3; needs_transcode \"\$(printf 'ac3\\t6\\neac3\\t2')\""
  [ "$status" -eq 0 ]
}

# One -b:a would give a stereo commentary a 5.1 track's bitrate, or the other way round.
@test "each track gets the bitrate its channel count calls for" {
  run_snippet "$SCRIPT" "_surround_bitrate=640k; _stereo_bitrate=256k; bitrate_args \"\$(printf 'eac3\\t6\\neac3\\t2\\neac3\\t1')\" | tr '\\n' ' '"
  [ "$output" = "-b:a:0 640k -b:a:1 256k -b:a:2 256k " ]
}

# --- Naming -------------------------------------------------------------------------------------

@test "the marker replaces the source codec's token in the name" {
  run_snippet "$SCRIPT" "_marker=AC3.CC; converted_name '/tv/Show.S01E01.1080p.WEB.DDP5.1.H264-GRP.mkv'"
  [ "$output" = "/tv/Show.S01E01.1080p.WEB.AC3.CC.H264-GRP.mkv" ]
}

@test "other codec tokens are recognised too" {
  run_snippet "$SCRIPT" "_marker=AC3.CC; converted_name '/tv/Show.S01E01.EAC3.H264-GRP.mkv'"
  [ "$output" = "/tv/Show.S01E01.AC3.CC.H264-GRP.mkv" ]
  run_snippet "$SCRIPT" "_marker=AC3.CC; converted_name '/tv/Show.S01E01.DD+5.1.H264-GRP.mkv'"
  [ "$output" = "/tv/Show.S01E01.AC3.CC.H264-GRP.mkv" ]
}

@test "with no codec token the marker sits before the release group" {
  run_snippet "$SCRIPT" "_marker=AC3.CC; converted_name '/tv/under.the.vines.s01e01.1080p.web.h264-ggez.mkv'"
  [ "$output" = "/tv/under.the.vines.s01e01.1080p.web.h264.AC3.CC-ggez.mkv" ]
}

@test "with neither, the marker goes at the end" {
  run_snippet "$SCRIPT" "_marker=AC3.CC; converted_name '/tv/plain name.mkv'"
  [ "$output" = "/tv/plain name.AC3.CC.mkv" ]
}

# A codec token in a parent directory's name describes other files, not this one.
@test "only the file name is rewritten, never a parent directory" {
  run_snippet "$SCRIPT" "_marker=AC3.CC; converted_name '/tv/DDP5.1 releases/Show.S01E01.H264-GRP.mkv'"
  [ "$output" = "/tv/DDP5.1 releases/Show.S01E01.H264.AC3.CC-GRP.mkv" ]
}

@test "the marker follows the requested format" {
  run_snippet "$SCRIPT" "_format_opt=eac3; apply_config; printf '%s' \"\$_marker\""
  [ "$output" = "EAC3.CC" ]
}

# --- Converting ---------------------------------------------------------------------------------

@test "the encode copies every stream and re-encodes only the audio" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  probe_audio "movie.AC3.CC.mkv.partial" ac3:6
  run_snippet "$SCRIPT" "_format=ac3; _marker=AC3.CC; _surround_bitrate=640k; _stereo_bitrate=256k; transcode_file '$LIB/movie.mkv' \"\$(printf 'eac3\\t6')\""
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg -nostdin .*-map 0 -c copy -c:a ac3 -b:a:0 640k -map_chapters 0'
  [ -f "$LIB/movie.AC3.CC.mkv" ]
}

# Without -nostdin, ffmpeg reads the standard input the prompts take their answers from.
@test "ffmpeg is told not to read standard input" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  probe_audio "movie.AC3.CC.mkv.partial" ac3:6
  run_snippet "$SCRIPT" "_format=ac3; _marker=AC3.CC; transcode_file '$LIB/movie.mkv' \"\$(printf 'eac3\\t6')\""
  stub_called 'ffmpeg -nostdin'
}

@test "the original is kept unless replacing was asked for" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  probe_audio "movie.AC3.CC.mkv.partial" ac3:6
  run_snippet "$SCRIPT" "_format=ac3; _marker=AC3.CC; transcode_file '$LIB/movie.mkv' \"\$(printf 'eac3\\t6')\""
  [ -f "$LIB/movie.mkv" ]
  [ -f "$LIB/movie.AC3.CC.mkv" ]
}

@test "--replace removes the original once the result is verified" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  probe_audio "movie.AC3.CC.mkv.partial" ac3:6
  run_snippet "$SCRIPT" "_format=ac3; _marker=AC3.CC; _replace=true; transcode_file '$LIB/movie.mkv' \"\$(printf 'eac3\\t6')\""
  [ "$status" -eq 0 ]
  [ ! -e "$LIB/movie.mkv" ]
  [ -f "$LIB/movie.AC3.CC.mkv" ]
}

# ffmpeg exits 0 having copied the audio through when asked for an encoder it does not have, which would
# otherwise leave a library of files labelled as converted and still unplayable.
@test "a result whose audio is unchanged is refused, and nothing is left behind" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  probe_audio "movie.AC3.CC.mkv.partial" eac3:6
  run_snippet "$SCRIPT" "_format=ac3; _marker=AC3.CC; transcode_file '$LIB/movie.mkv' \"\$(printf 'eac3\\t6')\""
  [ "$status" -eq 1 ]
  [[ "$output" == *"still has audio that is not ac3"* ]]
  [ ! -e "$LIB/movie.AC3.CC.mkv" ]
  [ ! -e "$LIB/movie.AC3.CC.mkv.partial" ]
  [ -f "$LIB/movie.mkv" ]
}

@test "a failed encode leaves neither a partial file nor a converted name" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  stub_fails ffmpeg
  run_snippet "$SCRIPT" "_format=ac3; _marker=AC3.CC; transcode_file '$LIB/movie.mkv' \"\$(printf 'eac3\\t6')\""
  [ "$status" -eq 1 ]
  [ ! -e "$LIB/movie.AC3.CC.mkv" ]
  [ ! -e "$LIB/movie.AC3.CC.mkv.partial" ]
  [ -f "$LIB/movie.mkv" ]
}

@test "an existing converted file is not overwritten" {
  film movie.mkv
  printf 'existing' > "$LIB/movie.AC3.CC.mkv"
  probe_audio movie.mkv eac3:6
  run_snippet "$SCRIPT" "_format=ac3; _marker=AC3.CC; transcode_file '$LIB/movie.mkv' \"\$(printf 'eac3\\t6')\""
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  run cat "$LIB/movie.AC3.CC.mkv"
  [ "$output" = "existing" ]
}

# The library is mostly hard links to seeding torrents; see CLAUDE.md, "Replacing a file someone else is
# seeding". --replace removes a name, which leaves the other names and their content alone.
@test "the copy a torrent is seeding is left byte-for-byte alone" {
  film movie.mkv
  ln "$LIB/movie.mkv" "$BATS_TEST_TMPDIR/seeding.mkv"
  probe_audio movie.mkv eac3:6
  probe_audio "movie.AC3.CC.mkv.partial" ac3:6
  run_snippet "$SCRIPT" "_format=ac3; _marker=AC3.CC; _replace=true; transcode_file '$LIB/movie.mkv' \"\$(printf 'eac3\\t6')\""
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/seeding.mkv"
  [ "$output" = "original bytes" ]
  [ ! -e "$LIB/movie.mkv" ]
}

# --- Driving it from the command line -----------------------------------------------------------

@test "a file already in the target codec is reported and passed over" {
  film movie.mkv
  probe_audio movie.mkv ac3:6
  run_script "$SCRIPT" "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"movie.mkv: already ac3"* ]]
  [[ "$output" == *"0 carry audio that is not ac3"* ]]
}

@test "--dry-run names the file it would write and encodes nothing" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  run_script "$SCRIPT" --dry-run "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would write movie.AC3.CC.mkv"* ]]
  [[ "$output" == *"Would convert 1 file(s)."* ]]
  run stub_calls ffmpeg
  [ "$output" = "0" ]
}

@test "a file this script already produced is not converted again" {
  film movie.AC3.CC.mkv
  probe_audio movie.AC3.CC.mkv eac3:6
  run_script "$SCRIPT" "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 file(s) examined"* ]]
}

@test "answering all converts the rest without asking again" {
  film a.mkv
  film b.mkv
  probe_audio a.mkv eac3:6
  probe_audio b.mkv eac3:6
  probe_audio "a.AC3.CC.mkv.partial" ac3:6
  probe_audio "b.AC3.CC.mkv.partial" ac3:6
  printf 'a\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" "$LIB" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Converted 2 file(s)."* ]]
}

@test "a declined file is left alone" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  printf 'n\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" "$LIB" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [ ! -e "$LIB/movie.AC3.CC.mkv" ]
  [[ "$output" == *"Converted 0 file(s)."* ]]
}

@test "quitting stops the run" {
  film a.mkv
  film b.mkv
  probe_audio a.mkv eac3:6
  probe_audio b.mkv eac3:6
  printf 'q\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" "$LIB" < "$BATS_TEST_TMPDIR/answers"
  [[ "$output" == *"Stopping here."* ]]
}

@test "a failed encode makes the run exit non-zero" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  stub_fails ffmpeg
  run_script "$SCRIPT" --yes "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 failed"* ]]
}

@test "a format that is not a codec name is refused" {
  run_script "$SCRIPT" --format 'ac3; rm -rf /' "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"plain codec name"* ]]
}

@test "a bitrate that is not a rate is refused" {
  run_script "$SCRIPT" --bitrate loud "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"look like 640k"* ]]
}

@test "the configured bitrates are used when no option overrides them" {
  printf 'SURROUND_BITRATE="448k"\nSTEREO_BITRATE="192k"\n' > "$CONFIG_FILE"
  film movie.mkv
  probe_audio movie.mkv eac3:6
  probe_audio "movie.AC3.CC.mkv.partial" ac3:6
  run_script "$SCRIPT" --yes "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg .*-b:a:0 448k'
}

@test "the options are recorded as parse_options sees them" {
  run_snippet "$SCRIPT" "parse_options -f eac3 -b 448k --stereo 192k -r -y -n -C '$LIB'; printf '%s|%s|%s|%s|%s|%s|%s|%s' \"\$_format_opt\" \"\$_surround_opt\" \"\$_stereo_opt\" \"\$_replace\" \"\$_assume_yes\" \"\$_dry_run\" \"\$_no_color\" \"\$_target\""
  [ "$output" = "eac3|448k|192k|true|true|true|true|$LIB" ]
}

@test "an unknown option is refused" {
  run_script "$SCRIPT" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'."* ]]
}

@test "a path that does not exist is refused" {
  run_script "$SCRIPT" "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

# --- Paths the earlier tests did not reach -------------------------------------------------------

@test "a single file may be named instead of a directory" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  run_script "$SCRIPT" --dry-run "$LIB/movie.mkv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s) examined"* ]]
}

@test "a file that is not Matroska is refused" {
  printf 'x' > "$BATS_TEST_TMPDIR/movie.mp4"
  run_script "$SCRIPT" "$BATS_TEST_TMPDIR/movie.mp4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a Matroska file"* ]]
}

@test "a file with no audio at all is passed over" {
  film silent.mkv
  printf '%s\n' '{"streams":[]}' > "$STUB_FIXTURES/ffprobe.silent.mkv.stdout"
  run_script "$SCRIPT" "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 file(s) examined; 0 carry audio"* ]]
}

@test "answering yes converts just that file" {
  film a.mkv
  film b.mkv
  probe_audio a.mkv eac3:6
  probe_audio b.mkv eac3:6
  probe_audio "a.AC3.CC.mkv.partial" ac3:6
  printf 'yn' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" "$LIB" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [ -f "$LIB/a.AC3.CC.mkv" ]
  [ ! -e "$LIB/b.AC3.CC.mkv" ]
}

# With nothing on standard input there is no answer to read, and treating that as "no" for every file
# would look like a run that considered each one and declined.
@test "end of input stops the run rather than declining everything" {
  film a.mkv
  film b.mkv
  probe_audio a.mkv eac3:6
  probe_audio b.mkv eac3:6
  run_script "$SCRIPT" "$LIB" < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopping here."* ]]
}

# ffmpeg exiting 0 having written nothing is not a converted file, whatever the exit status says.
@test "an empty result is refused and cleaned up" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  : > "$STUB_FIXTURES/ffmpeg.artifact"
  run_snippet "$SCRIPT" "_format=ac3; _marker=AC3.CC; transcode_file '$LIB/movie.mkv' \"\$(printf 'eac3\t6')\""
  [ "$status" -eq 1 ]
  [[ "$output" == *"produced nothing"* ]]
  [ ! -e "$LIB/movie.AC3.CC.mkv" ]
  [ ! -e "$LIB/movie.AC3.CC.mkv.partial" ]
  [ -f "$LIB/movie.mkv" ]
}

@test "--debug names the ffmpeg command it ran" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  probe_audio "movie.AC3.CC.mkv.partial" ac3:6
  run_script "$SCRIPT" --debug --yes "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running: ffmpeg -nostdin"* ]]
}

@test "a directory whose name looks like an option is usable after --" {
  run_snippet "$SCRIPT" "parse_options -- --odd; printf '%s' \"\$_target\""
  [ "$output" = "--odd" ]
}

@test "more than one path argument is refused" {
  run_script "$SCRIPT" "$LIB" "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected at most one path argument, got 2."* ]]
}

# This is how a library looks once the tool has run over it: the original keeps its name and its codec,
# with the converted file beside it. That is done, not failed, and not work to offer again.
@test "an original whose conversion already exists is reported as done" {
  film movie.mkv
  printf 'existing' > "$LIB/movie.AC3.CC.mkv"
  probe_audio movie.mkv eac3:6
  run_script "$SCRIPT" --dry-run "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already converted as movie.AC3.CC.mkv"* ]]
  [[ "$output" != *"would write"* ]]
  [[ "$output" == *"1 of those already have a converted file beside them."* ]]
  [[ "$output" == *"Would convert 0 file(s)."* ]]
}

@test "an original whose conversion already exists is not encoded again" {
  film movie.mkv
  printf 'existing' > "$LIB/movie.AC3.CC.mkv"
  probe_audio movie.mkv eac3:6
  run_script "$SCRIPT" --yes "$LIB"
  [ "$status" -eq 0 ]
  run stub_calls ffmpeg
  [ "$output" = "0" ]
  run cat "$LIB/movie.AC3.CC.mkv"
  [ "$output" = "existing" ]
}

# --- The output container -----------------------------------------------------------------------

# ffmpeg picks its muxer from the output file's suffix, and the file being written ends in .partial so
# that an interrupted encode cannot leave a finished name on a half-written file. Without the format
# named, ffmpeg refuses that suffix with "Unable to choose an output format" and every real file fails
# -- which a stubbed ffmpeg cannot reproduce, so the flag is asserted directly.
@test "the output container is named rather than left to the temporary file's suffix" {
  film movie.mkv
  probe_audio movie.mkv eac3:6
  probe_audio movie.AC3.CC.mkv.partial ac3:6
  run_script "$SCRIPT" --yes "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg .*-f matroska'
}

#!/usr/bin/env bats
#
# modernize-video re-encodes irreplaceable footage and stamps it with a capture date, so the assertions
# that matter are about the date and about never destroying an original.
#
# The date carries the most weight. ffmpeg turns a naive date into UTC using the converting machine's
# own offset, so the wall clock has to survive the round trip untouched, a date that cannot be true has
# to be refused rather than written, and a file with no date at all has to be reported rather than
# stamped with today.
#
# ffmpeg and ffprobe are stubbed. ffprobe answers per file, because a run inspects two — the source and
# the result it verifies — and the verification exists precisely because those two can disagree.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/photography/modernize-video/modernize-video.sh"

  LIB="$BATS_TEST_TMPDIR/camera"
  mkdir -p "$LIB"

  CONFIG_FILE="$BATS_TEST_TMPDIR/modernize-video.conf"
  export CONFIG_FILE
  : > "$CONFIG_FILE"
}

########################################
# Creates a fake video file with recognisable contents.
# Arguments:
#   name: File name relative to LIB.
########################################
clip() {
  printf 'original bytes' > "$LIB/$1"
}

########################################
# Makes ffprobe answer for one file.
#
# Shaped as the real document is, empty "programs" and "stream_groups" wrappers included, and with the
# date and brand under format.tags where ffprobe puts them. A fixture shaped to suit the filter rather
# than to match ffprobe can pass while the real interface answers nothing.
# Arguments:
#   name: Basename the answer applies to.
#   brand: major_brand, or "-" to omit the tag entirely as a non-ISO container does.
#   duration, date ("-" to omit), vcodec ("-" for no video stream), acodec ("-" for none), channels.
########################################
probe_as() {
  local name="$1" brand="$2" duration="$3" date="$4" vcodec="$5" acodec="$6" channels="$7"
  local streams='' tags=''

  if [[ "$vcodec" != "-" ]]; then
    streams+="{\"codec_type\":\"video\",\"codec_name\":\"${vcodec}\",\"width\":640,\"height\":480}"
  fi
  if [[ "$acodec" != "-" ]]; then
    [[ -n "$streams" ]] && streams+=','
    streams+="{\"codec_type\":\"audio\",\"codec_name\":\"${acodec}\",\"channels\":${channels}}"
  fi
  [[ "$date" != "-" ]] && tags+="\"creation_time\":\"${date}\""
  if [[ "$brand" != "-" ]]; then
    [[ -n "$tags" ]] && tags+=','
    tags+="\"major_brand\":\"${brand}\""
  fi

  printf '{"programs":[],"stream_groups":[],"streams":[%s],"format":{"duration":"%s","tags":{%s}}}\n' \
    "$streams" "$duration" "$tags" > "$STUB_FIXTURES/ffprobe.${name}.stdout"
}

########################################
# Makes ffprobe answer for the file ffmpeg is about to write, which is what verify_output reads.
# Arguments:
#   name: Basename of the finished file; the temporary carries a .partial suffix.
#   Remaining arguments are as probe_as, after the brand.
########################################
probe_result() {
  local name="$1"
  shift
  probe_as "${name}.partial" isom "$@"
}

# The source date every test uses unless it is testing the date itself, with the wall clock it must keep.
SOURCE_DATE='2006-10-15 03:01:25'
WANTED_DATE='2006-10-15T03:01:25'

########################################
# Files a source and a matching good result, so a conversion succeeds unless a test says otherwise.
# Arguments:
#   name: Source basename.
########################################
stage_convertible() {
  local name="$1"
  clip "$name"
  probe_as "$name" - 18.7 "$SOURCE_DATE" mjpeg pcm_s16le 2
  probe_result "${name%.*}.mp4" 18.7 "${WANTED_DATE}.000000Z" h264 aac 2
}

# --- Reading a file's facts ----------------------------------------------------------------------

@test "a file's facts are read as container, duration, date, codecs and channels" {
  clip movie.avi
  probe_as movie.avi - 18.7 "$SOURCE_DATE" mjpeg pcm_s16le 2
  run_func "$SCRIPT" probe_file "$LIB/movie.avi"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'other\t18.7\t2006-10-15 03:01:25\tmjpeg\tpcm_s16le\t2')" ]
}

# Tab is IFS whitespace, so bash collapses a run of tabs into one delimiter. A file with no recorded
# date would then hand its video codec to the field the date was read from and shift everything after
# it — which is most of a camera archive, since MPEG-1 and editing-cache files carry no date at all.
@test "a file with no date keeps every later field in its own column" {
  clip undated.mpg
  probe_as undated.mpg - 35.9 - mpeg1video mp2 1
  run_func "$SCRIPT" probe_file "$LIB/undated.mpg"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'other\t35.9\tnone\tmpeg1video\tmp2\t1')" ]
}

@test "a file with neither date nor audio still reports its video codec in the right column" {
  clip silent.avi
  probe_as silent.avi - 5.48 - indeo5 - 0
  run_func "$SCRIPT" probe_file "$LIB/silent.avi"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'other\t5.48\tnone\tindeo5\tnone\t0')" ]
}

# The field list is part of the contract: naming any field in -show_entries makes ffprobe emit only
# those, so a program selecting on a field nobody asked for sees no streams at all.
@test "ffprobe is asked for every field the program reads" {
  stage_convertible movie.avi
  run_func "$SCRIPT" probe_file "$LIB/movie.avi"
  [ "$status" -eq 0 ]
  stub_called 'ffprobe .*-show_entries stream=codec_type,codec_name,channels'
  stub_called 'ffprobe .*-show_entries format_tags=creation_time,major_brand'
}

# ffprobe has no -nostdin and takes the following argument as its value, so passing it fails on every
# file. ffmpeg does need it, or it eats the keypress meant for the next file's prompt.
@test "-nostdin goes to ffmpeg and never to ffprobe" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg .*-nostdin'
  run bash -c "grep '^ffprobe ' '$STUB_CALLS' | grep -c -- '-nostdin' || true"
  [ "$output" = "0" ]
}

# --- Choosing the date --------------------------------------------------------------------------

@test "a plausible embedded date is used, and reported as embedded" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dated ${WANTED_DATE} [embedded]"* ]]
}

# The source presents a wall clock with no zone. Writing it back through -map_metadata alone makes
# ffmpeg read it as host-local and store UTC, moving every date by the converting machine's own offset
# — a different answer in winter than in summer, and a different day for a clip shot near midnight.
@test "the wall clock is written back unchanged, with an explicit Z" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  stub_called "ffmpeg .*-metadata creation_time=${WANTED_DATE}Z"
}

@test "a date already carrying a Z keeps its wall clock rather than being converted" {
  clip phone.3gp
  probe_as phone.3gp 3gp4 47.6 '2004-12-30T20:21:59.000000Z' h263 amr_nb 1
  probe_result phone.mp4 47.6 '2004-12-30T20:21:59.000000Z' h264 aac 1
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg .*-metadata creation_time=2004-12-30T20:21:59Z'
}

# An MP4 header that was never filled in reads back as the epoch. Stamping a clip 1970 sorts it to the
# very start of a photo timeline, which is the failure this script exists to prevent.
@test "an epoch date is refused in favour of the modification time" {
  clip empty.mov
  probe_as empty.mov qt 35.0 '1970-01-01T00:00:00.000000Z' mjpeg pcm_s16le 1
  touch -t 200905021745.30 "$LIB/empty.mov"
  probe_result empty.mp4 35.0 '2009-05-02T17:45:30.000000Z' h264 aac 1
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dated 2009-05-02T17:45:30 [mtime]"* ]]
  stub_called 'ffmpeg .*-metadata creation_time=2009-05-02T17:45:30Z'
}

# Real cameras write real rubbish: this is the shape one of them left in an AVI's IDIT chunk.
@test "a malformed date is refused rather than passed to ffmpeg" {
  clip broken.avi
  probe_as broken.avi - 15.5 '2006-01-03 0<:2<:2<' mpeg4 pcm_mulaw 1
  touch -t 200601031244.44 "$LIB/broken.avi"
  probe_result broken.mp4 15.5 '2006-01-03T12:44:44.000000Z' h264 aac 1
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[mtime]"* ]]
  stub_called 'ffmpeg .*-metadata creation_time=2006-01-03T12:44:44Z'
}

@test "a date before the plausible range is refused" {
  run_func "$SCRIPT" plausible_date "1979-05-05T10:00:00"
  [ "$status" -ne 0 ]
}

@test "a date in the far future is refused" {
  run_func "$SCRIPT" plausible_date "2999-05-05T10:00:00"
  [ "$status" -ne 0 ]
}

@test "--date overrides what the file claims, and is reported as given" {
  clip movie.avi
  probe_as movie.avi - 18.7 "$SOURCE_DATE" mjpeg pcm_s16le 2
  probe_result movie.mp4 18.7 '2005-08-15T12:00:00.000000Z' h264 aac 2
  run_script "$SCRIPT" --yes --no-color --date 2005-08-15 "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dated 2005-08-15T12:00:00 [given]"* ]]
}

@test "a bare date is read as midday rather than midnight" {
  run_func "$SCRIPT" normalize_date "2005-08-15"
  [ "$status" -eq 0 ]
  [ "$output" = "2005-08-15T12:00:00" ]
}

# Where a sync client has rewritten every modification time, an mtime is not a worse date than the
# embedded one but a wrong one, and being told the file is undated is more useful than being given
# yesterday.
@test "--no-mtime reports an undated file instead of converting it" {
  clip undated.mpg
  probe_as undated.mpg - 35.9 - mpeg1video mp2 1
  run_script "$SCRIPT" --yes --no-color --no-mtime "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no usable capture date"* ]]
  [[ "$output" == *"1 had no usable capture date"* ]]
  run bash -c "grep -c '^ffmpeg ' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

# --- Deciding what each file needs --------------------------------------------------------------

@test "modern streams in an MP4 are reported and left alone" {
  clip done.mp4
  probe_as done.mp4 isom 10.0 '2017-10-24T01:45:22.000000Z' h264 aac 2
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already h264, aac in MP4; left alone"* ]]
  [[ "$output" == *"1 already in a modern form"* ]]
  run bash -c "grep -c '^ffmpeg ' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

# The brand is what the file says about itself. A 3GPP file carrying an .mp4 extension is common enough
# that trusting the extension would leave it unplayable while reporting it as finished.
@test "modern streams in a 3GPP container are rewrapped by a stream copy, not re-encoded" {
  clip phone.mp4
  probe_as phone.mp4 3gp4 142.7 '2014-07-06T00:36:14.000000Z' h264 aac 2
  probe_as phone.converted.mp4.partial isom 142.7 '2014-07-06T00:36:14.000000Z' h264 aac 2
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rewrap"* ]]
  [[ "$output" == *"rewrapped 1 losslessly"* ]]
  stub_called 'ffmpeg .*-c copy'
  run bash -c "grep '^ffmpeg ' '$STUB_CALLS' | grep -c -- '-c:v libx264' || true"
  [ "$output" = "0" ]
}

@test "old streams are re-encoded to H.264 and AAC" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg .*-c:v libx264'
  stub_called 'ffmpeg .*-c:a aac'
}

@test "a file with no audio is encoded with -an and no audio codec" {
  clip silent.avi
  probe_as silent.avi - 5.48 - indeo5 - 0
  touch -t 200508152212.00 "$LIB/silent.avi"
  probe_result silent.mp4 5.48 '2005-08-15T22:12:00.000000Z' h264 - 0
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"indeo5, no audio"* ]]
  stub_called 'ffmpeg .*-an'
  run bash -c "grep '^ffmpeg ' '$STUB_CALLS' | grep -c -- '-c:a' || true"
  [ "$output" = "0" ]
}

@test "audio already in AAC is copied while the video is re-encoded" {
  clip mixed.avi
  probe_as mixed.avi - 10.0 "$SOURCE_DATE" mjpeg aac 2
  probe_result mixed.mp4 10.0 "${WANTED_DATE}.000000Z" h264 aac 2
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg .*-c:v libx264'
  stub_called 'ffmpeg .*-c:a copy'
}

@test "a file with no video stream is reported rather than converted" {
  clip audio-only.avi
  probe_as audio-only.avi - 10.0 "$SOURCE_DATE" - pcm_s16le 2
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no video stream"* ]]
  run bash -c "grep -c '^ffmpeg ' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "a file ffprobe cannot read is reported, not passed over in silence" {
  clip notvideo.avi
  printf '1' > "$STUB_FIXTURES/ffprobe.fail"
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a video file"* ]]
  [[ "$output" == *"1 could not be read as video"* ]]
}

# --- The ffmpeg command -------------------------------------------------------------------------

# The temporary file ends in .partial so an interrupted run cannot leave a finished name on a
# half-written file, and ffmpeg cannot choose a muxer from that extension.
@test "the output format is named rather than left to the extension" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg .*-f mp4'
}

# A stream can misreport its frame rate — MPEG-1 from these cameras reports double its real rate — so
# forcing that figure would stretch the whole recording.
@test "the frame rate is never forced" {
  clip movie.mpg
  probe_as movie.mpg - 35.9 "$SOURCE_DATE" mpeg1video mp2 1
  probe_result movie.mp4 35.9 "${WANTED_DATE}.000000Z" h264 aac 1
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ffmpeg ' '$STUB_CALLS' | grep -cE ' -r [0-9]' || true"
  [ "$output" = "0" ]
}

@test "levels are converted to the limited range by default" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg .*out_range=limited'
  stub_called 'ffmpeg .*-color_range tv'
}

# The filter states only the output range, so swscale takes the input range from the source. Pinning the
# input to full would wrongly stretch the levels of a source that is already limited.
@test "the input range is left for the source to declare" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ffmpeg ' '$STUB_CALLS' | grep -c 'in_range' || true"
  [ "$output" = "0" ]
}

@test "COLOR_RANGE=full keeps the source levels untouched" {
  printf 'COLOR_RANGE="full"\n' > "$CONFIG_FILE"
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ffmpeg ' '$STUB_CALLS' | grep -cE 'out_range|-color_range' || true"
  [ "$output" = "0" ]
}

@test "an even-dimension guard is applied, since x264 refuses odd sizes" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  stub_called 'ffmpeg .*trunc(iw/2)\*2'
}

@test "a mono track gets half the stereo bitrate" {
  run_func "$SCRIPT" audio_bitrate_for 1
  [ "$status" -eq 0 ]
  [ "$output" = "96k" ]
}

@test "a stereo track gets the configured bitrate" {
  run_func "$SCRIPT" audio_bitrate_for 2
  [ "$status" -eq 0 ]
  [ "$output" = "192k" ]
}

# --- Refusing a result that is not what was asked for -------------------------------------------

# ffmpeg exiting zero is not proof: asked for an encoder it does not have it copies the stream through
# instead, and a folder of files named as converted but still holding what nothing plays is worse than
# a failure.
@test "a result still holding the old codec is refused and the original kept" {
  clip movie.avi
  probe_as movie.avi - 18.7 "$SOURCE_DATE" mjpeg pcm_s16le 2
  probe_result movie.mp4 18.7 "${WANTED_DATE}.000000Z" mjpeg aac 2
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds mjpeg video where h264 was asked for"* ]]
  [ -f "$LIB/movie.avi" ]
  [ ! -e "$LIB/movie.mp4" ]
}

@test "a result of the wrong length is refused" {
  clip movie.avi
  probe_as movie.avi - 100.0 "$SOURCE_DATE" mjpeg pcm_s16le 2
  probe_result movie.mp4 50.0 "${WANTED_DATE}.000000Z" h264 aac 2
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"against the source"* ]]
  [ ! -e "$LIB/movie.mp4" ]
}

# The date is the whole point of the conversion, so it is proved rather than assumed.
@test "a result carrying the wrong date is refused" {
  clip movie.avi
  probe_as movie.avi - 18.7 "$SOURCE_DATE" mjpeg pcm_s16le 2
  probe_result movie.mp4 18.7 '1999-01-01T00:00:00.000000Z' h264 aac 2
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"where '${WANTED_DATE}' was asked for"* ]]
  [ ! -e "$LIB/movie.mp4" ]
}

@test "a failing ffmpeg leaves the original alone and no partial file behind" {
  stage_convertible movie.avi
  printf '1' > "$STUB_FIXTURES/ffmpeg.fail"
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 1 ]
  [ -f "$LIB/movie.avi" ]
  [ ! -e "$LIB/movie.mp4" ]
  [ ! -e "$LIB/movie.mp4.partial" ]
}

# --- Naming and replacing -----------------------------------------------------------------------

@test "an existing output file is left alone rather than written through" {
  stage_convertible movie.avi
  printf 'precious' > "$LIB/movie.mp4"
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [ "$(cat "$LIB/movie.mp4")" = "precious" ]
}

# The plain name would be the source itself, and on a case-insensitive filesystem X.MP4 and X.mp4 are
# one file, so writing the output would truncate the source while ffmpeg was still reading it.
@test "a source already named .mp4 is given a distinct output name" {
  run_func "$SCRIPT" output_name "/tmp/holiday.MP4"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/holiday.converted.mp4" ]
}

@test "an ordinary source takes the plain .mp4 name" {
  run_func "$SCRIPT" output_name "/tmp/holiday.AVI"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/holiday.mp4" ]
}

@test "--replace removes the original only once the result has been verified" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color --replace "$LIB"
  [ "$status" -eq 0 ]
  [ ! -e "$LIB/movie.avi" ]
  [ -f "$LIB/movie.mp4" ]
}

@test "--replace keeps the original when the result is refused" {
  clip movie.avi
  probe_as movie.avi - 18.7 "$SOURCE_DATE" mjpeg pcm_s16le 2
  probe_result movie.mp4 18.7 "${WANTED_DATE}.000000Z" mjpeg aac 2
  run_script "$SCRIPT" --yes --no-color --replace "$LIB"
  [ "$status" -eq 1 ]
  [ -f "$LIB/movie.avi" ]
}

# A library file is often a hard link to something still wanted elsewhere. --replace unlinks one name,
# which leaves every other name holding the original bytes; the converted file is a new path, so nothing
# is ever written through a shared inode.
@test "--replace unlinks one name and leaves another link holding the original bytes" {
  stage_convertible movie.avi
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  ln "$LIB/movie.avi" "$BATS_TEST_TMPDIR/elsewhere/same.avi"
  run_script "$SCRIPT" --yes --no-color --replace "$LIB"
  [ "$status" -eq 0 ]
  [ ! -e "$LIB/movie.avi" ]
  [ "$(cat "$BATS_TEST_TMPDIR/elsewhere/same.avi")" = "original bytes" ]
}

# The refusal, not the rename, is what protects a file that is already there — including one that is a
# hard link to something else.
@test "an existing hard-linked output is refused rather than written through" {
  stage_convertible movie.avi
  printf 'seeded bytes' > "$LIB/movie.mp4"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  ln "$LIB/movie.mp4" "$BATS_TEST_TMPDIR/elsewhere/seeded.mp4"
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/elsewhere/seeded.mp4")" = "seeded bytes" ]
  [ "$(cat "$LIB/movie.mp4")" = "seeded bytes" ]
}

@test "a successful run leaves no partial file behind" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  run bash -c "ls '$LIB' | grep -c partial || true"
  [ "$output" = "0" ]
}

@test "the converted file's modification time is set to its capture date" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  run_snippet "$SCRIPT" "stat_mtime_iso '$LIB/movie.mp4'"
  [ "$output" = "$WANTED_DATE" ]
}

# --- Reporting and the command line -------------------------------------------------------------

@test "--dry-run reports what would happen and runs no ffmpeg" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --dry-run --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would write movie.mp4"* ]]
  [[ "$output" == *"Would convert 1"* ]]
  run bash -c "grep -c '^ffmpeg ' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
  [ ! -e "$LIB/movie.mp4" ]
}

# Every file has to land in one of the counts: a run that quietly passed over half a folder looks
# exactly like one that had nothing to do.
@test "every file examined is accounted for in the summary" {
  stage_convertible one.avi
  clip done.mp4
  probe_as done.mp4 isom 10.0 '2017-10-24T01:45:22.000000Z' h264 aac 2
  clip novideo.avi
  probe_as novideo.avi - 10.0 "$SOURCE_DATE" - pcm_s16le 2
  run_script "$SCRIPT" --yes --no-color "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 file(s) examined"* ]]
  [[ "$output" == *"Converted 1"* ]]
  [[ "$output" == *"1 already in a modern form"* ]]
  [[ "$output" == *"1 could not be read as video"* ]]
}

@test "an unknown option is refused with the usage" {
  run_script "$SCRIPT" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "an option missing its value is refused" {
  run_script "$SCRIPT" --crf
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an argument"* ]]
}

@test "a second path argument is refused" {
  run_script "$SCRIPT" one two
  [ "$status" -eq 1 ]
  [[ "$output" == *"at most one path"* ]]
}

@test "an out-of-range CRF is refused" {
  run_script "$SCRIPT" --crf 99 "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRF must be a number"* ]]
}

@test "an implausible --date is refused before anything is converted" {
  stage_convertible movie.avi
  run_script "$SCRIPT" --yes --date 1823-01-01 "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"The date must be"* ]]
  [ ! -e "$LIB/movie.mp4" ]
}

@test "an unusable COLOR_RANGE is refused" {
  printf 'COLOR_RANGE="sideways"\n' > "$CONFIG_FILE"
  run_script "$SCRIPT" --yes "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COLOR_RANGE must be"* ]]
}

# An empty setting means "use the default", as every other setting here does. A value that is present
# but holds only whitespace is the one that would reach find as an empty \( \) group, which is a syntax
# error rather than a walk matching nothing.
@test "an extension list of only whitespace is refused rather than reaching find" {
  printf 'EXTENSIONS="   "\n' > "$CONFIG_FILE"
  run_script "$SCRIPT" --yes "$LIB"
  [ "$status" -eq 1 ]
  [[ "$output" == *"at least one extension"* ]]
}

@test "a missing path is refused" {
  run_script "$SCRIPT" "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "--help prints the usage and exits cleanly" {
  run_script "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--no-mtime"* ]]
}

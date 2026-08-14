#!/usr/bin/env bats
#
# subtitle-sync rewrites subtitle files in place, so the failures that matter are the ones that lose
# data: overwriting a backup that holds the only pristine copy, syncing from an already-synced file, or
# replacing a subtitle when the alignment step actually failed. The suite drives those paths first.
#
# The pipeline's four external tools are stubbed. Three of them hand a file back to the script, which
# then parses it, so the stub fabricates one (see test/stubs/_stub); ffprobe's stream list is supplied
# as canned stdout. Timing arithmetic and the SRT rewriting are exercised as functions, since driving
# them through the CLI would only assert on a log line.
#
# Every test supplies its own CONFIG_FILE. Beyond hermeticity that is a safety requirement: CACHE_DIR
# defaults under $XDG_CACHE_HOME, and a test that let it default would write into the developer's real
# cache and then read from it on the next run.

load test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/utility/subtitle-sync.sh"
  TREE="$BATS_TEST_TMPDIR/media"
  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$TREE" "$CACHE"
  CONF="$BATS_TEST_TMPDIR/sync.conf"
  printf 'CACHE_DIR="%s"\n' "$CACHE" > "$CONF"
}

########################################
# Creates a file under the tree, with SRT-shaped content when it looks like a subtitle.
# Arguments:
#   path: Path relative to TREE.
#   first_cue_at: Optional "HH:MM:SS,mmm" start for the first cue.
########################################
touch_file() {
  local rel="$1" start="${2:-00:00:10,000}"
  mkdir -p "$(dirname "$TREE/$rel")"
  case "$rel" in
    *.srt|*.ass|*.ssa|*.vtt)
      printf '1\n%s --> 00:00:12,000\nhello\n\n2\n00:00:20,000 --> 00:00:22,000\nworld\n' \
        "$start" > "$TREE/$rel"
      ;;
    *) printf 'video-bytes' > "$TREE/$rel" ;;
  esac
}

########################################
# Makes the ffprobe stub report subtitle streams as "index,codec,language" rows.
# Arguments:
#   Rows to emit; none means a video with no subtitle streams.
########################################
embedded_streams() {
  if (( $# == 0 )); then
    stub_outputs ffprobe < /dev/null
  else
    printf '%s\n' "$@" | stub_outputs ffprobe
  fi
}

########################################
# Makes the alass stub return a fixed corrected subtitle rather than echoing its input.
# Arguments:
#   first_cue_at: "HH:MM:SS,mmm" start for the corrected file's first cue.
########################################
alass_returns() {
  printf '1\n%s --> 00:00:13,000\nhello\n' "$1" > "$STUB_FIXTURES/alass.artifact"
}

########################################
# Runs the script with the fixture config.
########################################
sync_run() {
  CONFIG_FILE="$CONF" run_script "$SCRIPT" -C "$@"
}

########################################
# Evaluates a snippet inside the script, with a scratch working directory in place.
########################################
with_workdir() {
  run_snippet "$SCRIPT" "_workdir='$BATS_TEST_TMPDIR'; $1"
}

# --- Option parsing ----------------------------------------------------------------------------

@test "--help lists the drift types the script handles" {
  sync_run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Segmented / ad-break drift"* ]]
  [[ "$output" == *"--fps-guess"* ]]
}

@test "an unknown option is refused" {
  sync_run --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "an option that takes a value is refused without one" {
  sync_run --lang
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an argument"* ]]
}

@test "more than one PATH is refused" {
  sync_run "$TREE" "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"at most one PATH"* ]]
}

# --remux without --embedded would silently do nothing, since there is no extracted track to mux.
@test "--remux without --embedded is refused" {
  sync_run --remux "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--remux only applies with --embedded"* ]]
}

@test "--split-penalty rejects a non-integer" {
  sync_run --split-penalty 2.5 "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "--max-words rejects zero" {
  sync_run --max-words 0 "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "--threads rejects a non-integer" {
  sync_run --threads two "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--threads must be a positive integer"* ]]
}

@test "--anchor-max accepts a decimal and rejects a word" {
  touch_file movie.mkv
  sync_run --anchor-max 0.75 --dry-run "$TREE"
  [ "$status" -eq 0 ]
  sync_run --anchor-max soon "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative number"* ]]
}

@test "a path that is neither a file nor a directory is refused" {
  sync_run "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a file or directory"* ]]
}

@test "a file that is neither media nor subtitle is refused" {
  touch_file notes.txt
  sync_run "$TREE/notes.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported file type"* ]]
}

# --- Dependency check --------------------------------------------------------------------------

# The tool names are configurable, so pointing one at something absent is how the check is reached
# without disturbing the PATH the rest of the harness depends on.
@test "a missing external tool is reported with install hints" {
  touch_file movie.mkv
  printf 'CACHE_DIR="%s"\nALASS_BIN="alass-not-installed"\n' "$CACHE" > "$CONF"
  sync_run "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required tool(s): alass-not-installed"* ]]
  [[ "$output" == *"github.com/kaegi/alass"* ]]
}

@test "WHISPER_BIN from the config is the command that gets run" {
  touch_file movie.mkv
  touch_file movie.en.srt
  ln -s "$REPO_ROOT/test/stubs/_stub" "$BATS_TEST_TMPDIR/my-whisper"
  printf 'CACHE_DIR="%s"\nWHISPER_BIN="%s"\n' "$CACHE" "$BATS_TEST_TMPDIR/my-whisper" > "$CONF"
  sync_run "$TREE"
  [ "$status" -eq 0 ]
  [ "$(stub_calls my-whisper)" -eq 1 ]
  [ "$(stub_calls whisper-ctranslate2)" -eq 0 ]
}

@test "WHISPER_EXTRA_ARGS from the config reach the transcription command" {
  touch_file movie.mkv
  touch_file movie.en.srt
  printf 'CACHE_DIR="%s"\nWHISPER_EXTRA_ARGS=(--vad_filter True)\n' "$CACHE" > "$CONF"
  sync_run "$TREE"
  stub_called 'whisper-ctranslate2 .*--vad_filter True'
}

@test "the transcription command carries the model, language and granularity" {
  touch_file movie.mkv
  touch_file movie.de.srt
  sync_run --model small --lang de --max-words 4 --threads 2 "$TREE"
  stub_called 'whisper-ctranslate2 .*--model small'
  stub_called 'whisper-ctranslate2 .*--language de'
  stub_called 'whisper-ctranslate2 .*--max_words_per_line 4'
  stub_called 'whisper-ctranslate2 .*--threads 2'
}

# Whisper wants 16 kHz mono PCM; handing it the container's own audio would work by luck at best.
@test "audio is extracted as 16 kHz mono PCM with no video stream" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run "$TREE"
  stub_called 'ffmpeg .*-vn -ar 16000 -ac 1 -c:a pcm_s16le'
}

# --- Sidecar syncing ---------------------------------------------------------------------------

@test "a matching sidecar is synced and the original backed up" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run "$TREE"
  [ "$status" -eq 0 ]
  [ -f "$TREE/movie.en.srt.bak" ]
  [[ "$output" == *"Synced: $TREE/movie.en.srt"* ]]
}

@test "the backup holds the original timings and the subtitle holds the corrected ones" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  alass_returns 00:00:30,000
  sync_run --no-anchor "$TREE"
  grep -q "00:00:10,000" "$TREE/movie.en.srt.bak"
  grep -q "00:00:30,000" "$TREE/movie.en.srt"
}

@test "alass is given the reference and the subtitle, with the split penalty" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --split-penalty 3 "$TREE"
  stub_called 'alass .*--split-penalty 3'
  stub_called 'alass .*reference\.srt'
}

# FPS guessing is off by default, so a subtitle with a real segmented drift is not "corrected" by
# rescaling the whole file to a framerate it never had.
@test "alass framerate guessing is disabled unless --fps-guess is given" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run "$TREE"
  stub_called 'alass .*-g'
  : > "$STUB_CALLS"
  sync_run --force --fps-guess "$TREE"
  run stub_calls 'alass .*-g '
  [ "$output" = "0" ]
}

@test "a sidecar in another language is left alone" {
  touch_file movie.mkv
  touch_file movie.de.srt
  sync_run "$TREE"
  [ ! -f "$TREE/movie.de.srt.bak" ]
  [ "$(stub_calls alass)" -eq 0 ]
}

@test "--lang selects which sidecar is synced" {
  touch_file movie.mkv
  touch_file movie.de.srt
  sync_run --lang de "$TREE"
  [ -f "$TREE/movie.de.srt.bak" ]
}

# A single-language release is often untagged, so an unmarked sidecar is assumed to be the target.
@test "an untagged sidecar is treated as the target language" {
  touch_file movie.mkv
  touch_file movie.srt
  sync_run "$TREE"
  [ -f "$TREE/movie.srt.bak" ]
}

@test "a role token after the language does not hide the sidecar" {
  touch_file movie.mkv
  touch_file movie.en.forced.srt
  sync_run "$TREE"
  [ -f "$TREE/movie.en.forced.srt.bak" ]
}

@test "a sidecar belonging to another video is not synced" {
  touch_file alpha.mkv
  touch_file beta.en.srt
  sync_run "$TREE"
  [ ! -f "$TREE/beta.en.srt.bak" ]
}

@test "several sidecars for one video are all synced from one reference" {
  touch_file movie.mkv
  touch_file movie.en.srt
  touch_file movie.eng.srt
  sync_run "$TREE"
  [ -f "$TREE/movie.en.srt.bak" ]
  [ -f "$TREE/movie.eng.srt.bak" ]
  [ "$(stub_calls whisper-ctranslate2)" -eq 1 ]
  [ "$(stub_calls alass)" -eq 2 ]
}

@test "subtitle formats other than srt are synced too" {
  touch_file movie.mkv
  touch_file movie.en.ass
  sync_run "$TREE"
  [ -f "$TREE/movie.en.ass.bak" ]
}

# alass picks its parser from the file extension, so the copy handed to it must not be named ".bak".
@test "the file handed to alass keeps the subtitle's own extension" {
  touch_file movie.mkv
  touch_file movie.en.ass
  sync_run "$TREE"
  stub_called 'alass .*source\.ass'
}

# --- Idempotency and --force -------------------------------------------------------------------

@test "a subtitle with a backup beside it is skipped" {
  touch_file movie.mkv
  touch_file movie.en.srt
  : > "$TREE/movie.en.srt.bak"
  sync_run "$TREE"
  [[ "$output" == *"Skip (already synced)"* ]]
  [ "$(stub_calls alass)" -eq 0 ]
}

@test "--force re-syncs a subtitle that already has a backup" {
  touch_file movie.mkv
  touch_file movie.en.srt
  cp "$TREE/movie.en.srt" "$TREE/movie.en.srt.bak"
  sync_run --force "$TREE"
  [ "$(stub_calls alass)" -eq 1 ]
  [[ "$output" == *"Synced:"* ]]
}

# The backup is the only pristine copy, so a forced re-run must align it rather than the file it
# already replaced -- and must not overwrite it with that file.
@test "--force aligns the backup, and leaves it untouched" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  printf '1\n00:00:01,000 --> 00:00:02,000\npristine\n' > "$TREE/movie.en.srt.bak"
  sync_run --force --no-anchor "$TREE"
  grep -q "pristine" "$TREE/movie.en.srt.bak"
  grep -q "pristine" "$TREE/movie.en.srt"
}

@test "--backup-suffix changes where the original is kept" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --backup-suffix .orig "$TREE"
  [ -f "$TREE/movie.en.srt.orig" ]
  [ ! -f "$TREE/movie.en.srt.bak" ]
}

# --- Failure handling --------------------------------------------------------------------------

# The summary assertion is what separates "the failure was handled" from "the run died before it could
# do any damage": both leave the subtitle intact, but only the first accounts for the file.
@test "a failed alignment leaves the subtitle untouched and exits non-zero" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  stub_fails alass
  sync_run "$TREE"
  [ "$status" -ne 0 ]
  grep -q "00:00:10,000" "$TREE/movie.en.srt"
  [ ! -f "$TREE/movie.en.srt.bak" ]
  [[ "$output" == *"alass failed"* ]]
  [[ "$output" == *"Done: 0 synced, 0 skipped, 1 failed"* ]]
}

@test "a failed transcription is reported and counted as a failure" {
  touch_file movie.mkv
  touch_file movie.en.srt
  stub_fails whisper-ctranslate2
  sync_run "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Transcription failed"* ]]
  [ "$(stub_calls alass)" -eq 0 ]
}

@test "a failed audio extraction stops before transcription" {
  touch_file movie.mkv
  touch_file movie.en.srt
  stub_fails ffmpeg
  sync_run "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to extract audio"* ]]
  [ "$(stub_calls whisper-ctranslate2)" -eq 0 ]
}

# A transcription that exits 0 but produces nothing would otherwise be aligned against an empty
# reference, which alass would happily accept.
@test "a transcription that produces no subtitles is a failure" {
  touch_file movie.mkv
  touch_file movie.en.srt
  printf '' > "$STUB_FIXTURES/whisper-ctranslate2.artifact"
  sync_run "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no subtitles"* ]]
}

@test "the exit status is zero when nothing failed" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run "$TREE"
  [ "$status" -eq 0 ]
}

# --- Dry run -----------------------------------------------------------------------------------

@test "--dry-run changes nothing and never transcribes" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  sync_run --dry-run "$TREE"
  [ "$status" -eq 0 ]
  [ ! -f "$TREE/movie.en.srt.bak" ]
  grep -q "00:00:10,000" "$TREE/movie.en.srt"
  [ "$(stub_calls whisper-ctranslate2)" -eq 0 ]
  [ "$(stub_calls alass)" -eq 0 ]
  [[ "$output" == *"[dry-run] Would sync"* ]]
}

@test "--dry-run reports the planned embedded work without probing for output" {
  touch_file movie.mkv
  embedded_streams "2,subrip,eng"
  sync_run --dry-run --embedded "$TREE"
  [[ "$output" == *"[dry-run] Would sync embedded track 2"* ]]
  [ "$(stub_calls whisper-ctranslate2)" -eq 0 ]
}

@test "the dry-run summary counts what would be processed" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --dry-run "$TREE"
  [[ "$output" == *"Dry run complete: 1 subtitle(s) would be processed."* ]]
}

# --- The reference cache -----------------------------------------------------------------------

@test "the reference is cached and reused for the next run" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run "$TREE"
  [ "$(find "$CACHE" -name '*.srt' | wc -l | tr -d ' ')" -eq 1 ]
  : > "$STUB_CALLS"
  sync_run --force "$TREE"
  [ "$(stub_calls whisper-ctranslate2)" -eq 0 ]
  [[ "$output" == *"reference cached"* ]]
}

@test "--no-cache does not write the cache" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --no-cache "$TREE"
  [ "$(find "$CACHE" -name '*.srt' | wc -l | tr -d ' ')" -eq 0 ]
}

# Seeding the cache first is the only way to observe the read: a --no-cache run leaves nothing behind,
# so a second --no-cache run would find an empty cache and transcribe whatever the flag did.
@test "--no-cache ignores a cache entry that is already there" {
  touch_file movie.mkv
  touch_file movie.en.srt
  run_snippet "$SCRIPT" "cache_key '$TREE/movie.mkv'"
  local key="$output"
  [ -n "$key" ]
  printf '1\n00:00:01,000 --> 00:00:02,000\nstale\n' > "$CACHE/${key}.srt"
  sync_run --no-cache "$TREE"
  [ "$status" -eq 0 ]
  [ "$(stub_calls whisper-ctranslate2)" -eq 1 ]
  [[ "$output" != *"reference cached"* ]]
}

@test "a cache entry that is there is used instead of transcribing" {
  touch_file movie.mkv
  touch_file movie.en.srt
  run_snippet "$SCRIPT" "cache_key '$TREE/movie.mkv'"
  local key="$output"
  printf '1\n00:00:01,000 --> 00:00:02,000\ncached\n' > "$CACHE/${key}.srt"
  sync_run "$TREE"
  [ "$(stub_calls whisper-ctranslate2)" -eq 0 ]
  [[ "$output" == *"reference cached"* ]]
}

# The key covers the transcription parameters, so changing one must not reuse a reference built with
# the old ones.
@test "the cache key changes with the model, language and granularity" {
  touch_file movie.mkv
  local base other
  run_snippet "$SCRIPT" "cache_key '$TREE/movie.mkv'"
  base="$output"
  [ -n "$base" ]
  for other in "_model=tiny" "_lang=de" "_max_words=2"; do
    run_snippet "$SCRIPT" "$other; cache_key '$TREE/movie.mkv'"
    [ -n "$output" ]
    [ "$output" != "$base" ]
  done
}

@test "the cache key changes when the video does" {
  touch_file movie.mkv
  run_snippet "$SCRIPT" "cache_key '$TREE/movie.mkv'"
  local before="$output"
  printf 'different-bytes-entirely' > "$TREE/movie.mkv"
  run_snippet "$SCRIPT" "cache_key '$TREE/movie.mkv'"
  [ "$output" != "$before" ]
}

@test "the cache key is stable for an unchanged video" {
  touch_file movie.mkv
  run_snippet "$SCRIPT" "cache_key '$TREE/movie.mkv'"
  local first="$output"
  run_snippet "$SCRIPT" "cache_key '$TREE/movie.mkv'"
  [ "$output" = "$first" ]
}

# --- Embedded tracks ---------------------------------------------------------------------------

@test "an embedded track in the target language is extracted and written as a sidecar" {
  touch_file movie.mkv
  embedded_streams "2,subrip,eng"
  sync_run --embedded "$TREE"
  [ -f "$TREE/movie.en.srt" ]
  stub_called 'ffmpeg .*-map 0:2'
  [[ "$output" == *"Synced (embedded -> sidecar)"* ]]
}

@test "the first matching track wins" {
  touch_file movie.mkv
  embedded_streams "1,subrip,ger" "3,subrip,eng" "4,subrip,eng"
  sync_run --embedded "$TREE"
  stub_called 'ffmpeg .*-map 0:3'
}

# Bitmap tracks carry no resyncable text timing, so a picture-based stream must not be chosen.
@test "a bitmap subtitle track is skipped in favour of a text one" {
  touch_file movie.mkv
  embedded_streams "1,hdmv_pgs_subtitle,eng" "2,subrip,eng"
  sync_run --embedded "$TREE"
  stub_called 'ffmpeg .*-map 0:2'
}

@test "a video with no matching embedded track is left alone" {
  touch_file movie.mkv
  embedded_streams "1,subrip,ger"
  sync_run --embedded --lang en "$TREE"
  [ ! -f "$TREE/movie.en.srt" ]
  [ "$(stub_calls alass)" -eq 0 ]
}

# The sidecar is what makes this bite: without one the video is passed over before the embedded step is
# ever reached, so the test would hold no matter what that step did.
@test "embedded tracks are ignored without --embedded" {
  touch_file movie.mkv
  touch_file movie.eng.srt
  embedded_streams "2,subrip,eng"
  sync_run "$TREE"
  [ "$status" -eq 0 ]
  [ ! -f "$TREE/movie.en.srt" ]
  [ "$(stub_calls ffprobe)" -eq 0 ]
}

@test "an existing sidecar stops the embedded track from overwriting it" {
  touch_file movie.mkv
  touch_file movie.en.srt
  : > "$TREE/movie.en.srt.bak"
  embedded_streams "2,subrip,eng"
  sync_run --embedded "$TREE"
  [[ "$output" == *"Skip embedded (sidecar exists)"* ]]
}

@test "--remux writes a new container instead of a sidecar" {
  touch_file movie.mkv
  embedded_streams "2,subrip,eng"
  sync_run --embedded --remux "$TREE"
  [ -f "$TREE/movie.subsync.mkv" ]
  [ ! -f "$TREE/movie.en.srt" ]
  [[ "$output" == *"Synced (remux)"* ]]
}

# The corrected track is appended, so the stream index used for tagging has to count the streams that
# were already there or the metadata lands on the wrong one.
@test "the remuxed track is tagged and defaulted by its position after the originals" {
  touch_file movie.mkv
  embedded_streams "1,subrip,eng" "2,subrip,ger"
  sync_run --embedded --remux "$TREE"
  stub_called 'ffmpeg .*-metadata:s:s:2 language=en'
  stub_called 'ffmpeg .*-disposition:s:s:2 default'
}

@test "an existing remux target is not overwritten without --force" {
  touch_file movie.mkv
  touch_file movie.subsync.mkv
  embedded_streams "2,subrip,eng"
  sync_run --embedded --remux "$TREE"
  [[ "$output" == *"Skip embedded (remux target exists)"* ]]
}

@test "a failed extraction of the embedded track is reported" {
  touch_file movie.mkv
  embedded_streams "2,subrip,eng"
  printf '1' > "$STUB_FIXTURES/ffmpeg.fail"
  sync_run --embedded "$TREE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to extract"*"audio"* ]] || [[ "$output" == *"Failed to extract embedded"* ]]
}

# --- A lone subtitle ---------------------------------------------------------------------------

@test "a lone subtitle is matched to its sibling video" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run "$TREE/movie.en.srt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Video: $TREE/movie.mkv"* ]]
  [ -f "$TREE/movie.en.srt.bak" ]
}

@test "--video names the video explicitly" {
  touch_file "other name.mkv"
  touch_file subs.en.srt
  sync_run --video "$TREE/other name.mkv" "$TREE/subs.en.srt"
  [ "$status" -eq 0 ]
  [ -f "$TREE/subs.en.srt.bak" ]
}

@test "a lone subtitle with no video to sync against is refused" {
  touch_file orphan.en.srt
  sync_run "$TREE/orphan.en.srt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not find a video"* ]]
  [[ "$output" == *"--video"* ]]
}

@test "a lone subtitle that is already synced is skipped" {
  touch_file movie.mkv
  touch_file movie.en.srt
  : > "$TREE/movie.en.srt.bak"
  sync_run "$TREE/movie.en.srt"
  [[ "$output" == *"Skip (already synced)"* ]]
  [ "$(stub_calls whisper-ctranslate2)" -eq 0 ]
}

@test "a lone subtitle in dry-run changes nothing" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --dry-run "$TREE/movie.en.srt"
  [ ! -f "$TREE/movie.en.srt.bak" ]
  [[ "$output" == *"[dry-run] Would sync"* ]]
}

# --- Traversal ---------------------------------------------------------------------------------

@test "a directory is walked recursively" {
  touch_file "season 1/ep1.mkv"
  touch_file "season 1/ep1.en.srt"
  touch_file "season 2/ep2.mkv"
  touch_file "season 2/ep2.en.srt"
  sync_run "$TREE"
  [ -f "$TREE/season 1/ep1.en.srt.bak" ]
  [ -f "$TREE/season 2/ep2.en.srt.bak" ]
}

@test "a single video file can be given directly" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run "$TREE/movie.mkv"
  [ -f "$TREE/movie.en.srt.bak" ]
}

@test "a video with no matching subtitles is passed over" {
  touch_file movie.mkv
  sync_run "$TREE"
  [ "$status" -eq 0 ]
  [ "$(stub_calls whisper-ctranslate2)" -eq 0 ]
}

@test "a filename with spaces survives the pipeline" {
  touch_file "The Show S01E01 (2024).mkv"
  touch_file "The Show S01E01 (2024).en.srt"
  sync_run "$TREE"
  [ -f "$TREE/The Show S01E01 (2024).en.srt.bak" ]
  stub_called 'The Show S01E01 (2024)\.mkv'
}

@test "a backup file is not itself treated as a subtitle to sync" {
  touch_file movie.mkv
  touch_file movie.en.srt
  cp "$TREE/movie.en.srt" "$TREE/movie.en.srt.bak"
  sync_run --force "$TREE"
  [ ! -f "$TREE/movie.en.srt.bak.bak" ]
  [ "$(stub_calls alass)" -eq 1 ]
}

@test "the media extension list can be replaced from a config file" {
  touch_file movie.xyz
  touch_file movie.en.srt
  printf 'CACHE_DIR="%s"\nMEDIA_EXTS=(xyz)\n' "$CACHE" > "$CONF"
  sync_run "$TREE"
  [ -f "$TREE/movie.en.srt.bak" ]
}

@test "an unreadable CONFIG_FILE is refused rather than ignored" {
  touch_file movie.mkv
  CONFIG_FILE="$BATS_TEST_TMPDIR/nope.conf" run_script "$SCRIPT" -C "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_FILE is set to"* ]]
}

# --- The anchor ------------------------------------------------------------------------------

# Whisper marks a cue at the word's onset, a fraction of a second after a human subtitler would, so
# alass inherits a small constant lead. The anchor cancels it by returning the opening cue to where it
# was.
@test "a small opening shift is treated as bias and cancelled" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  alass_returns 00:00:09,500
  sync_run "$TREE"
  grep -q "00:00:10,000" "$TREE/movie.en.srt"
}

# A large opening shift is the correction the user asked for, not bias, so cancelling it would undo
# the whole point of the run.
@test "a large opening shift is kept as a real offset" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  alass_returns 00:00:04,000
  sync_run "$TREE"
  grep -q "00:00:04,000" "$TREE/movie.en.srt"
}

@test "--anchor-max moves the line between bias and offset" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  alass_returns 00:00:07,000
  sync_run --anchor-max 5 "$TREE"
  grep -q "00:00:10,000" "$TREE/movie.en.srt"
}

@test "--no-anchor leaves the alignment exactly as alass produced it" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  alass_returns 00:00:09,500
  sync_run --no-anchor "$TREE"
  grep -q "00:00:09,500" "$TREE/movie.en.srt"
}

# WebVTT uses the same " --> " separator as SRT but a dot before the milliseconds, so the SRT shifter
# would happily parse and then rewrite its timestamps into a format VTT does not use. The guard is what
# keeps a non-SRT file out of it, and a fixture with real cues is what proves the guard fires.
@test "anchor_correct passes a non-SRT format through untouched" {
  printf 'WEBVTT\n\n00:00:10.500 --> 00:00:12.000\nhello\n' > "$BATS_TEST_TMPDIR/c.vtt"
  printf 'WEBVTT\n\n00:00:10.000 --> 00:00:11.500\nhello\n' > "$BATS_TEST_TMPDIR/o.vtt"
  with_workdir "anchor_correct '$BATS_TEST_TMPDIR/c.vtt' '$BATS_TEST_TMPDIR/o.vtt' '$BATS_TEST_TMPDIR/out.vtt'"
  run diff "$BATS_TEST_TMPDIR/c.vtt" "$BATS_TEST_TMPDIR/out.vtt"
  [ "$status" -eq 0 ]
}

@test "anchor_correct passes through when the corrected file has no cue" {
  printf 'no cues here\n' > "$BATS_TEST_TMPDIR/c.srt"
  printf '1\n00:00:01,000 --> 00:00:02,000\nx\n' > "$BATS_TEST_TMPDIR/o.srt"
  with_workdir "anchor_correct '$BATS_TEST_TMPDIR/c.srt' '$BATS_TEST_TMPDIR/o.srt' '$BATS_TEST_TMPDIR/out.srt'"
  [ "$(cat "$BATS_TEST_TMPDIR/out.srt")" = "no cues here" ]
}

# Without the guard an unreadable opening time is taken as zero, which turns into a shift by the whole
# of the corrected file's own opening -- so the cue moves rather than being left alone. The corrected
# opening is kept under --anchor-max, or the shift would stand down and hide the difference.
@test "anchor_correct passes through when the original has no cue" {
  printf '1\n00:00:00,500 --> 00:00:02,000\nx\n' > "$BATS_TEST_TMPDIR/c.srt"
  printf 'no cues here\n' > "$BATS_TEST_TMPDIR/o.srt"
  with_workdir "anchor_correct '$BATS_TEST_TMPDIR/c.srt' '$BATS_TEST_TMPDIR/o.srt' '$BATS_TEST_TMPDIR/out.srt'"
  run cat "$BATS_TEST_TMPDIR/out.srt"
  [[ "$output" == *"00:00:00,500 --> 00:00:02,000"* ]]
}

# --- SRT arithmetic --------------------------------------------------------------------------

@test "first_cue_ms reads the opening timestamp in milliseconds" {
  printf '1\n01:02:03,456 --> 01:02:04,000\nx\n' > "$BATS_TEST_TMPDIR/a.srt"
  run_snippet "$SCRIPT" "first_cue_ms '$BATS_TEST_TMPDIR/a.srt'"
  [ "$output" = "3723456" ]
}

@test "first_cue_ms reads the first cue only" {
  printf '1\n00:00:05,000 --> 00:00:06,000\nx\n\n2\n00:00:09,000 --> 00:00:10,000\ny\n' \
    > "$BATS_TEST_TMPDIR/a.srt"
  run_snippet "$SCRIPT" "first_cue_ms '$BATS_TEST_TMPDIR/a.srt'"
  [ "$output" = "5000" ]
}

@test "first_cue_ms is empty for a file with no cues" {
  printf 'nothing\n' > "$BATS_TEST_TMPDIR/a.srt"
  run_snippet "$SCRIPT" "first_cue_ms '$BATS_TEST_TMPDIR/a.srt'; echo '[end]'"
  [ "$output" = "[end]" ]
}

@test "shift_srt moves both ends of every cue" {
  printf '1\n00:00:10,000 --> 00:00:12,000\nx\n\n2\n00:00:20,500 --> 00:00:21,000\ny\n' \
    > "$BATS_TEST_TMPDIR/in.srt"
  run_snippet "$SCRIPT" "shift_srt '$BATS_TEST_TMPDIR/in.srt' '$BATS_TEST_TMPDIR/out.srt' 1500"
  run cat "$BATS_TEST_TMPDIR/out.srt"
  [[ "$output" == *"00:00:11,500 --> 00:00:13,500"* ]]
  [[ "$output" == *"00:00:22,000 --> 00:00:22,500"* ]]
}

@test "shift_srt keeps the cue text and numbering" {
  printf '1\n00:00:10,000 --> 00:00:12,000\nhello there\n' > "$BATS_TEST_TMPDIR/in.srt"
  run_snippet "$SCRIPT" "shift_srt '$BATS_TEST_TMPDIR/in.srt' '$BATS_TEST_TMPDIR/out.srt' 1000"
  run cat "$BATS_TEST_TMPDIR/out.srt"
  [[ "$output" == *"hello there"* ]]
  [ "${lines[0]}" = "1" ]
}

# A negative shift larger than the opening timestamp would otherwise produce a negative time, which no
# player accepts.
@test "shift_srt clamps a negative result to zero" {
  printf '1\n00:00:01,000 --> 00:00:02,000\nx\n' > "$BATS_TEST_TMPDIR/in.srt"
  run_snippet "$SCRIPT" "shift_srt '$BATS_TEST_TMPDIR/in.srt' '$BATS_TEST_TMPDIR/out.srt' -5000"
  run cat "$BATS_TEST_TMPDIR/out.srt"
  [[ "$output" == *"00:00:00,000 --> 00:00:00,000"* ]]
}

@test "shift_srt carries across the minute and hour boundaries" {
  printf '1\n00:59:59,500 --> 01:00:00,000\nx\n' > "$BATS_TEST_TMPDIR/in.srt"
  run_snippet "$SCRIPT" "shift_srt '$BATS_TEST_TMPDIR/in.srt' '$BATS_TEST_TMPDIR/out.srt' 1000"
  run cat "$BATS_TEST_TMPDIR/out.srt"
  [[ "$output" == *"01:00:00,500 --> 01:00:01,000"* ]]
}

# --- Language and extension helpers ------------------------------------------------------------

@test "normalize_lang folds codes and names onto one token" {
  run_snippet "$SCRIPT" "for l in en eng English ger de fr FRE; do printf '%s ' \"\$(normalize_lang \"\$l\")\"; done"
  [ "$output" = "en en en de de fr fr " ]
}

@test "normalize_lang answers und for empty input and lowercases the unknown" {
  run_snippet "$SCRIPT" "printf '%s %s' \"\$(normalize_lang '')\" \"\$(normalize_lang 'Klingon')\""
  [ "$output" = "und klingon" ]
}

@test "lang_from_tokens takes the first token that is not a role flag" {
  run_snippet "$SCRIPT" "printf '%s %s %s %s' \"\$(lang_from_tokens 'en')\" \"\$(lang_from_tokens 'en.forced')\" \"\$(lang_from_tokens 'forced.en')\" \"\$(lang_from_tokens 'forced')\""
  [ "$output" = "en en en und" ]
}

@test "lang_matches_target accepts the target and the undetermined" {
  run_snippet "$SCRIPT" "_lang=en; for l in en und de; do lang_matches_target \"\$l\" && printf 'y' || printf 'n'; done"
  [ "$output" = "yyn" ]
}

# The bare name "mkv" is the case the dot check exists for: stripping an extension that is not there
# leaves the whole filename, which would otherwise match the list.
@test "has_ext is case-insensitive and needs a dot" {
  run_snippet "$SCRIPT" \
    "for p in a.MKV a.mkv a.txt noext mkv; do has_ext \"\$p\" _media_exts && printf 'y' || printf 'n'; done"
  [ "$output" = "yynnn" ]
}

# --- Summary and timing ------------------------------------------------------------------------

@test "_fmt_dur scales from seconds to hours" {
  run_snippet "$SCRIPT" "printf '%s|%s|%s' \"\$(_fmt_dur 42)\" \"\$(_fmt_dur 320)\" \"\$(_fmt_dur 3792)\""
  [ "$output" = "42s|5m 20s|1h 03m 12s" ]
}

@test "the summary reports the three counters" {
  touch_file a.mkv
  touch_file a.en.srt
  touch_file b.mkv
  touch_file b.en.srt
  : > "$TREE/b.en.srt.bak"
  sync_run "$TREE"
  [[ "$output" == *"Done: 1 synced, 1 skipped, 0 failed"* ]]
}

@test "print_summary fails when anything failed" {
  run_snippet "$SCRIPT" \
    "_batch_start=\$(_now); s=0; print_summary >/dev/null || s=\$?; echo \"clean=\${s}\"
     _n_failed=1; s=0; print_summary >/dev/null || s=\$?; echo \"failed=\${s}\""
  [ "${lines[0]}" = "clean=0" ]
  [ "${lines[1]}" = "failed=1" ]
}

@test "the per-episode timing line names the steps" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run "$TREE"
  [[ "$output" == *"movie.mkv took"* ]]
  [[ "$output" == *"extract "*"transcribe "*"align "* ]]
}

# A video whose only subtitle was skipped reaches the timing step but did nothing worth timing. Using a
# video with no subtitles at all would return earlier and never reach it.
@test "no timing line is printed for a video that did no work" {
  touch_file movie.mkv
  touch_file movie.en.srt
  : > "$TREE/movie.en.srt.bak"
  sync_run "$TREE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip (already synced)"* ]]
  [[ "$output" != *"took"* ]]
}

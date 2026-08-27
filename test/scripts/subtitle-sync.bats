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

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/media/subtitle-sync/subtitle-sync.sh"
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
#
# One cue where touch_file wrote two, so the cue counts disagree and the script cannot profile the
# shift -- which is the path a test wanting an unprofilable alignment asks for.
# Arguments:
#   first_cue_at: "HH:MM:SS,mmm" start for the corrected file's first cue.
########################################
alass_returns() {
  printf '1\n%s --> 00:00:13,000\nhello\n' "$1" > "$STUB_FIXTURES/alass.artifact"
}

########################################
# Makes the alass stub return touch_file's two cues moved by a given offset, so the script sees a
# profilable shift of a known size.
# Arguments:
#   ms:      Signed milliseconds to move the cues by.
#   variant: Optional alignment mode to answer only ('nosplit' or 'split').
########################################
alass_shifts_by() {
  local ms="$1" variant="${2:-}" name="alass.artifact"
  [[ -n "$variant" ]] && name="alass.$variant.artifact"
  awk -v off="$ms" 'function f(t,  h,m,s,ms2){t+=off; if(t<0)t=0; ms2=t%1000; t=int(t/1000); s=t%60; t=int(t/60); m=t%60; h=int(t/60); return sprintf("%02d:%02d:%02d,%03d",h,m,s,ms2)} BEGIN{printf "1\n%s --> %s\nhello\n\n2\n%s --> %s\nworld\n", f(10000), f(12000), f(20000), f(22000)}' > "$STUB_FIXTURES/$name"
}

########################################
# Makes the alass stub answer one alignment mode with cues read from stdin, so a test can give the two
# modes results of measurably different quality.
# Arguments:
#   variant: 'nosplit' or 'split'.
########################################
alass_variant_artifact() {
  cat > "$STUB_FIXTURES/alass.$1.artifact"
}

########################################
# Makes the transcriber stub return a given reference transcript, which is what the alignment is scored
# against.
# Arguments:
#   Cue text on stdin.
########################################
reference_is() {
  cat > "$STUB_FIXTURES/whisper-ctranslate2.artifact"
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

@test "--min-shift accepts a decimal and rejects a word" {
  touch_file movie.mkv
  sync_run --min-shift 0.75 --dry-run "$TREE"
  [ "$status" -eq 0 ]
  sync_run --min-shift soon "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--min-shift must be a non-negative number"* ]]
}

@test "--ad-breaks accepts its three modes and rejects anything else" {
  touch_file movie.mkv
  local mode
  for mode in auto yes no; do
    sync_run --ad-breaks "$mode" --dry-run "$TREE"
    [ "$status" -eq 0 ]
  done
  sync_run --ad-breaks sometimes "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--ad-breaks must be auto, yes or no"* ]]
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
  alass_shifts_by 4000
  sync_run "$TREE"
  [ "$status" -eq 0 ]
  [ -f "$TREE/movie.en.srt.bak" ]
  [[ "$output" == *"Synced (single offset +4.0s): $TREE/movie.en.srt"* ]]
}

# Torrents carry subtitle files too, so a synced sidecar can be a hard link to one still being seeded.
# The corrected file therefore has to land on a new inode: writing through the shared one would alter
# what the tracker checksums. See the "Replacing a file someone else is seeding" section of CLAUDE.md.
@test "the copy a torrent is seeding is left byte-for-byte alone" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  ln "$TREE/movie.en.srt" "$BATS_TEST_TMPDIR/seeding.en.srt"
  alass_returns 00:00:30,000
  sync_run "$TREE"
  [ "$status" -eq 0 ]
  grep -q "00:00:10,000" "$BATS_TEST_TMPDIR/seeding.en.srt"
  run grep -c "00:00:30,000" "$BATS_TEST_TMPDIR/seeding.en.srt"
  [ "$output" = "0" ]
  [ ! "$TREE/movie.en.srt" -ef "$BATS_TEST_TMPDIR/seeding.en.srt" ]
}

@test "the backup holds the original timings and the subtitle holds the corrected ones" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  alass_returns 00:00:30,000
  sync_run "$TREE"
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
  sync_run --lang de --min-shift 0 "$TREE"
  [ -f "$TREE/movie.de.srt.bak" ]
}

# A single-language release is often untagged, so an unmarked sidecar is assumed to be the target.
@test "an untagged sidecar is treated as the target language" {
  touch_file movie.mkv
  touch_file movie.srt
  sync_run --min-shift 0 "$TREE"
  [ -f "$TREE/movie.srt.bak" ]
}

@test "a role token after the language does not hide the sidecar" {
  touch_file movie.mkv
  touch_file movie.en.forced.srt
  sync_run --min-shift 0 "$TREE"
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
  sync_run --min-shift 0 "$TREE"
  [ -f "$TREE/movie.en.srt.bak" ]
  [ -f "$TREE/movie.eng.srt.bak" ]
  [ "$(stub_calls whisper-ctranslate2)" -eq 1 ]
  [ "$(stub_calls alass)" -eq 4 ]
}

@test "subtitle formats other than srt are synced too" {
  touch_file movie.mkv
  touch_file movie.en.ass
  sync_run --min-shift 0 "$TREE"
  [ -f "$TREE/movie.en.ass.bak" ]
}

# alass picks its parser from the file extension, so the copy handed to it must not be named ".bak".
@test "the file handed to alass keeps the subtitle's own extension" {
  touch_file movie.mkv
  touch_file movie.en.ass
  sync_run "$TREE"
  stub_called 'alass .*source\.ass'
}

# --- Choosing between one offset and segments ---------------------------------------------------

# Segmented alignment can invent a break in a subtitle whose only fault is a constant offset, leaving an
# opening stretch further out than it started. Both alignments are therefore produced and scored, and
# the segmented one is kept only when it matches the speech measurably better.

@test "the split penalty defaults to alass's own default" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --min-shift 0 "$TREE"
  stub_called 'alass .*--split-penalty 7'
}

@test "auto aligns each subtitle both ways, one of them without splitting" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --min-shift 0 "$TREE"
  [ "$(stub_calls alass)" -eq 2 ]
  stub_called 'alass --no-split'
  stub_called 'alass --split-penalty'
}

@test "the segmented alignment is kept when it matches the speech better" {
  touch_file movie.mkv
  touch_file movie.en.srt
  reference_is <<< "1
00:00:00,000 --> 00:01:40,000
speech"
  alass_variant_artifact nosplit <<< "1
00:00:00,000 --> 00:00:50,000
kept-nosplit"
  alass_variant_artifact split <<< "1
00:00:00,000 --> 00:00:51,000
kept-split"
  sync_run "$TREE"
  grep -q "kept-split" "$TREE/movie.en.srt"
}

@test "the segmented alignment is discarded when it matches no better" {
  touch_file movie.mkv
  touch_file movie.en.srt
  reference_is <<< "1
00:00:00,000 --> 00:01:40,000
speech"
  alass_variant_artifact nosplit <<< "1
00:00:00,000 --> 00:00:50,000
kept-nosplit"
  alass_variant_artifact split <<< "1
00:00:00,000 --> 00:00:40,000
kept-split"
  sync_run "$TREE"
  grep -q "kept-nosplit" "$TREE/movie.en.srt"
}

# The margin is the whole point of the gate: a segmented alignment that matches a fraction better is
# noise, and believing it is what splits a file that only ever needed one shift. 50.2s of the reference
# against 50.0s is a gain of four parts per thousand, under the threshold; 51.0s is twenty, over it.
@test "a segmented alignment winning by less than half a percent is discarded" {
  touch_file movie.mkv
  touch_file movie.en.srt
  reference_is <<< "1
00:00:00,000 --> 00:01:40,000
speech"
  alass_variant_artifact nosplit <<< "1
00:00:00,000 --> 00:00:50,000
kept-nosplit"
  alass_variant_artifact split <<< "1
00:00:00,000 --> 00:00:50,200
kept-split"
  sync_run "$TREE"
  grep -q "kept-nosplit" "$TREE/movie.en.srt"
}

@test "--ad-breaks no aligns once, without splitting" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --ad-breaks no --min-shift 0 "$TREE"
  [ "$(stub_calls alass)" -eq 1 ]
  stub_called 'alass --no-split'
}

@test "--ad-breaks yes aligns once, with the split penalty" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --ad-breaks yes --min-shift 0 "$TREE"
  [ "$(stub_calls alass)" -eq 1 ]
  stub_called 'alass --split-penalty 7'
}

# A forced mode must not be overruled by the score, or it is not an override.
@test "--ad-breaks yes keeps the segmented alignment even when it matches worse" {
  touch_file movie.mkv
  touch_file movie.en.srt
  reference_is <<< "1
00:00:00,000 --> 00:01:40,000
speech"
  alass_variant_artifact split <<< "1
00:00:00,000 --> 00:00:10,000
kept-split"
  sync_run --ad-breaks yes "$TREE"
  grep -q "kept-split" "$TREE/movie.en.srt"
}

# With framerate guessing the two alignments can be rescaled by different factors, so they cover
# different amounts of time and the score rewards the more stretched one for no good reason.
@test "--fps-guess drops back to a single global offset" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --fps-guess --min-shift 0 "$TREE"
  [ "$(stub_calls alass)" -eq 1 ]
  stub_called 'alass --no-split'
}

@test "--fps-guess still honours an explicit --ad-breaks" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --fps-guess --ad-breaks auto --min-shift 0 "$TREE"
  [ "$(stub_calls alass)" -eq 2 ]
}

########################################
# Points the script at an aligner that fails for one of the two modes and copies its input through for
# the other, which is the only way to exercise one failed run out of the pair.
# Arguments:
#   failing: 'nosplit' or 'split'.
########################################
alass_fails_only() {
  local failing="$1" fake="$BATS_TEST_TMPDIR/fake-alass"
  cat > "$fake" <<FAKE
#!/usr/bin/env bash
mode=split
for arg in "\$@"; do [[ "\$arg" == "--no-split" ]] && mode=nosplit; done
[[ "\$mode" == "$failing" ]] && exit 1
cp "\${@: -2:1}" "\${@: -1:1}"
FAKE
  chmod +x "$fake"
  printf 'CACHE_DIR="%s"\nALASS_BIN="%s"\n' "$CACHE" "$fake" > "$CONF"
}

# A segmented run that fails leaves a perfectly good single-offset alignment in hand, so the subtitle is
# still corrected -- but silently preferring it would hide that half the comparison never happened.
@test "a failed segmented alignment keeps the single-offset one and says so" {
  touch_file movie.mkv
  touch_file movie.en.srt
  alass_fails_only split
  sync_run --min-shift 0 "$TREE"
  [ "$status" -eq 0 ]
  [ -f "$TREE/movie.en.srt.bak" ]
  [[ "$output" == *"Segmented alignment failed"* ]]
  [[ "$output" == *"Synced"* ]]
}

# With no single-offset alignment to fall back to there is nothing to write, so this one has to count as
# a failure rather than quietly leaving the file as it was.
@test "a failed single-offset alignment is a failure" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  alass_fails_only nosplit
  sync_run "$TREE"
  [ "$status" -ne 0 ]
  grep -q "00:00:10,000" "$TREE/movie.en.srt"
  [ ! -f "$TREE/movie.en.srt.bak" ]
  [[ "$output" == *"Done: 0 synced, 0 already in sync, 0 skipped, 1 failed"* ]]
}

# A forced mode has only one run, so its failure is the whole alignment failing.
@test "--ad-breaks yes fails when the segmented run fails" {
  touch_file movie.mkv
  touch_file movie.en.srt
  alass_fails_only split
  sync_run --ad-breaks yes "$TREE"
  [ "$status" -ne 0 ]
  [ ! -f "$TREE/movie.en.srt.bak" ]
}

# --- The min-shift deadband ---------------------------------------------------------------------

# alass moves an already-correct subtitle by a few tenths of a second towards Whisper's cue starts,
# which run slightly late. A correction that small cannot be told apart from that lead, so the file is
# left exactly as it was rather than traded from one small error to another.

@test "a subtitle already matching the speech is left byte-identical and unbacked-up" {
  touch_file movie.mkv
  touch_file movie.en.srt
  cp "$TREE/movie.en.srt" "$BATS_TEST_TMPDIR/before.srt"
  alass_shifts_by 100
  sync_run "$TREE"
  [ "$status" -eq 0 ]
  cmp "$TREE/movie.en.srt" "$BATS_TEST_TMPDIR/before.srt"
  [ ! -f "$TREE/movie.en.srt.bak" ]
  [[ "$output" == *"Already in sync (within 0.5s): $TREE/movie.en.srt"* ]]
}

@test "a shift under --min-shift is left alone and one over it is applied" {
  touch_file movie.mkv
  touch_file movie.en.srt
  alass_shifts_by 400
  sync_run "$TREE"
  [ ! -f "$TREE/movie.en.srt.bak" ]
  alass_shifts_by 600
  sync_run "$TREE"
  [ -f "$TREE/movie.en.srt.bak" ]
  grep -q "00:00:10,600" "$TREE/movie.en.srt"
}

# The threshold is converted to milliseconds, where truncating instead of rounding loses one: 2.01
# seconds scales to 2009.999... in binary arithmetic, so a truncating conversion holds it as 2009ms and
# rewrites a file it was asked to leave alone. Verified to differ on both BSD awk and GNU awk.
@test "--min-shift is read to the millisecond" {
  touch_file movie.mkv
  touch_file movie.en.srt
  alass_shifts_by 2009
  sync_run --min-shift 2.01 "$TREE"
  [ ! -f "$TREE/movie.en.srt.bak" ]
  [[ "$output" == *"Already in sync (within 2.01s)"* ]]
}

@test "--min-shift 0 rewrites for any shift at all" {
  touch_file movie.mkv
  touch_file movie.en.srt
  alass_shifts_by 100
  sync_run --min-shift 0 "$TREE"
  [ -f "$TREE/movie.en.srt.bak" ]
  grep -q "00:00:10,100" "$TREE/movie.en.srt"
}

# An aligner shifts a subtitle rather than rewriting its cue list, so disagreeing cue counts mean the
# shift cannot be measured. That must fall towards writing the file: reporting it as already in sync
# would discard a correction of unknown size.
@test "an alignment whose cue count does not match is written, not reported in sync" {
  touch_file movie.mkv
  touch_file movie.en.srt
  alass_returns 00:00:30,000
  sync_run "$TREE"
  [ -f "$TREE/movie.en.srt.bak" ]
  grep -q "00:00:30,000" "$TREE/movie.en.srt"
  [[ "$output" == *"Synced (shift unknown)"* ]]
}

# The deadband guards a rewrite, never a creation: an embedded track has no sidecar yet, and declining
# to write one would leave the operator with no subtitle and every later run repeating the extraction.
@test "an embedded track that is already in sync still produces its sidecar" {
  touch_file movie.mkv
  embedded_streams "2,subrip,eng"
  # The extracted track is the stub's default two cues; this moves them by a tenth of a second, which
  # for a sidecar would be small enough to leave the file alone.
  printf '1\n00:00:01,100 --> 00:00:03,100\nfirst line\n\n2\n00:00:05,100 --> 00:00:07,100\nsecond line\n' > "$STUB_FIXTURES/alass.artifact"
  sync_run --embedded "$TREE"
  [ -f "$TREE/movie.en.srt" ]
  [[ "$output" == *"Synced (embedded -> sidecar"* ]]
  grep -q "00:00:01,100" "$TREE/movie.en.srt"
}

# A subtitle found to be in sync cost the same transcription as one that was rewritten, so its episode
# belongs in the timing line and in the per-episode average.
@test "an episode whose subtitle was already in sync still reports its timing" {
  touch_file movie.mkv
  touch_file movie.en.srt
  alass_shifts_by 100
  sync_run "$TREE"
  [[ "$output" == *"movie.mkv took"* ]]
  [[ "$output" == *"/episode over 1"* ]]
}

# --- What the success line says ------------------------------------------------------------------

# The line is how a wrong verdict becomes visible: segments on a file that needed one shift, or a single
# offset on a broadcast rip, is the sign to re-run with --ad-breaks.

@test "a constant correction is reported as a single offset" {
  touch_file movie.mkv
  touch_file movie.en.srt
  alass_shifts_by 4000
  sync_run "$TREE"
  [[ "$output" == *"Synced (single offset +4.0s)"* ]]
}

@test "a segmented correction names the segments and their range" {
  touch_file movie.mkv
  touch_file movie.en.srt
  alass_variant_artifact nosplit <<< "1
00:00:11,000 --> 00:00:13,000
hello

2
00:00:25,000 --> 00:00:27,000
world"
  sync_run --ad-breaks no "$TREE"
  [[ "$output" == *"Synced (2 segments, +1.0s to +5.0s)"* ]]
}

# Framerate correction rescales every cue by a different amount, which is a different thing from a
# handful of breaks and is judged against the cue count rather than a fixed number of segments.
@test "a rescaled correction is reported as a variable shift" {
  touch_file movie.mkv
  awk 'BEGIN{for(i=1;i<=12;i++) printf "%d\n00:00:%02d,000 --> 00:00:%02d,200\nline\n\n", i, i, i}' > "$TREE/movie.en.srt"
  awk 'function f(t,  h,m,s,ms){ms=t%1000; t=int(t/1000); s=t%60; t=int(t/60); m=t%60; h=int(t/60); return sprintf("%02d:%02d:%02d,%03d",h,m,s,ms)} BEGIN{for(i=1;i<=12;i++){o=i*1000+i*100; printf "%d\n%s --> %s\nline\n\n", i, f(o), f(o+200)}}' > "$STUB_FIXTURES/alass.artifact"
  sync_run --ad-breaks no "$TREE"
  [[ "$output" == *"Synced (variable shift, +0.1s to +1.2s)"* ]]
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
  alass_shifts_by 4000
  sync_run --force "$TREE"
  [ "$(stub_calls alass)" -eq 2 ]
  [[ "$output" == *"Synced (single offset +4.0s)"* ]]
}

# The backup is the only pristine copy, so a forced re-run must align it rather than the file it
# already replaced -- and must not overwrite it with that file.
@test "--force aligns the backup, and leaves it untouched" {
  touch_file movie.mkv
  touch_file movie.en.srt 00:00:10,000
  printf '1\n00:00:01,000 --> 00:00:02,000\npristine\n' > "$TREE/movie.en.srt.bak"
  sync_run --force --min-shift 0 "$TREE"
  grep -q "pristine" "$TREE/movie.en.srt.bak"
  grep -q "pristine" "$TREE/movie.en.srt"
}

@test "--backup-suffix changes where the original is kept" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --backup-suffix .orig --min-shift 0 "$TREE"
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
  [[ "$output" == *"Done: 0 synced, 0 already in sync, 0 skipped, 1 failed"* ]]
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
  # Whether a subtitle needs correcting cannot be known without the transcript, which is the step
  # dry-run skips, so the report says it would sync if needed rather than promising a rewrite.
  [[ "$output" == *"[dry-run] Would sync if needed"* ]]
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
  [[ "$output" == *"Synced (embedded -> sidecar,"* ]]
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
  [[ "$output" == *"Synced (remux,"* ]]
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
  sync_run --min-shift 0 "$TREE/movie.en.srt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Video: $TREE/movie.mkv"* ]]
  [ -f "$TREE/movie.en.srt.bak" ]
}

@test "--video names the video explicitly" {
  touch_file "other name.mkv"
  touch_file subs.en.srt
  sync_run --video "$TREE/other name.mkv" --min-shift 0 "$TREE/subs.en.srt"
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
  [[ "$output" == *"[dry-run] Would sync if needed"* ]]
}

# --- Traversal ---------------------------------------------------------------------------------

@test "a directory is walked recursively" {
  touch_file "season 1/ep1.mkv"
  touch_file "season 1/ep1.en.srt"
  touch_file "season 2/ep2.mkv"
  touch_file "season 2/ep2.en.srt"
  sync_run --min-shift 0 "$TREE"
  [ -f "$TREE/season 1/ep1.en.srt.bak" ]
  [ -f "$TREE/season 2/ep2.en.srt.bak" ]
}

@test "a single video file can be given directly" {
  touch_file movie.mkv
  touch_file movie.en.srt
  sync_run --min-shift 0 "$TREE/movie.mkv"
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
  sync_run --min-shift 0 "$TREE"
  [ -f "$TREE/The Show S01E01 (2024).en.srt.bak" ]
  stub_called 'The Show S01E01 (2024)\.mkv'
}

@test "a backup file is not itself treated as a subtitle to sync" {
  touch_file movie.mkv
  touch_file movie.en.srt
  cp "$TREE/movie.en.srt" "$TREE/movie.en.srt.bak"
  sync_run --force "$TREE"
  [ ! -f "$TREE/movie.en.srt.bak.bak" ]
  [ "$(stub_calls alass)" -eq 2 ]
}

@test "the media extension list can be replaced from a config file" {
  touch_file movie.xyz
  touch_file movie.en.srt
  printf 'CACHE_DIR="%s"\nMEDIA_EXTS=(xyz)\n' "$CACHE" > "$CONF"
  sync_run --min-shift 0 "$TREE"
  [ -f "$TREE/movie.en.srt.bak" ]
}

@test "an unreadable CONFIG_FILE is refused rather than ignored" {
  touch_file movie.mkv
  CONFIG_FILE="$BATS_TEST_TMPDIR/nope.conf" run_script "$SCRIPT" -C "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_FILE is set to"* ]]
}

# --- Alignment statistics ------------------------------------------------------------------------

# alignment-stats.awk is the whole basis of the choice above: the score decides whether a segmented
# alignment is believed, and the shift profile decides whether the file is rewritten at all.

########################################
# Writes the three files the statistics are computed from and reports the result.
# Arguments:
#   reference: Reference cues.
#   original:  Pre-sync cues.
#   candidate: Aligned cues.
########################################
stats_for() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/ref.srt"
  printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/orig.srt"
  printf '%s\n' "$3" > "$BATS_TEST_TMPDIR/cand.srt"
  run_snippet "$SCRIPT" "alignment_stats '$BATS_TEST_TMPDIR/ref.srt' '$BATS_TEST_TMPDIR/orig.srt' '$BATS_TEST_TMPDIR/cand.srt'"
}

@test "the score counts only the milliseconds the candidate and the reference share" {
  stats_for "1
00:00:00,000 --> 00:00:10,000
r" "1
00:00:00,000 --> 00:00:04,000
o" "1
00:00:06,000 --> 00:00:14,000
c"
  [ "${output%% *}" = "4000" ]
}

@test "the score is zero when the two never overlap" {
  stats_for "1
00:00:00,000 --> 00:00:05,000
r" "1
00:00:00,000 --> 00:00:05,000
o" "1
00:00:10,000 --> 00:00:15,000
c"
  [ "${output%% *}" = "0" ]
}

# Two cues covering the same moment must not let one millisecond be counted twice, or the score stops
# measuring coverage and starts rewarding whichever file repeats itself most. ASS subtitles overlap
# routinely and Whisper's word-timestamped cues can too.
@test "overlapping reference cues are counted once, not twice" {
  stats_for "1
00:00:00,000 --> 00:00:05,000
r

2
00:00:02,000 --> 00:00:07,000
r" "1
00:00:00,000 --> 00:00:07,000
o" "1
00:00:00,000 --> 00:00:07,000
c"
  [ "${output%% *}" = "7000" ]
}

@test "WebVTT timestamps are read with their dots and without their hours" {
  stats_for "1
00:00:00,000 --> 00:00:10,000
r" "1
00:00:00,000 --> 00:00:10,000
o" "WEBVTT

00:02.000 --> 00:06.000
c"
  [ "${output%% *}" = "4000" ]
}

# An ASS Format line declares which column holds Start and which holds End, and files do vary; reading
# them by position instead would score such a file as matching nothing.
@test "ASS dialogue times are read from the columns the Format line declares" {
  stats_for "1
00:00:00,000 --> 00:00:10,000
r" "1
00:00:00,000 --> 00:00:10,000
o" "[Events]
Format: Layer, End, Start, Style, Text
Dialogue: 0,0:00:06.00,0:00:02.00,D,c"
  [ "${output%% *}" = "4000" ]
}

# The three inputs are told apart by name rather than by which record came first, so a reference with no
# cues scores zero instead of the candidate being compared against itself.
@test "an empty reference scores zero rather than scoring the candidate against itself" {
  : > "$BATS_TEST_TMPDIR/ref.srt"
  printf '1\n00:00:00,000 --> 00:00:05,000\no\n' > "$BATS_TEST_TMPDIR/orig.srt"
  printf '1\n00:00:00,000 --> 00:00:05,000\nc\n' > "$BATS_TEST_TMPDIR/cand.srt"
  run_snippet "$SCRIPT" "alignment_stats '$BATS_TEST_TMPDIR/ref.srt' '$BATS_TEST_TMPDIR/orig.srt' '$BATS_TEST_TMPDIR/cand.srt'"
  [ "${output%% *}" = "0" ]
  [ "$(echo "$output" | cut -d' ' -f2)" = "1" ]
}

@test "a constant shift is one run, and its size is reported both signed and absolute" {
  stats_for "1
00:00:00,000 --> 00:00:10,000
r" "1
00:00:10,000 --> 00:00:12,000
o

2
00:00:20,000 --> 00:00:22,000
o" "1
00:00:07,000 --> 00:00:09,000
c

2
00:00:17,000 --> 00:00:19,000
c"
  [ "$output" = "2000 2 1 3000 -3000 -3000" ]
}

@test "two different shifts are two runs, with the range between them" {
  stats_for "1
00:00:00,000 --> 00:01:00,000
r" "1
00:00:10,000 --> 00:00:12,000
o

2
00:00:20,000 --> 00:00:22,000
o" "1
00:00:11,000 --> 00:00:13,000
c

2
00:00:25,000 --> 00:00:27,000
c"
  [ "$output" = "4000 2 2 5000 1000 5000" ]
}

# ASS and SSA timestamps carry only centiseconds, so a single global offset written back into one lands
# as shifts a few milliseconds apart. Counted raw, every ASS file would look segmented.
@test "centisecond rounding in an ASS file is still one run" {
  printf '1\n00:00:00,000 --> 00:01:00,000\nr\n' > "$BATS_TEST_TMPDIR/ref.srt"
  printf '1\n00:00:10,004 --> 00:00:12,000\no\n\n2\n00:00:20,006 --> 00:00:22,000\no\n' > "$BATS_TEST_TMPDIR/orig.srt"
  printf '[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:10.34,0:00:12.33,D,c\nDialogue: 0,0:00:20.35,0:00:22.33,D,c\n' > "$BATS_TEST_TMPDIR/cand.ass"
  run_snippet "$SCRIPT" "alignment_stats '$BATS_TEST_TMPDIR/ref.srt' '$BATS_TEST_TMPDIR/orig.srt' '$BATS_TEST_TMPDIR/cand.ass'"
  [ "$(echo "$output" | cut -d' ' -f3)" = "1" ]
}

@test "disagreeing cue counts are reported as an unmeasurable shift" {
  stats_for "1
00:00:00,000 --> 00:00:10,000
r" "1
00:00:01,000 --> 00:00:03,000
o

2
00:00:05,000 --> 00:00:07,000
o" "1
00:00:01,000 --> 00:00:03,000
c"
  [ "$(echo "$output" | cut -d' ' -f2)" = "-1" ]
  [ "$(echo "$output" | cut -d' ' -f3)" = "-1" ]
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

@test "the summary reports each verdict separately" {
  touch_file a.mkv
  touch_file a.en.srt
  touch_file b.mkv
  touch_file b.en.srt
  touch_file c.mkv
  touch_file c.en.srt
  : > "$TREE/b.en.srt.bak"
  alass_shifts_by 4000
  sync_run "$TREE/a.mkv"
  [[ "$output" == *"Done: 1 synced, 0 already in sync, 0 skipped, 0 failed"* ]]
  # The pass above left a.en.srt a backup of its own, so the whole-tree pass now has one subtitle of
  # each kind: a and b carry backups and are skipped, and c is aligned but moves too little to rewrite.
  alass_shifts_by 100
  sync_run "$TREE"
  [[ "$output" == *"Done: 0 synced, 1 already in sync, 2 skipped, 0 failed"* ]]
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

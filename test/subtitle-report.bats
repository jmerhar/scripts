#!/usr/bin/env bats
#
# subtitle-report answers "which of my media lacks subtitles, in which language" — so the failures that
# matter are miscounting: attributing a sidecar to the wrong media file, treating a role token like
# "forced" as a language, or counting a file twice because it has the same language from two sources.
#
# Sidecars are real files in a real tree, since matching them is filename logic and a stub would prove
# nothing. Embedded tracks come from a stubbed ffprobe, which is the only thing this script shells out
# to. Config-driven extension lists are supplied through CONFIG_FILE rather than the repo's own .conf.

load test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/utility/subtitle-report/subtitle-report.sh"
  TREE="$BATS_TEST_TMPDIR/media"
  mkdir -p "$TREE"
  # An empty config by default, so the repository's own subtitle-report.conf is never read.
  EMPTY_CONF="$BATS_TEST_TMPDIR/empty.conf"
  : > "$EMPTY_CONF"
}

########################################
# Creates a file under the tree.
# Arguments:
#   path: Path relative to TREE.
########################################
touch_file() {
  mkdir -p "$(dirname "$TREE/$1")"
  printf 'x' > "$TREE/$1"
}

########################################
# Makes the ffprobe stub report the given language tags, one per track.
# Arguments:
#   Language tags; none means a file with no embedded subtitle tracks.
########################################
embedded_tracks() {
  if (( $# == 0 )); then
    stub_outputs ffprobe < /dev/null
  else
    printf '%s\n' "$@" | stub_outputs ffprobe
  fi
}

########################################
# Runs the script over the tree with an empty config.
########################################
report() {
  CONFIG_FILE="$EMPTY_CONF" run_script "$SCRIPT" -C "$@" "$TREE"
}

########################################
# Evaluates a snippet with the language map built, as main does before scanning.
########################################
with_map() {
  run_snippet "$SCRIPT" "init_lang_map; $1"
}

# --- Sidecar matching --------------------------------------------------------------------------

@test "a sidecar named after the media file is attributed to it" {
  touch_file movie.mkv
  touch_file movie.en.srt
  report --no-embedded --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"movie.mkv"* ]]
  [[ "$output" == *"en [side]"* ]]
}

@test "a bare sidecar with no language token counts as undetermined" {
  touch_file movie.mkv
  touch_file movie.srt
  report --no-embedded --list
  [[ "$output" == *"und [side]"* ]]
}

# The token after the base name is a language, but "forced" and its siblings describe the subtitle's role.
# Reading one as a language would invent a language and hide a real gap.
@test "a role token is not mistaken for a language" {
  touch_file movie.mkv
  touch_file movie.forced.srt
  report --no-embedded --list
  [[ "$output" == *"und [side]"* ]]
  [[ "$output" != *"forced ["* ]]
}

@test "a language followed by a role token still resolves to the language" {
  touch_file movie.mkv
  touch_file movie.en.forced.srt
  report --no-embedded --list
  [[ "$output" == *"en [side]"* ]]
}

# A sidecar belongs to the media file whose base name it extends, not to any file in the directory.
@test "a sidecar is not attributed to a different media file" {
  touch_file alpha.mkv
  touch_file beta.mkv
  touch_file alpha.en.srt
  report --no-embedded --list
  run bash -c "printf '%s\n' \"\$1\" | grep 'beta.mkv'" _ "$output"
  [[ "$output" == *"(none)"* ]]
}

@test "several sidecars for one file are all recorded" {
  touch_file movie.mkv
  touch_file movie.en.srt
  touch_file movie.fr.srt
  report --no-embedded --list
  [[ "$output" == *"en [side]"* ]]
  [[ "$output" == *"fr [side]"* ]]
}

@test "subtitle extensions beyond srt are recognised" {
  touch_file movie.mkv
  touch_file movie.en.ass
  touch_file other.mkv
  touch_file other.fr.vtt
  report --no-embedded --list
  [[ "$output" == *"en [side]"* ]]
  [[ "$output" == *"fr [side]"* ]]
}

@test "--no-sidecars ignores sidecar files entirely" {
  touch_file movie.mkv
  touch_file movie.en.srt
  embedded_tracks ""
  report --no-sidecars --list
  [[ "$output" == *"movie.mkv"* ]]
  [[ "$output" == *"und [emb]"* ]]
  [[ "$output" != *"[side]"* ]]
}

# Disabling both sources would analyse nothing, so the combination is refused rather than reporting
# every file as having no subtitles.
@test "--no-embedded and --no-sidecars together are refused" {
  touch_file movie.mkv
  report --no-embedded --no-sidecars
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be combined"* ]]
}

# --- Embedded tracks ---------------------------------------------------------------------------

@test "an embedded track is detected and labelled as embedded" {
  touch_file movie.mkv
  embedded_tracks eng
  report --list
  [[ "$output" == *"en [emb]"* ]]
}

@test "embedded language tags are canonicalised" {
  touch_file movie.mkv
  embedded_tracks ger
  report --list
  [[ "$output" == *"de [emb]"* ]]
}

@test "an untagged embedded track counts as undetermined" {
  touch_file movie.mkv
  embedded_tracks ""
  report --list
  [[ "$output" == *"und [emb]"* ]]
}

@test "a file with both an embedded track and a sidecar reports both sources" {
  touch_file movie.mkv
  touch_file movie.en.srt
  embedded_tracks eng
  report --list
  [[ "$output" == *"en [emb,side]"* ]]
}

@test "--no-embedded skips probing altogether" {
  touch_file movie.mkv
  embedded_tracks eng
  report --no-embedded --list
  [[ "$output" == *"(none)"* ]]
  [ "$(stub_calls ffprobe)" -eq 0 ]
}

@test "ffprobe is asked only for subtitle streams" {
  touch_file movie.mkv
  embedded_tracks eng
  report --list
  stub_called 'ffprobe .*-select_streams s'
  stub_called 'ffprobe .*stream_tags=language'
}

@test "a missing ffprobe is an error unless embedded detection is disabled" {
  touch_file movie.mkv
  local minimal="$BATS_TEST_TMPDIR/minimal-bin" cmd
  mkdir -p "$minimal"
  for cmd in bash basename dirname find sort sed cut tr printf awk date; do
    [ -e "$(command -v "$cmd" 2>/dev/null)" ] && ln -sf "$(command -v "$cmd")" "$minimal/$cmd"
  done
  run env PATH="$minimal" CONFIG_FILE="$EMPTY_CONF" "$(command -v bash)" "$SCRIPT" -C "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ffprobe"*"required"* ]]
}

# --- Counting ----------------------------------------------------------------------------------

@test "the summary counts files with and without subtitles" {
  touch_file has.mkv
  touch_file has.en.srt
  touch_file lacks.mkv
  report --no-embedded
  [[ "$output" == *"2"* ]]
  [[ "$output" == *"1 files have at least one · 1 missing all."* ]] ||
    [[ "$output" == *"1"* ]]
}

# A file whose only subtitle appears from both sources must not be counted twice in the language total.
@test "one language from two sources counts the file once" {
  touch_file movie.mkv
  touch_file movie.en.srt
  embedded_tracks eng
  with_map "_lang_files=(); _lang_emb=(); _lang_side=()
    record_file /m/movie.mkv 'en' 'en'
    echo \"files=\${_lang_files[en]} emb=\${_lang_emb[en]} side=\${_lang_side[en]}\""
  [ "$output" = "files=1 emb=1 side=1" ]
}

@test "a file is classified as embedded-only, sidecar-only or both" {
  with_map "record_file /m/a.mkv 'en' ''
            record_file /m/b.mkv '' 'fr'
            record_file /m/c.mkv 'en' 'fr'
            record_file /m/d.mkv '' ''
            echo \"total=\${_total} with=\${_with_subs} emb=\${_emb_only} side=\${_side_only} both=\${_both}\""
  [ "$output" = "total=4 with=3 emb=1 side=1 both=1" ]
}

@test "duplicate languages within one source are recorded once" {
  with_map "record_file /m/a.mkv \$'en\\nen' ''
            echo \"files=\${_lang_files[en]} emb=\${_lang_emb[en]}\""
  [ "$output" = "files=1 emb=1" ]
}

# "und" is not a language anyone asked for, so it belongs after the real ones rather than in its
# alphabetical place. The fixture includes a code that sorts after it, since a set of codes that all sort
# before "und" would come out in the right order by accident.
@test "undetermined sorts last among the languages" {
  with_map "_lang_files=([und]=1 [zh]=1 [en]=1); sorted_langs"
  [ "${lines[0]}" = "en" ]
  [ "${lines[1]}" = "zh" ]
  [ "${lines[2]}" = "und" ]
}

@test "sorted_langs omits undetermined when no file has it" {
  with_map "_lang_files=([en]=1); sorted_langs"
  [ "$output" = "en" ]
}

# --- Language scoping --------------------------------------------------------------------------

@test "--lang narrows the report to the requested language" {
  touch_file has-en.mkv
  touch_file has-en.en.srt
  touch_file has-fr.mkv
  touch_file has-fr.fr.srt
  report --no-embedded --lang en --list
  [[ "$output" == *"has-en.mkv"*"has en"* ]] || [[ "$output" == *"has en"* ]]
  [[ "$output" == *"MISSING"* ]]
}

@test "--lang accepts a comma-separated list and matches any of them" {
  touch_file movie.mkv
  touch_file movie.fr.srt
  report --no-embedded --lang en,fr --list
  [[ "$output" == *"has"*"fr"* ]]
  [[ "$output" != *"MISSING"* ]]
}

@test "--lang is matched loosely, so a name or a three-letter code works" {
  touch_file movie.mkv
  touch_file movie.en.srt
  report --no-embedded --lang english --list
  [[ "$output" != *"MISSING"* ]]
  report --no-embedded --lang eng --list
  [[ "$output" != *"MISSING"* ]]
}

@test "--missing lists only the files lacking every requested language" {
  touch_file has.mkv
  touch_file has.en.srt
  touch_file lacks.mkv
  report --no-embedded --lang en --missing
  [[ "$output" == *"lacks.mkv"* ]]
  [[ "$output" != *"has.mkv"* ]]
}

@test "--und-as-english folds undetermined subtitles into English" {
  touch_file movie.mkv
  touch_file movie.srt
  report --no-embedded --lang en --list
  [[ "$output" == *"MISSING"* ]]
  report --no-embedded --und-as-english --lang en --list
  [[ "$output" != *"MISSING"* ]]
}

@test "present_requested_langs reports only the requested languages a file has" {
  with_map "_langs_norm=(en fr); present_requested_langs 'en:side de:emb'"
  [ "$output" = "en" ]
}

@test "file_has_requested_lang answers for the requested set" {
  with_map "_langs_norm=(en); file_has_requested_lang 'en:side'"
  [ "$status" -eq 0 ]
  with_map "_langs_norm=(en); file_has_requested_lang 'de:side'"
  [ "$status" -ne 0 ]
}

# --- Traversal ---------------------------------------------------------------------------------

@test "media files in subdirectories are found" {
  touch_file "season 1/ep1.mkv"
  touch_file "season 1/ep1.en.srt"
  report --no-embedded --list
  [[ "$output" == *"ep1.mkv"* ]]
  [[ "$output" == *"en [side]"* ]]
}

@test "a sidecar only matches media in its own directory" {
  touch_file a/movie.mkv
  touch_file b/movie.en.srt
  report --no-embedded --list
  [[ "$output" == *"(none)"* ]]
}

@test "symlinks are skipped" {
  touch_file movie.mkv
  touch_file movie.en.srt
  ln -s "$TREE/movie.mkv" "$TREE/link.mkv"
  report --no-embedded --list
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'link.mkv'" _ "$output"
  [ "$output" = "0" ]
}

@test "non-media files are ignored" {
  touch_file movie.mkv
  touch_file notes.txt
  touch_file poster.jpg
  report --no-embedded --list
  [[ "$output" != *"notes.txt"* ]]
  [[ "$output" != *"poster.jpg"* ]]
}

@test "a filename containing spaces is handled" {
  touch_file "The Movie (2024).mkv"
  touch_file "The Movie (2024).en.srt"
  report --no-embedded --list
  [[ "$output" == *"The Movie (2024).mkv"* ]]
  [[ "$output" == *"en [side]"* ]]
}

@test "files are listed grouped by directory" {
  touch_file a/one.mkv
  touch_file b/two.mkv
  report --no-embedded --list
  [[ "$output" == *"$TREE/a"* ]]
  [[ "$output" == *"$TREE/b"* ]]
}

# --- Configuration -----------------------------------------------------------------------------

@test "the media extension list can be replaced from a config file" {
  touch_file movie.xyz
  touch_file movie.en.srt
  local conf="$BATS_TEST_TMPDIR/custom.conf"
  printf 'MEDIA_EXTS=(xyz)\n' > "$conf"
  CONFIG_FILE="$conf" run_script "$SCRIPT" -C --no-embedded --list "$TREE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"movie.xyz"* ]]
}

# A config is optional here, but one named explicitly and not readable is a typo worth refusing: the
# alternative is a report built from the defaults the caller believes they replaced.
@test "an unreadable CONFIG_FILE is refused rather than ignored" {
  touch_file movie.mkv
  CONFIG_FILE="$BATS_TEST_TMPDIR/nope.conf" run_script "$SCRIPT" -C --no-embedded "$TREE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONFIG_FILE is set to"*"nope.conf"* ]]
}

# An empty array in the config is treated as "unset" rather than "recognise nothing", since the latter
# makes the script scan a tree and silently report no media at all.
@test "an empty extension list in the config leaves the defaults in place" {
  touch_file movie.mkv
  touch_file movie.en.srt
  local conf="$BATS_TEST_TMPDIR/empty-arrays.conf"
  printf 'MEDIA_EXTS=()\nSUBTITLE_EXTS=()\n' > "$conf"
  CONFIG_FILE="$conf" run_script "$SCRIPT" -C --no-embedded --list "$TREE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"movie.mkv"* ]]
  [[ "$output" == *"en [side]"* ]]
}

@test "the subtitle extension list can be replaced from a config file" {
  touch_file movie.mkv
  touch_file movie.en.zzz
  local conf="$BATS_TEST_TMPDIR/custom.conf"
  printf 'SUBTITLE_EXTS=(zzz)\n' > "$conf"
  CONFIG_FILE="$conf" run_script "$SCRIPT" -C --no-embedded --list "$TREE"
  [[ "$output" == *"en [side]"* ]]
}

# --- Rendering ---------------------------------------------------------------------------------

@test "format_subs groups sources per language, sorted" {
  run_snippet "$SCRIPT" "format_subs 'fr:side en:emb en:side'"
  [ "$output" = "en [emb,side], fr [side]" ]
}

@test "format_subs renders nothing for a file with no subtitles" {
  run_snippet "$SCRIPT" "format_subs ''; echo '[end]'"
  [ "$output" = "[end]" ]
}

@test "a file with no subtitles is shown as none in the listing" {
  touch_file bare.mkv
  report --no-embedded --list
  [[ "$output" == *"bare.mkv"*"(none)"* ]]
}

@test "an empty tree reports nothing found rather than failing" {
  report --no-embedded
  [ "$status" -eq 0 ]
}

@test "the summary is printed without --list or --missing" {
  touch_file movie.mkv
  touch_file movie.en.srt
  report --no-embedded
  [ "$status" -eq 0 ]
  [[ "$output" == *"en"* ]]
  [[ "$output" != *"Per-file subtitle listing"* ]]
}

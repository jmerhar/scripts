#!/usr/bin/env bats
#
# The formatting, language and pattern helpers scattered across the scripts. They are pure, so they
# are the cheapest thing in the repository to pin down, and they are where an off-by-one or a bad
# boundary shows up directly in what the user reads.
#
# Byte and duration formats are asserted under the C locale and UTC that setup_common pins; several
# of them are locale- or timezone-sensitive and would otherwise differ per machine.

load test_helper

setup() {
  setup_common
  COMPARE_DIRS="$REPO_ROOT/scripts/utility/compare-dirs.sh"
  PRUNE="$REPO_ROOT/scripts/system/prune-orphaned-torrents.sh"
  SIDECARS="$REPO_ROOT/scripts/photography/remove-sidecars.sh"
  MDCHECK="$REPO_ROOT/scripts/system/mdcheck-progress.sh"
  SUBSYNC="$REPO_ROOT/scripts/utility/subtitle-sync.sh"
  SUBREPORT="$REPO_ROOT/scripts/utility/subtitle-report.sh"
  DMARC="$REPO_ROOT/scripts/utility/dmarc-report.sh"
}

########################################
# Skips the calling test unless GNU date's -d option is available.
# mdcheck-progress is published for Debian only and its time helpers use `date -d`, which BSD date
# does not support, so these assertions can only run on Linux.
########################################
require_gnu_date() {
  date -d "@0" +%s >/dev/null 2>&1 || skip "needs GNU date -d (mdcheck-progress is Linux-only)"
}

# --- compare-dirs: byte and time formatting ---------------------------------------------------

# format_size uses printf's %'d, whose thousands grouping is locale-dependent; under the pinned C
# locale there is no separator. A machine running en_US would render 2048 as "2,048 bytes".
@test "compare-dirs format_size renders a plain byte count" {
  run_func "$COMPARE_DIRS" format_size 2048
  [ "$status" -eq 0 ]
  [ "$output" = "2048 bytes" ]
}

@test "compare-dirs format_size handles zero" {
  run_func "$COMPARE_DIRS" format_size 0
  [ "$output" = "0 bytes" ]
}

@test "compare-dirs format_mtime renders the epoch in UTC" {
  run_func "$COMPARE_DIRS" format_mtime 0
  [ "$status" -eq 0 ]
  [ "$output" = "1970-01-01 00:00:00" ]
}

@test "compare-dirs format_mtime renders a known timestamp" {
  run_func "$COMPARE_DIRS" format_mtime 1700000000
  [ "$output" = "2023-11-14 22:13:20" ]
}

# --- compare-dirs: pattern matching and type detection ----------------------------------------

@test "matches_pattern matches an exact name" {
  run_func "$COMPARE_DIRS" matches_pattern notes.txt notes.txt
  [ "$status" -eq 0 ]
}

@test "matches_pattern matches a glob" {
  run_func "$COMPARE_DIRS" matches_pattern debug.log '*.log'
  [ "$status" -eq 0 ]
}

@test "matches_pattern tries every pattern it is given" {
  run_func "$COMPARE_DIRS" matches_pattern debug.log '*.tmp' '*.bak' '*.log'
  [ "$status" -eq 0 ]
}

@test "matches_pattern fails when nothing matches" {
  run_func "$COMPARE_DIRS" matches_pattern notes.txt '*.log' '*.tmp'
  [ "$status" -eq 1 ]
}

@test "matches_pattern fails when given no patterns" {
  run_func "$COMPARE_DIRS" matches_pattern notes.txt
  [ "$status" -eq 1 ]
}

@test "matches_pattern does not treat a glob as a literal" {
  run_func "$COMPARE_DIRS" matches_pattern 'star.log' '*.log'
  [ "$status" -eq 0 ]
  run_func "$COMPARE_DIRS" matches_pattern '*.log' 'notes.txt'
  [ "$status" -eq 1 ]
}

@test "get_type names a regular file" {
  touch "$BATS_TEST_TMPDIR/plain"
  run_func "$COMPARE_DIRS" get_type "$BATS_TEST_TMPDIR/plain"
  [ "$output" = "file" ]
}

@test "get_type names a directory" {
  mkdir "$BATS_TEST_TMPDIR/adir"
  run_func "$COMPARE_DIRS" get_type "$BATS_TEST_TMPDIR/adir"
  [ "$output" = "directory" ]
}

@test "get_type reports a symlink as such, not as its target" {
  touch "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$BATS_TEST_TMPDIR/link"
  run_func "$COMPARE_DIRS" get_type "$BATS_TEST_TMPDIR/link"
  [ "$output" = "symlink" ]
}

@test "get_type falls back to other for something missing" {
  run_func "$COMPARE_DIRS" get_type "$BATS_TEST_TMPDIR/not-here"
  [ "$output" = "other" ]
}

# --- prune-orphaned-torrents: sizes and ages --------------------------------------------------

@test "prune format_size reports zero without a decimal" {
  run_func "$PRUNE" format_size 0
  [ "$output" = "0 B" ]
}

@test "prune format_size stays in bytes below one kilobyte" {
  run_func "$PRUNE" format_size 1023
  [ "$output" = "1023.00 B" ]
}

@test "prune format_size steps up at exactly one kilobyte" {
  run_func "$PRUNE" format_size 1024
  [ "$output" = "1.00 KB" ]
}

@test "prune format_size rounds to two decimals" {
  run_func "$PRUNE" format_size 1536
  [ "$output" = "1.50 KB" ]
}

@test "prune format_size scales to megabytes" {
  run_func "$PRUNE" format_size 1048576
  [ "$output" = "1.00 MB" ]
}

@test "prune format_size defaults to zero with no argument" {
  run_func "$PRUNE" format_size
  [ "$output" = "0 B" ]
}

@test "prune format_age shows hours and minutes under a day" {
  run_func "$PRUNE" format_age 3660
  [ "$output" = "1h 1m" ]
}

@test "prune format_age switches to days and hours past a day" {
  run_func "$PRUNE" format_age 90000
  [ "$output" = "1d 1h" ]
}

# A clock skew can hand this a negative age. The value has to be at least an hour past zero to pin the
# clamp: integer division truncates toward zero, so a small negative renders as "0h 0m" with or
# without it, and an assertion using one would pass even if the clamp were deleted.
@test "prune format_age treats a negative age as zero" {
  run_func "$PRUNE" format_age -3600
  [ "$output" = "0h 0m" ]
  run_func "$PRUNE" format_age -90000
  [ "$output" = "0h 0m" ]
  run_func "$PRUNE" format_age -5
  [ "$output" = "0h 0m" ]
}

@test "prune format_age defaults to zero with no argument" {
  run_func "$PRUNE" format_age
  [ "$output" = "0h 0m" ]
}

# --- remove-sidecars ---------------------------------------------------------------------------

@test "remove-sidecars format_size matches the shared byte formatting" {
  run_func "$SIDECARS" format_size 1048576
  [ "$output" = "1.00 MB" ]
  run_func "$SIDECARS" format_size 0
  [ "$output" = "0 B" ]
}

# --- mdcheck-progress --------------------------------------------------------------------------

@test "human_bytes prints whole bytes without decimals" {
  run_func "$MDCHECK" human_bytes 512
  [ "$output" = "512 B" ]
}

@test "human_bytes switches to two decimals from kibibytes up" {
  run_func "$MDCHECK" human_bytes 1024
  [ "$output" = "1.00 KiB" ]
  run_func "$MDCHECK" human_bytes 1048576
  [ "$output" = "1.00 MiB" ]
}

@test "human_bytes uses binary units" {
  run_func "$MDCHECK" human_bytes 1536
  [ "$output" = "1.50 KiB" ]
}

@test "fmt_ts renders an epoch as a dated, zoned stamp" {
  require_gnu_date
  run_func "$MDCHECK" fmt_ts 0
  [ "$status" -eq 0 ]
  [[ "$output" == "Thu 1970-01-01 00:00 "* ]]
}

@test "to_epoch parses a date back to seconds" {
  require_gnu_date
  run_func "$MDCHECK" to_epoch "1970-01-01 00:00:00"
  [ "$output" = "0" ]
}

@test "to_epoch yields nothing for an absent or unknown time" {
  require_gnu_date
  run_func "$MDCHECK" to_epoch ""
  [ -z "$output" ]
  run_func "$MDCHECK" to_epoch "n/a"
  [ -z "$output" ]
}

@test "to_epoch yields nothing rather than failing on garbage" {
  require_gnu_date
  run_func "$MDCHECK" to_epoch "not a date at all"
  [ -z "$output" ]
}

@test "midnight_of truncates a timestamp to the start of its day" {
  require_gnu_date
  run_func "$MDCHECK" midnight_of 1700000000
  [ "$output" = "1699920000" ]
}

# --- subtitle-sync: case, durations, extensions, cache keys -----------------------------------

@test "_lower lowercases its argument" {
  run_func "$SUBSYNC" _lower "MiXeD Case"
  [ "$output" = "mixed case" ]
}

# _fmt_dur is called only inside command substitutions, and that is where it must be tested. Its
# leading `(( a = …, b = … ))` evaluates to whatever the last assignment yields, so at exact-minute
# durations the arithmetic returns non-zero — harmless inside $(…), but a bare `_fmt_dur 60`
# statement under errexit would abort before printing.
@test "_fmt_dur renders seconds alone under a minute" {
  run_snippet "$SUBSYNC" 'echo "$(_fmt_dur 42)"'
  [ "$output" = "42s" ]
}

@test "_fmt_dur renders minutes and padded seconds" {
  run_snippet "$SUBSYNC" 'echo "$(_fmt_dur 320)"'
  [ "$output" = "5m 20s" ]
}

@test "_fmt_dur renders hours with padded minutes and seconds" {
  run_snippet "$SUBSYNC" 'echo "$(_fmt_dur 3792)"'
  [ "$output" = "1h 03m 12s" ]
}

@test "_fmt_dur renders exact-minute durations" {
  run_snippet "$SUBSYNC" 'echo "$(_fmt_dur 60)"'
  [ "$output" = "1m 00s" ]
  run_snippet "$SUBSYNC" 'echo "$(_fmt_dur 3600)"'
  [ "$output" = "1h 00m 00s" ]
}

@test "_fmt_dur renders zero" {
  run_snippet "$SUBSYNC" 'echo "$(_fmt_dur 0)"'
  [ "$output" = "0s" ]
}

@test "subtitle-sync normalize_lang canonicalises codes and names" {
  run_func "$SUBSYNC" normalize_lang EN
  [ "$output" = "en" ]
  run_func "$SUBSYNC" normalize_lang eng
  [ "$output" = "en" ]
  run_func "$SUBSYNC" normalize_lang English
  [ "$output" = "en" ]
}

@test "subtitle-sync normalize_lang ignores surrounding whitespace" {
  run_func "$SUBSYNC" normalize_lang " f r "
  [ "$output" = "fr" ]
}

@test "subtitle-sync normalize_lang maps an empty or undetermined value to und" {
  run_func "$SUBSYNC" normalize_lang ""
  [ "$output" = "und" ]
  run_func "$SUBSYNC" normalize_lang und
  [ "$output" = "und" ]
  run_func "$SUBSYNC" normalize_lang undetermined
  [ "$output" = "und" ]
}

@test "subtitle-sync normalize_lang passes an unknown code through" {
  run_func "$SUBSYNC" normalize_lang zzz
  [ "$output" = "zzz" ]
}

@test "lang_matches_target accepts the target language" {
  run_snippet "$SUBSYNC" '_lang=en; lang_matches_target en'
  [ "$status" -eq 0 ]
}

@test "lang_matches_target accepts an undetermined track" {
  run_snippet "$SUBSYNC" '_lang=en; lang_matches_target und'
  [ "$status" -eq 0 ]
}

@test "lang_matches_target rejects a different language" {
  run_snippet "$SUBSYNC" '_lang=en; lang_matches_target fr'
  [ "$status" -ne 0 ]
}

@test "lang_matches_target normalises the configured target" {
  run_snippet "$SUBSYNC" '_lang=English; lang_matches_target en'
  [ "$status" -eq 0 ]
}

@test "has_ext matches an extension case-insensitively" {
  run_snippet "$SUBSYNC" 'exts=(srt ass); has_ext /films/movie.SRT exts'
  [ "$status" -eq 0 ]
}

@test "has_ext rejects an extension outside the list" {
  run_snippet "$SUBSYNC" 'exts=(srt ass); has_ext /films/movie.vtt exts'
  [ "$status" -ne 0 ]
}

@test "has_ext rejects a name with no extension at all" {
  run_snippet "$SUBSYNC" 'exts=(srt); has_ext /films/README exts'
  [ "$status" -ne 0 ]
}

@test "cache_key is stable for the same file and settings" {
  local video="$BATS_TEST_TMPDIR/ep.mkv"
  printf 'video bytes' > "$video"
  run_snippet "$SUBSYNC" "cache_key '$video'"
  local first="$output"
  run_snippet "$SUBSYNC" "cache_key '$video'"
  [ "$output" = "$first" ]
  [ -n "$first" ]
}

@test "cache_key changes when the model changes" {
  local video="$BATS_TEST_TMPDIR/ep.mkv"
  printf 'video bytes' > "$video"
  run_snippet "$SUBSYNC" "_model=base.en; cache_key '$video'"
  local base="$output"
  run_snippet "$SUBSYNC" "_model=large-v3; cache_key '$video'"
  [ "$output" != "$base" ]
}

@test "cache_key changes when the file's contents change" {
  local video="$BATS_TEST_TMPDIR/ep.mkv"
  printf 'first' > "$video"
  run_snippet "$SUBSYNC" "cache_key '$video'"
  local before="$output"
  printf 'second and longer' > "$video"
  run_snippet "$SUBSYNC" "cache_key '$video'"
  [ "$output" != "$before" ]
}

# --- subtitle-report: the table-driven language map -------------------------------------------

@test "subtitle-report normalize_lang canonicalises a two-letter code" {
  run_func "$SUBREPORT" normalize_lang de
  [ "$output" = "de" ]
}

@test "subtitle-report normalize_lang canonicalises bibliographic and terminologic codes" {
  run_func "$SUBREPORT" normalize_lang ger
  [ "$output" = "de" ]
  run_func "$SUBREPORT" normalize_lang deu
  [ "$output" = "de" ]
}

@test "subtitle-report normalize_lang canonicalises an English language name" {
  run_func "$SUBREPORT" normalize_lang German
  [ "$output" = "de" ]
}

@test "subtitle-report normalize_lang resolves an alternative name" {
  run_func "$SUBREPORT" normalize_lang flemish
  [ "$output" = "nl" ]
}

@test "subtitle-report normalize_lang maps undetermined to und by default" {
  run_func "$SUBREPORT" normalize_lang ""
  [ "$output" = "und" ]
  run_func "$SUBREPORT" normalize_lang und
  [ "$output" = "und" ]
}

@test "subtitle-report normalize_lang can treat undetermined as English" {
  run_snippet "$SUBREPORT" '_und_as_english=true; normalize_lang ""'
  [ "$output" = "en" ]
}

@test "subtitle-report normalize_lang passes an unknown token through" {
  run_func "$SUBREPORT" normalize_lang qqq
  [ "$output" = "qqq" ]
}

@test "lang_from_tokens takes the language from a bare token" {
  run_func "$SUBREPORT" lang_from_tokens en
  [ "$output" = "en" ]
}

@test "lang_from_tokens skips a leading flag token" {
  run_func "$SUBREPORT" lang_from_tokens forced.en
  [ "$output" = "en" ]
}

@test "lang_from_tokens ignores a trailing flag token" {
  run_func "$SUBREPORT" lang_from_tokens en.forced
  [ "$output" = "en" ]
}

@test "lang_from_tokens yields und when every token is a flag" {
  run_func "$SUBREPORT" lang_from_tokens sdh
  [ "$output" = "und" ]
}

@test "lang_from_tokens yields und for an empty token list" {
  run_func "$SUBREPORT" lang_from_tokens ""
  [ "$output" = "und" ]
}

# --- dmarc-report ------------------------------------------------------------------------------

@test "epoch_to_date formats an epoch in UTC" {
  run_func "$DMARC" epoch_to_date 1700000000 "%Y-%m-%d"
  [ "$status" -eq 0 ]
  [ "$output" = "2023-11-14" ]
}

@test "epoch_to_date honours the requested format" {
  run_func "$DMARC" epoch_to_date 1700000000 "%H:%M"
  [ "$output" = "22:13" ]
}

@test "epoch_to_date yields nothing for zero or an empty epoch" {
  run_func "$DMARC" epoch_to_date 0 "%Y"
  [ -z "$output" ]
  run_func "$DMARC" epoch_to_date "" "%Y"
  [ -z "$output" ]
}

# clean_auth_pairs returns two lines — the cleaned list, then a pass flag — and the list may legally
# be empty. Reading both fields explicitly keeps the assertion unambiguous about which is which.
@test "clean_auth_pairs drops empty slots and reports that one passed" {
  run_snippet "$DMARC" 'clean_auth_pairs "example.com:pass;:;other.com:fail" |
    { IFS= read -r pairs; IFS= read -r any; printf "pairs=[%s] any=[%s]" "$pairs" "$any"; }'
  [ "$output" = "pairs=[example.com:pass;other.com:fail] any=[1]" ]
}

@test "clean_auth_pairs reports no pass when every result failed" {
  run_snippet "$DMARC" 'clean_auth_pairs "a.com:fail;b.com:softfail" |
    { IFS= read -r pairs; IFS= read -r any; printf "pairs=[%s] any=[%s]" "$pairs" "$any"; }'
  [ "$output" = "pairs=[a.com:fail;b.com:softfail] any=[0]" ]
}

@test "clean_auth_pairs yields an empty list for nothing but empty slots" {
  run_snippet "$DMARC" 'clean_auth_pairs ":;:;" |
    { IFS= read -r pairs; IFS= read -r any; printf "pairs=[%s] any=[%s]" "$pairs" "$any"; }'
  [ "$output" = "pairs=[] any=[0]" ]
}

# _AUTH_SLOTS is a readonly literal, so these assert against the shipped slot count rather than
# setting one: three "domain:result" terms joined by two separators.
@test "auth_concat_expr builds one XPath term per auth slot" {
  run_func "$DMARC" auth_concat_expr "rec" "dkim"
  [ "$status" -eq 0 ]
  [[ "$output" == *"normalize-space(rec/auth_results/dkim[1]/domain)"* ]]
  [[ "$output" == *"normalize-space(rec/auth_results/dkim[3]/result)"* ]]
}

@test "auth_concat_expr separates slots without a trailing separator" {
  run_func "$DMARC" auth_concat_expr "rec" "spf"
  # Two separators for three slots, and the expression must not end with one.
  run bash -c "printf '%s' \"\$1\" | grep -o \"';',\" | wc -l | tr -d ' '" _ "$output"
  [ "$output" = "2" ]
  run_func "$DMARC" auth_concat_expr "rec" "spf"
  [[ "$output" != *"';'," ]]
  [[ "$output" == *"/result)" ]]
}

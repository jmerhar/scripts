#!/usr/bin/env bats
#
# scripts/lib/lang.sh exists because two scripts read the same media libraries and disagreed about what a
# language is called. subtitle-report canonicalised from a 183-row ISO 639 table; subtitle-sync had a
# hand-written case with 24 arms, so it left "vietnamese", "thai", "catalan", "serbian" and "modern greek"
# exactly as it found them — and `--lang vietnamese` could not then match a track tagged `vi`.
#
# The last test here is the one that keeps that from coming back: both scripts are asked, and their answers
# must match.

load ../test_helper

setup() {
  setup_common
  TOOL=$(lib_at opt/tools lang-user lang.sh)
  REPORT="$REPO_ROOT/scripts/utility/subtitle-report/subtitle-report.sh"
  SYNC="$REPO_ROOT/scripts/utility/subtitle-sync/subtitle-sync.sh"
}

# --- Canonicalisation --------------------------------------------------------------------------

@test "a two-letter code is already canonical" {
  run_snippet "$TOOL" 'normalize_lang en'
  [ "$output" = "en" ]
}

@test "both three-letter codes resolve to the two-letter one" {
  run_snippet "$TOOL" 'normalize_lang ger'
  [ "$output" = "de" ]
  run_snippet "$TOOL" 'normalize_lang deu'
  [ "$output" = "de" ]
}

@test "an English name resolves" {
  run_snippet "$TOOL" 'normalize_lang german'
  [ "$output" = "de" ]
}

# Names are registered with their whitespace stripped, so a multi-word name is reachable however it is typed.
@test "a multi-word name resolves regardless of spacing and case" {
  run_snippet "$TOOL" "normalize_lang 'Modern Greek'"
  [ "$output" = "el" ]
  run_snippet "$TOOL" 'normalize_lang moderngreek'
  [ "$output" = "el" ]
}

@test "case is irrelevant" {
  run_snippet "$TOOL" 'normalize_lang ENGLISH'
  [ "$output" = "en" ]
  run_snippet "$TOOL" 'normalize_lang Eng'
  [ "$output" = "en" ]
}

# Passing an unknown tag through, rather than discarding it, is what lets a report show a language the table
# has never heard of instead of silently dropping the file.
@test "an unrecognised tag passes through, lowercased and stripped" {
  run_snippet "$TOOL" "normalize_lang ' Klingon '"
  [ "$output" = "klingon" ]
}

# --- Undetermined ------------------------------------------------------------------------------

@test "empty and explicit undetermined both become und" {
  run_snippet "$TOOL" 'normalize_lang ""'
  [ "$output" = "und" ]
  run_snippet "$TOOL" 'normalize_lang und'
  [ "$output" = "und" ]
  run_snippet "$TOOL" 'normalize_lang undetermined'
  [ "$output" = "und" ]
}

# Opt-in, and off by default: asserting that an untagged subtitle is English overstates coverage for a
# library that is not English, and loses the distinction between "untagged" and "English".
@test "undetermined becomes English only when the caller asks" {
  run_snippet "$TOOL" '_und_as_english=true; normalize_lang ""'
  [ "$output" = "en" ]
  run_snippet "$TOOL" 'normalize_lang ""'
  [ "$output" = "und" ]
}

# --- lang_from_tokens --------------------------------------------------------------------------

@test "the language is taken from the tokens between the base name and the extension" {
  run_snippet "$TOOL" 'lang_from_tokens en'
  [ "$output" = "en" ]
}

# "forced" describes the subtitle's role, not its language; reading it as one would invent a language and
# hide a real gap.
@test "a role token is skipped rather than read as a language" {
  run_snippet "$TOOL" 'lang_from_tokens forced'
  [ "$output" = "und" ]
  run_snippet "$TOOL" 'lang_from_tokens forced.en'
  [ "$output" = "en" ]
  run_snippet "$TOOL" 'lang_from_tokens en.forced'
  [ "$output" = "en" ]
}

@test "no tokens at all is undetermined" {
  run_snippet "$TOOL" 'lang_from_tokens ""'
  [ "$output" = "und" ]
}

@test "the caller may name its own role tokens" {
  run_snippet "$TOOL" '_sidecar_flags=(dubbed); lang_from_tokens dubbed.fr'
  [ "$output" = "fr" ]
}

# --- The table ---------------------------------------------------------------------------------

# One row lacked its English name, which is why "bulgarian" resolved to "bulgarian". A missing name is
# invisible until someone types that language.
@test "every row in the table carries at least one English name" {
  run bash -c "grep -cE '^[a-z]{2}\|[a-z]*\|[a-z]*\|\$' '$LIB_DIR/lang.sh' || true"
  [ "$output" = "0" ]
}

@test "the table covers the languages a media library actually contains" {
  local lang
  for lang in english german french spanish italian dutch russian japanese chinese korean \
              vietnamese thai catalan serbian bulgarian polish swedish greek hebrew turkish; do
    run_snippet "$TOOL" "normalize_lang '$lang'"
    [ "${#output}" -eq 2 ] || { echo "did not resolve: $lang -> $output"; return 1; }
  done
}

# --- The two scripts agree ---------------------------------------------------------------------

# The regression test for the bug this library was written to fix. Both scripts are driven through their own
# normalize_lang, so a future copy of the table in either one shows up here.
@test "subtitle-report and subtitle-sync normalise identically" {
  local lang from_report from_sync
  for lang in english vietnamese thai catalan serbian bulgarian "modern greek" ger und ""; do
    run_snippet "$REPORT" "normalize_lang '$lang'"
    from_report="$output"
    run_snippet "$SYNC" "normalize_lang '$lang'"
    from_sync="$output"
    [ "$from_report" = "$from_sync" ] || {
      echo "disagreement on '$lang': report=$from_report sync=$from_sync"
      return 1
    }
  done
}

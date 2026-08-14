#!/usr/bin/env bats
#
# The command-line contract of each user-facing script: which options are accepted, how bad input is
# rejected, and what a flag actually sets. This is the part users touch directly and the part a
# refactor of an option loop breaks silently.
#
# Rejections are driven through the real command line, so the asserted exit status is the one a caller
# or a cron job would see. Flag effects are checked by calling parse_options and reading the globals it
# sets, which is far cheaper than arranging a full run.
#
# The bin/ tooling has its own suites; only user-facing scripts are covered here.

load test_helper

setup() {
  setup_common
  COMPARE_DIRS="$REPO_ROOT/scripts/utility/compare-dirs/compare-dirs.sh"
  SIDECARS="$REPO_ROOT/scripts/photography/remove-sidecars/remove-sidecars.sh"
  LOCAL_BACKUP="$REPO_ROOT/scripts/system/local-backup/local-backup.sh"
  PHOTO_BACKUP="$REPO_ROOT/scripts/photography/photo-backup/photo-backup.sh"
  MDCHECK="$REPO_ROOT/scripts/system/mdcheck-progress/mdcheck-progress.sh"
  NOPASSWD="$REPO_ROOT/scripts/system/nopasswd-sudo/nopasswd-sudo.sh"
  PRUNE="$REPO_ROOT/scripts/system/prune-orphaned-torrents/prune-orphaned-torrents.sh"
  DMARC="$REPO_ROOT/scripts/utility/dmarc-report/dmarc-report.sh"
  SUBREPORT="$REPO_ROOT/scripts/utility/subtitle-report/subtitle-report.sh"
  SUBSYNC="$REPO_ROOT/scripts/utility/subtitle-sync/subtitle-sync.sh"
  UNLOCK="$REPO_ROOT/scripts/utility/unlock-pdf/unlock-pdf.sh"

  # Two real directories, for the scripts that insist their arguments exist.
  LEFT="$BATS_TEST_TMPDIR/left"
  RIGHT="$BATS_TEST_TMPDIR/right"
  mkdir -p "$LEFT" "$RIGHT"
}

# --- compare-dirs ------------------------------------------------------------------------------

@test "compare-dirs help lists every documented option" {
  run_script "$COMPARE_DIRS" --help
  [ "$status" -eq 0 ]
  for opt in --timestamps --checksums --ignore-case --no-dotfiles --exclude \
             --exclude-left --exclude-right --no-color --help; do
    [[ "$output" == *"$opt"* ]] || { echo "missing $opt from usage" >&2; return 1; }
  done
}

@test "compare-dirs rejects an unknown short option" {
  run_script "$COMPARE_DIRS" -Z "$LEFT" "$RIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option: -Z"* ]]
}

@test "compare-dirs insists on exactly two directories" {
  run_script "$COMPARE_DIRS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected exactly 2 directory arguments, got 0."* ]]

  run_script "$COMPARE_DIRS" "$LEFT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"got 1."* ]]

  run_script "$COMPARE_DIRS" "$LEFT" "$RIGHT" "$LEFT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"got 3."* ]]
}

@test "compare-dirs rejects an argument that is not a directory" {
  touch "$BATS_TEST_TMPDIR/afile"
  run_script "$COMPARE_DIRS" "$BATS_TEST_TMPDIR/afile" "$RIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a directory."* ]]
}

@test "compare-dirs accepts long flags and records them" {
  run_snippet "$COMPARE_DIRS" \
    "parse_options --timestamps --checksums --ignore-case --no-dotfiles '$LEFT' '$RIGHT'
     echo \"\$_opt_timestamps \$_opt_checksums \$_opt_ignore_case \$_opt_no_dotfiles\""
  [ "$status" -eq 0 ]
  [ "$output" = "true true true true" ]
}

@test "compare-dirs accepts short flags bundled together" {
  run_snippet "$COMPARE_DIRS" \
    "parse_options -tcid '$LEFT' '$RIGHT'
     echo \"\$_opt_timestamps \$_opt_checksums \$_opt_ignore_case \$_opt_no_dotfiles\""
  [ "$output" = "true true true true" ]
}

@test "compare-dirs allows -x at the end of a bundle" {
  run_snippet "$COMPARE_DIRS" \
    "parse_options -tx '*.log' '$LEFT' '$RIGHT'; echo \"\$_opt_timestamps \${_opt_excludes[0]}\""
  [ "$output" = "true *.log" ]
}

@test "compare-dirs refuses -x in the middle of a bundle, where its argument would be lost" {
  run_script "$COMPARE_DIRS" -xt '*.log' "$LEFT" "$RIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"-x must be last in a combined flag group"* ]]
}

@test "compare-dirs collects repeated exclude patterns" {
  run_snippet "$COMPARE_DIRS" \
    "parse_options -x '*.log' --exclude '*.tmp' '$LEFT' '$RIGHT'
     echo \"\${#_opt_excludes[@]}:\${_opt_excludes[0]},\${_opt_excludes[1]}\""
  [ "$output" = "2:*.log,*.tmp" ]
}

@test "compare-dirs keeps side-specific excludes apart" {
  run_snippet "$COMPARE_DIRS" \
    "parse_options --exclude-left L --exclude-right R '$LEFT' '$RIGHT'
     echo \"\${_opt_excludes_left[0]}/\${_opt_excludes_right[0]}\""
  [ "$output" = "L/R" ]
}

@test "compare-dirs treats everything after -- as a directory argument" {
  run_snippet "$COMPARE_DIRS" "parse_options -- '$LEFT' '$RIGHT'; echo \"\$_dir1\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"/left" ]]
}

@test "compare-dirs resolves its directories to absolute paths" {
  run_snippet "$COMPARE_DIRS" "cd '$BATS_TEST_TMPDIR'; parse_options left right; echo \"\$_dir1|\$_dir2\""
  [[ "$output" == /*"/left|"/*"/right" ]]
}

# --- remove-sidecars ---------------------------------------------------------------------------

@test "remove-sidecars rejects an unknown option" {
  run_script "$SIDECARS" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'. Use --help for usage."* ]]
}

@test "remove-sidecars accepts at most one directory" {
  run_script "$SIDECARS" "$LEFT" "$RIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Expected at most one directory argument, got 2."* ]]
}

@test "remove-sidecars rejects a directory that does not exist" {
  run_script "$SIDECARS" "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a directory."* ]]
}

@test "remove-sidecars records the dry-run and no-color flags" {
  run_snippet "$SIDECARS" 'parse_options --dry-run --no-color; echo "$_dry_run $_no_color"'
  [ "$output" = "true true" ]
  run_snippet "$SIDECARS" 'parse_options -n -C; echo "$_dry_run $_no_color"'
  [ "$output" = "true true" ]
}

@test "remove-sidecars takes an explicit target directory" {
  run_snippet "$SIDECARS" "parse_options '$LEFT'; echo \"\$_target_dir\""
  [ "$output" = "$LEFT" ]
}

# --- getopts-based scripts ---------------------------------------------------------------------

@test "local-backup rejects an invalid option" {
  run_script "$LOCAL_BACKUP" -z
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid option: -z"* ]]
}

@test "local-backup rejects stray positional arguments" {
  run_script "$LOCAL_BACKUP" unexpected
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected arguments: unexpected"* ]]
}

# getopts only understands single-dash options, so the long form is not part of the contract.
@test "local-backup does not accept a long help flag" {
  run_script "$LOCAL_BACKUP" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid option"* ]]
}

@test "local-backup -d turns on debug output" {
  run_snippet "$LOCAL_BACKUP" 'parse_options -d; echo "$IS_DEBUG_MODE"'
  [ "$output" = "true" ]
}

@test "photo-backup rejects an invalid option" {
  run_script "$PHOTO_BACKUP" -z
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid option: -z"* ]]
}

@test "photo-backup rejects stray positional arguments" {
  run_script "$PHOTO_BACKUP" unexpected
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected arguments: unexpected"* ]]
}

# --- mdcheck-progress --------------------------------------------------------------------------

@test "mdcheck-progress rejects an unknown option" {
  run_script "$MDCHECK" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'. Use --help for usage."* ]]
}

@test "mdcheck-progress records its flags" {
  run_snippet "$MDCHECK" 'parse_options --no-color --debug; echo "$_no_color $IS_DEBUG_MODE"'
  [ "$output" = "true true" ]
  run_snippet "$MDCHECK" 'parse_options -C -d; echo "$_no_color $IS_DEBUG_MODE"'
  [ "$output" = "true true" ]
}

@test "mdcheck-progress accepts array names with or without a /dev/ prefix" {
  run_snippet "$MDCHECK" 'parse_options /dev/md0 md1; echo "${_filters[0]} ${_filters[1]}"'
  [ "$output" = "md0 md1" ]
}

@test "mdcheck-progress treats arguments after -- as array names" {
  run_snippet "$MDCHECK" 'parse_options -- md0; echo "${_filters[0]}"'
  [ "$output" = "md0" ]
}

# --- nopasswd-sudo -----------------------------------------------------------------------------

@test "nopasswd-sudo shows usage when called with no command" {
  run_script "$NOPASSWD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"{on|off|status}"* ]]
}

########################################
# Skips the calling test when the suite is running as root.
# The two assertions below are about what a non-root caller is refused. Run as root — in a container,
# or under sudo — nopasswd-sudo would instead proceed to change the real sudoers configuration, so
# skipping is both the accurate result and the safe one.
########################################
require_non_root() {
  [ "${EUID:-$(id -u)}" -ne 0 ] || skip "asserts the non-root refusal; this run is root"
}

# Root is checked before the command is validated, so a non-root caller is turned away even for a
# nonsense command and never learns it was nonsense. That ordering is deliberate — nothing about the
# request is acted on until privilege is established — which also means the "unknown command" status
# is reachable only as root.
@test "nopasswd-sudo checks for root before it validates the command" {
  require_non_root
  run_script "$NOPASSWD" sideways
  [ "$status" -eq 1 ]
  [[ "$output" == *"must run as root"* ]]
  [[ "$output" != *"unknown command"* ]]
}

# Every command must refuse outright rather than half-apply when it cannot do the job.
@test "nopasswd-sudo refuses to act without root" {
  require_non_root
  for cmd in on off status; do
    run_script "$NOPASSWD" "$cmd"
    [ "$status" -eq 1 ] || { echo "$cmd did not refuse" >&2; return 1; }
    [[ "$output" == *"must run as root"* ]] || { echo "$cmd gave no root error" >&2; return 1; }
  done
}

# --- the remaining option loops ----------------------------------------------------------------

@test "prune-orphaned-torrents rejects an unknown option" {
  run_script "$PRUNE" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'. Use --help for usage."* ]]
}

@test "dmarc-report rejects an unknown option" {
  run_script "$DMARC" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'. Use --help for usage."* ]]
}

@test "subtitle-report rejects an unknown option" {
  run_script "$SUBREPORT" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'. Use --help for usage."* ]]
}

@test "subtitle-sync rejects an unknown option" {
  run_script "$SUBSYNC" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'. Use --help for usage."* ]]
}

@test "subtitle-sync reports an option whose argument is missing" {
  run_func "$SUBSYNC" _require_arg --lang
  [ "$status" -eq 1 ]
  [[ "$output" == *"Option '--lang' requires an argument."* ]]
}

@test "subtitle-sync accepts an option that has its argument" {
  run_func "$SUBSYNC" _require_arg --lang en
  [ "$status" -eq 0 ]
}

# --- unlock-pdf --------------------------------------------------------------------------------

@test "unlock-pdf requires exactly one argument" {
  run_script "$UNLOCK" one.pdf two.pdf
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unlock-pdf reports a missing input file" {
  run_script "$UNLOCK" "$BATS_TEST_TMPDIR/absent.pdf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"File not found: "*"absent.pdf"* ]]
}

@test "unlock-pdf refuses a file that is not a PDF" {
  touch "$BATS_TEST_TMPDIR/notes.txt"
  run_script "$UNLOCK" "$BATS_TEST_TMPDIR/notes.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not a PDF file: "*"notes.txt"* ]]
}

@test "unlock-pdf accepts an uppercase PDF extension" {
  # Reaches the password prompt, which is as far as this test goes: an empty password is refused.
  touch "$BATS_TEST_TMPDIR/scan.PDF"
  run bash -c "printf '\n' | bash '$UNLOCK' '$BATS_TEST_TMPDIR/scan.PDF'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Password cannot be empty."* ]]
}

@test "unlock-pdf explains itself when qpdf is missing" {
  # An empty directory as the only PATH entry, so nothing — not even the stubs — is reachable. bash
  # itself is named absolutely, since it could not be found on that PATH either.
  local empty="$BATS_TEST_TMPDIR/empty-path" bash_path
  mkdir -p "$empty"
  bash_path=$(command -v bash)
  run env PATH="$empty" "$bash_path" "$UNLOCK" some.pdf
  [ "$status" -eq 1 ]
  [[ "$output" == *"'qpdf' is not installed"* ]]
}

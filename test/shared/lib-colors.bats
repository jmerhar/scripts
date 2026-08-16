#!/usr/bin/env bats
#
# scripts/lib/colors.sh replaced six near-identical copies, which had drifted: each defined a different
# subset of one palette, and one script spelled the "no colour" flag differently from the other five.
#
# The behaviour worth pinning is what happens when colour is not wanted. Escape codes in a pipe end up in
# logs and in anything parsing the output, and under `set -o nounset` a palette variable that was never
# defined aborts the script instead — so every colour is defined empty from the start.

load ../test_helper

setup() {
  setup_common
  TOOL=$(lib_at opt/tools colour-user colors.sh)
}

# --- The palette exists before anything sets it ------------------------------------------------

# A script may print with a colour before it decides whether colour is wanted; under nounset an undefined
# one would abort rather than print plainly.
@test "every colour is defined, and empty, without calling setup_colors" {
  run_snippet "$TOOL" 'set -o nounset
    printf "[%s%s%s%s%s%s%s%s%s%s]" "${_C_RED}" "${_C_GREEN}" "${_C_BRIGHT_GREEN}" "${_C_YELLOW}" \
      "${_C_CYAN}" "${_C_MAGENTA}" "${_C_WHITE}" "${_C_DIM}" "${_C_BOLD}" "${_C_RESET}"'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- setup_colors ------------------------------------------------------------------------------

# bats never gives the script a terminal, so this is the branch every test here takes — and the one that
# matters for logs and pipes.
@test "colours stay empty when output is not a terminal" {
  run_snippet "$TOOL" 'setup_colors true; printf "[%s]" "${_C_GREEN}"'
  [ "$output" = "[]" ]
}

@test "colours stay empty when colour is refused" {
  run_snippet "$TOOL" 'setup_colors false; printf "[%s]" "${_C_GREEN}"'
  [ "$output" = "[]" ]
}

@test "the flag is an argument, so a script may name its own option whatever it likes" {
  run_snippet "$TOOL" '_opt_no_color=true; setup_colors "${_opt_no_color}"; printf "[%s]" "${_C_RED}"'
  [ "$output" = "[]" ]
  run_snippet "$TOOL" '_no_color=true; setup_colors "${_no_color}"; printf "[%s]" "${_C_RED}"'
  [ "$output" = "[]" ]
}

@test "setup_colors with no argument does not abort under nounset" {
  run_snippet "$TOOL" 'set -o nounset; setup_colors; echo survived'
  [ "$status" -eq 0 ]
  [ "$output" = "survived" ]
}

# The palette is the union of what the scripts used, so a script gaining a colour needs no change here.
@test "the palette covers every colour the scripts use" {
  run_snippet "$TOOL" 'for v in _C_RED _C_GREEN _C_BRIGHT_GREEN _C_YELLOW _C_CYAN _C_MAGENTA _C_WHITE \
      _C_DIM _C_BOLD _C_RESET; do
      declare -p "$v" >/dev/null || { echo "missing $v"; exit 1; }
    done; echo all-present'
  [ "$output" = "all-present" ]
}

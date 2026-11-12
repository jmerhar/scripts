#!/usr/bin/env bats
#
# scripts/lib/colors.sh replaced six near-identical copies, which had drifted: each defined a different
# subset of one palette, and one script spelled the "no colour" flag differently from the other five.
#
# The behaviour worth pinning is what happens when colour is turned off. Escape codes in a pipe end up in
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

# bats never gives the script a terminal, so this is the branch most tests here take — and the one that
# matters for logs and pipes.
@test "colours stay empty when output is not a terminal, even when allowed" {
  run_snippet "$TOOL" 'setup_colors false; printf "[%s]" "${_C_GREEN}"'
  [ "$output" = "[]" ]
}

@test "colours stay empty when --no-color is passed" {
  run_snippet "$TOOL" 'setup_colors true; printf "[%s]" "${_C_GREEN}"'
  [ "$output" = "[]" ]
}

########################################
# Runs a command in a pseudo-terminal, so its stdout is a terminal.
#
# The only way to see setup_colors fill the palette: outside a terminal it stays empty whatever it is
# told, which is why a test outside one cannot tell --no-color honoured from --no-color ignored. The
# library is sourced in that terminal directly rather than through run_snippet, which cannot hand its
# subprocess a terminal. util-linux's script takes the command with -c; the BSD one on macOS takes it as
# trailing arguments, and fails when its stdin is the socket bats provides, so stdin is /dev/null.
# Arguments:
#   The shell code to run.
# Outputs:
#   What it printed, as the terminal rendered it.
########################################
in_terminal() {
  if script --version >/dev/null 2>&1; then
    script -qec "bash -c $(printf '%q' "$1")" /dev/null < /dev/null
  else
    script -q /dev/null bash -c "$1" < /dev/null
  fi
}

@test "in a terminal, colours are filled in unless --no-color is passed" {
  command -v script >/dev/null || skip "script(1) is not installed"
  run in_terminal "source '$TOOL'; setup_colors false; printf 'allowed=[%q]' \"\$_C_RED\""
  [[ "$output" == *"allowed=[\$'\\E[31m']"* ]]
  run in_terminal "source '$TOOL'; setup_colors; printf 'default=[%q]' \"\$_C_RED\""
  [[ "$output" == *"default=[\$'\\E[31m']"* ]]
  run in_terminal "source '$TOOL'; setup_colors true; printf 'refused=[%q]' \"\$_C_RED\""
  [[ "$output" == *"refused=[''"* ]]
}

# The argument is each script's own --no-color flag, passed unchanged. A script that passed a "colour
# wanted" value instead would invert --no-color, and only in a terminal, where no other test looks.
@test "every script passes its --no-color flag to setup_colors" {
  local call bad=0
  while IFS= read -r call; do
    case "$call" in
      *'setup_colors "${_no_color}"'* | *'setup_colors "${_opt_no_color}"'* | *'setup_colors "${no_color}"'*) ;;
      *) echo "unexpected: $call" >&2; bad=1 ;;
    esac
  done < <(grep -rn 'setup_colors ' "$REPO_ROOT/scripts" --include='*.sh' | grep -v '/lib/' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')
  (( bad == 0 ))
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

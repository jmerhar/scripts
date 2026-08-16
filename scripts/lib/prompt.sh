# shellcheck shell=bash
#
# Reading an answer from the person at the terminal.
#
# Two shapes, because the scripts want different things and the difference is not cosmetic: one reads a line
# and treats end-of-input as an empty answer, the other reads a single keypress and passes end-of-input back
# to the caller. A script that loops over candidates needs the second — piped into it with no input, the
# first would re-prompt for ever.
#
# Sourced at development time and inlined by compile-includes.sh at build time.

# Double-source guard
if [[ "${_PROMPT_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_PROMPT_SH_LOADED="true"

# For the colour the typed answer is echoed in.
# shellcheck source=./colors.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/colors.sh"
# @include colors.sh

########################################
# Reads a whole line into _answer.
#
# End of input — a pipe with nothing in it, or Ctrl-D — yields an empty answer rather than a failure, so a
# caller that treats empty as "the default" behaves the same whether a person declined or nothing was
# connected. `|| true` is what keeps that from tripping errexit.
# Globals:
#   _answer — set to what was typed.
########################################
prompt_line() {
  printf '%s' "${_C_WHITE}"
  _answer=""
  read -r _answer || true
  printf '%s' "${_C_RESET}"
}

########################################
# Reads a single keypress into _answer, without waiting for Enter.
#
# End of input is passed back to the caller, which matters for a loop: a script asking about each of fifty
# candidates with nothing on stdin has to stop, not re-prompt fifty times. `read -s` suppresses the terminal
# echo, so the key is printed here instead — and only when one was actually read.
# Globals:
#   _answer — set to the key pressed.
# Returns:
#   0 when a key was read, non-zero at end of input.
########################################
prompt_key() {
  _answer=""
  local status=0
  read -rsn1 _answer || status=$?
  if (( status == 0 )); then
    printf '%s%s%s\n' "${_C_WHITE}" "${_answer}" "${_C_RESET}"
  fi
  return "${status}"
}

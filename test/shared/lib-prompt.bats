#!/usr/bin/env bats
#
# scripts/lib/prompt.sh holds the two ways these scripts ask a question, and the difference between them is
# what end-of-input means. prompt_line treats it as an empty answer, so a caller's default applies whether a
# person pressed Enter or nothing was connected. prompt_key passes it back, because a script looping over
# fifty candidates with nothing on stdin has to stop rather than re-prompt fifty times.
#
# Both are driven from a real subshell with stdin redirected, since that is the behaviour under test.

load ../test_helper

setup() {
  setup_common
  TOOL=$(lib_at opt/tools prompt-user prompt.sh)
}

# --- prompt_line -------------------------------------------------------------------------------

@test "prompt_line reads a whole line" {
  run_snippet "$TOOL" 'prompt_line; printf "[%s]" "${_answer}"' <<< "keep this one"
  [ "$output" = "[keep this one]" ]
}

# End of input has to read as an empty answer rather than a failure, or a piped run trips errexit before the
# caller can apply its default.
@test "prompt_line survives end of input" {
  run_snippet "$TOOL" 'set -o errexit; prompt_line; printf "[%s]" "${_answer}"' < /dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "prompt_line leaves the answer empty when the line is empty" {
  run_snippet "$TOOL" 'prompt_line; printf "[%s]" "${_answer}"' <<< ""
  [ "$output" = "[]" ]
}

# --- prompt_key --------------------------------------------------------------------------------

@test "prompt_key reads a single character without waiting for Enter" {
  run_snippet "$TOOL" 'prompt_key; printf "[%s]" "${_answer}"' <<< "yes"
  [[ "$output" == *"[y]"* ]]
}

@test "prompt_key echoes the key it read, since read -s suppresses it" {
  run_snippet "$TOOL" 'prompt_key >/dev/null; printf "[%s]" "${_answer}"' <<< "d"
  [ "$output" = "[d]" ]
}

# The property that separates it from prompt_line: a caller looping over candidates must be able to stop.
@test "prompt_key reports end of input to the caller" {
  run_snippet "$TOOL" 'if prompt_key; then echo read-something; else echo end-of-input; fi' < /dev/null
  [ "$output" = "end-of-input" ]
}

@test "prompt_key prints nothing when there was no key to read" {
  run_snippet "$TOOL" 'prompt_key || true' < /dev/null
  [ "$output" = "" ]
}

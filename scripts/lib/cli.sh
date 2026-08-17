# shellcheck shell=bash
#
# The three ways a command line can be wrong, handled once so that every script reports them alike.
#
# Not a general option parser. Each script's option table stays in its own parse_options, and each writes its
# own usage text: a generated one reads worse than a hand-written one, and a generic parser would have to
# reproduce every script's diagnostics to avoid changing them. What is shared is only the handling of the
# three ways a command line can be wrong.
#
# This library calls `show_usage`, which the calling script defines. That is the one inversion here, and it is
# deliberate: the alternative is passing the usage text in, or each script repeating log_error + show_usage +
# exit at every error site, which is what it replaces.
#
# Sourced at development time and inlined by compile-includes.sh at build time.

# Double-source guard
if [[ "${_CLI_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_CLI_SH_LOADED="true"

# For log_error.
# shellcheck source=./core.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/core.sh"
# @include core.sh

########################################
# Reports a command-line mistake, prints the usage, and exits.
#
# Together rather than separately, because a script that logged the error without the usage left the reader
# guessing, and one that printed the usage without the error buried it.
# Arguments:
#   Message describing what was wrong.
# Returns:
#   Does not return; exits 1.
########################################
die_usage() {
  log_error "$*"
  show_usage >&2
  exit 1
}

########################################
# Refuses an option that was given without its value.
#
# Called as `require_option_value "$@"` from inside the option's case arm, where "$1" is the option and "$2"
# is the value it needs — so a trailing `--lang` with nothing after it is caught before the script reads the
# next option as a language.
# Arguments:
#   The remaining command line, starting with the option itself.
# Returns:
#   Does not return when the value is missing; exits 1.
########################################
require_option_value() {
  if (( $# < 2 )) || [[ -z "$2" ]]; then
    die_usage "Option '$1' requires an argument."
  fi
}

########################################
# Refuses leftover arguments for a script that takes none.
#
# A script that silently ignored them would run with a command line its operator believes did something —
# a mistyped option, or a path where none belongs.
# Arguments:
#   Whatever is left after the options have been parsed.
# Returns:
#   Does not return when anything is left; exits 1.
########################################
reject_positionals() {
  if (( $# > 0 )); then
    die_usage "Unexpected arguments: $*"
  fi
}

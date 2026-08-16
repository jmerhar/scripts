# shellcheck shell=bash
#
# Terminal colours for the scripts that print reports.
#
# Sourced at development time and inlined by compile-includes.sh at build time.

# Double-source guard
if [[ "${_COLORS_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_COLORS_SH_LOADED="true"

# Every colour starts empty, so a script may print with them before setup_colors runs and simply get no
# colour rather than an unbound-variable error under `set -o nounset`.
_C_RED=""
_C_GREEN=""
_C_BRIGHT_GREEN=""
_C_YELLOW=""
_C_CYAN=""
_C_MAGENTA=""
_C_WHITE=""
_C_DIM=""
_C_BOLD=""
_C_RESET=""

########################################
# Fills in the colour variables, unless colour is switched off or output is not a terminal.
#
# The whole palette is defined at once rather than per script: a script that gains a colour should not have
# to add it here, and the unused ones cost nothing. Whether colour is wanted is the caller's decision, so
# it is an argument — the scripts spell that flag differently (`_no_color`, `_opt_no_color`), and reading a
# global by name from here would make the library depend on each script's naming.
#
# A pipe or a file gets no escape codes, which is what keeps them out of logs and out of anything parsing
# the output.
# Globals:
#   _C_RED, _C_GREEN, _C_BRIGHT_GREEN, _C_YELLOW, _C_CYAN, _C_MAGENTA, _C_WHITE, _C_DIM, _C_BOLD, _C_RESET
# Arguments:
#   wanted: "false" to leave the palette empty; anything else enables it. Defaults to enabled.
########################################
setup_colors() {
  local wanted="${1:-true}"

  if [[ "${wanted}" == false ]]; then
    return
  fi
  if [[ ! -t 1 ]]; then
    return
  fi

  _C_RED=$'\033[31m'
  _C_GREEN=$'\033[32m'
  _C_BRIGHT_GREEN=$'\033[92m'
  _C_YELLOW=$'\033[33m'
  _C_CYAN=$'\033[36m'
  _C_MAGENTA=$'\033[35m'
  _C_WHITE=$'\033[97m'
  _C_DIM=$'\033[2m'
  _C_BOLD=$'\033[1m'
  _C_RESET=$'\033[0m'
}

# shellcheck shell=bash
#
# Reading the awk and jq programs a script keeps beside itself.
#
# Sourced at development time and inlined by compile-includes.sh at build time, which is also what turns
# each load_program call into the program's text.

# Double-source guard
if [[ "${_PROGRAM_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_PROGRAM_SH_LOADED="true"

# For log_error, which reports a program that cannot be read.
# shellcheck source=./core.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/core.sh"
# @include core.sh

########################################
# Reads an awk or jq program stored beside the script, and prints it.
#
# A program held in a file gets syntax highlighting, is checked by bin/lint/check-programs.sh before it ever
# runs, and is not counted as never-executed bash by kcov — none of which is true of the same program
# quoted inside the script. The file is resolved against the script's own directory, the same derivation
# load_config uses, so a script invoked by any path finds its own programs.
#
# Every call site is a single line ending in an `# @embed <name>` directive, which
# bin/compile/compile-includes.sh replaces with the program text at build time. A published script therefore
# never calls this function — it is the development form of a literal — which is why it can assume the
# file sits beside the script rather than searching an install prefix the way load_config does.
#
# An absent or unreadable program is fatal rather than empty: awk and jq both accept an empty program
# and produce nothing, so returning "" would turn a packaging mistake into a script that silently
# reports no results.
# Globals:
#   None
# Arguments:
#   name: File name of the program, relative to the script's directory.
# Outputs:
#   The program text on stdout.
# Returns:
#   0 on success; exits 1 if the program cannot be read.
########################################
load_program() {
  local name="$1"
  local script_dir
  script_dir=$(cd "$(dirname "$0")" && pwd -P)
  local path="${script_dir}/${name}"

  if [[ ! -r "${path}" ]]; then
    log_error "Program file not found or not readable: ${path}"
    exit 1
  fi

  cat "${path}"
}

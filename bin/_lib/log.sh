# shellcheck shell=bash
#
# Shared logging for the bin/ tools.
#
# The timestamped format matches what every bin/ tool wrote by hand, and log_error /
# log_warning additionally emit the GitHub Actions annotation syntax when GITHUB_ACTIONS
# is set, so a failure in `make lint` or a release workflow shows up as an annotation on
# the failing step rather than buried in the log.
#
# The annotation goes to stdout, which is where the Actions runner reads workflow commands.
# That makes a tool's error output two lines under CI and one otherwise, so a test counting
# reported items must count the timestamped line rather than the message text — and a tool
# whose stdout is a data channel must redirect a child's stdout to stderr, as
# release-package.sh does around the packager it captures a commit message from.
#
# A tool sources this after setting SCRIPT_DIR:
#
#   # shellcheck source=../_lib/log.sh
#   source "${SCRIPT_DIR}/../_lib/log.sh"
#
# Globals:
#   GITHUB_ACTIONS   Read; when non-empty, log_error/log_warning emit a workflow annotation.
# Outputs:
#   log_error, log_warning, log_info write a timestamped line to stderr.

# Double-source guard, so sourcing this twice cannot redefine the functions mid-run.
if [[ "${_BIN_LOG_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_BIN_LOG_SH_LOADED="true"

#######################################
# Prints a timestamped error to stderr, and a GitHub Actions error annotation under CI.
# Arguments:
#   Message to print.
#######################################
log_error() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::$*"
  fi
  printf '[%s] [ERROR]: %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

#######################################
# Prints a timestamped warning to stderr, and a GitHub Actions warning annotation under CI.
# Arguments:
#   Message to print.
#######################################
log_warning() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::$*"
  fi
  printf '[%s] [WARNING]: %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

#######################################
# Prints a timestamped info message to stderr.
# Arguments:
#   Message to print.
#######################################
log_info() {
  printf '[%s] [INFO]: %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

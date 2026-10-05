#!/usr/bin/env bash
#
# Runs the bats suite, in parallel where that is possible.
#
# The suite is large and every test runs the code under test in a fresh subprocess, because each script
# derives its library include, SCRIPT_NAME, install prefix, config search path and usage text from $0.
# That fidelity costs a process per test and several more per library include, which makes the run
# dominated by process creation rather than by the assertions. Spreading it across cores is therefore
# worth roughly a threefold saving, and nothing else here comes close.
#
# bats needs GNU parallel to do that, and it is not part of this repository's requirements: the lint and
# CI workflows have neither. So the job count is decided here rather than fixed in a Makefile recipe —
# parallel when the tool is present, serial when it is not, and the choice reported either way. A run
# that quietly took four times as long because a dependency had gone missing would look exactly like a
# slow machine.
#
# The environment the CI runners have is applied by --ci rather than spelled out in two Makefile
# recipes, because it is the same list every caller needs and a run that differs from the gate by one
# variable is the kind of difference that only shows up in CI.
#
# Usage:
#   ./run-suite.sh [OPTIONS] [PATH]

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"

# Seams. Neither tool can be doubled on PATH under its real name: a `bats` there is picked up by the
# very suite that exercises this tool, and a `parallel` there would change how that suite runs.
: "${BATS_BIN:=bats}"
: "${PARALLEL_BIN:=parallel}"
# Pins what the core-count probe would otherwise read off the machine, so a test asserts on the
# decision rather than on however many cores it happens to have. It is not a stand-in for --jobs: the
# two take different paths, and only an explicit --jobs can ask for serial on a parallel-capable box.
: "${JOBS:=}"

_jobs=""
_ci=false
_target="test/"

########################################
# Prints the usage instructions to stdout.
# Outputs:
#   Writes usage text to stdout.
########################################
show_usage() {
  cat <<USAGE
Usage: run-suite.sh [OPTIONS] [PATH]

Run the bats suite, using every core when GNU parallel is available.

PATH is the directory or file to run, relative to the repository root
(default ${_target}).

Options:
  -j, --jobs N   Run N tests at once. 1 runs them serially. Defaults to the
                 number of cores when GNU parallel is installed, and to 1
                 when it is not.
      --ci       Also apply the environment the CI runners have, which is what
                 the commit gate uses.
  -h, --help     Show this help message.

GNU parallel is an optional dependency; without it the suite still runs, one
test at a time, and says so.
USAGE
}

########################################
# Parses command-line arguments into the globals above.
# Globals:
#   _jobs, _ci, _target
# Arguments:
#   The command line.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -j|--jobs)
        if (( $# < 2 )) || [[ -z "$2" ]]; then
          log_error "Option '$1' requires an argument."
          show_usage >&2
          exit 1
        fi
        _jobs="$2"
        shift 2
        ;;
      --ci)
        _ci=true
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        log_error "Unknown option '$1'."
        show_usage >&2
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#positional[@]} > 1 )); then
    log_error "Expected at most one path argument, got ${#positional[@]}."
    show_usage >&2
    exit 1
  fi
  if (( ${#positional[@]} == 1 )); then
    _target="${positional[0]}"
  fi

  if [[ -n "${_jobs}" && ! "${_jobs}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "The job count must be a positive whole number, got '${_jobs}'."
    show_usage >&2
    exit 1
  fi
}

########################################
# Reports whether GNU parallel is available.
# Globals:
#   PARALLEL_BIN
# Returns:
#   0 when it can be run, 1 otherwise.
########################################
have_parallel() {
  command -v "${PARALLEL_BIN}" &>/dev/null
}

########################################
# Prints how many tests to run at once.
#
# getconf answers on both GNU and BSD userlands, where nproc and sysctl each answer on only one, so no
# platform split is needed. A machine that will not say falls back to a count low enough to help on a
# laptop and not to thrash a small runner.
# Outputs:
#   The core count.
########################################
detect_jobs() {
  if [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "${JOBS}"
    return 0
  fi
  local count
  count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [[ "${count}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "${count}"
    return 0
  fi
  printf '4'
}

########################################
# Prints the job count to use, reporting why when it is not what was asked for.
# Globals:
#   _jobs
# Outputs:
#   The job count on stdout; a note on the decision to the log.
########################################
resolve_jobs() {
  if [[ -z "${_jobs}" ]]; then
    if have_parallel; then
      detect_jobs
      return 0
    fi
    log_info "GNU parallel is not installed; running one test at a time. Install it to use every core."
    printf '1'
    return 0
  fi

  if (( _jobs > 1 )) && ! have_parallel; then
    log_warning "GNU parallel is not installed, so --jobs ${_jobs} cannot be honoured; running one test at a time."
    printf '1'
    return 0
  fi
  printf '%s' "${_jobs}"
}

########################################
# Applies the environment the CI runners have.
#
# Three differences have each already turned a green local run into a failing CI one: GITHUB_ACTIONS
# makes every log_error emit an Actions annotation as well as its own line, so a test counting a message
# sees it twice; git's default branch is master on the runners, which the tests driving a bare fixture
# repository read; and the coverage entry point exports JUNIT_DIR into every test.
# Globals:
#   Exports GITHUB_ACTIONS, GIT_CONFIG_COUNT, GIT_CONFIG_KEY_0, GIT_CONFIG_VALUE_0, JUNIT_DIR.
########################################
apply_ci_environment() {
  export GITHUB_ACTIONS=true
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=init.defaultBranch
  export GIT_CONFIG_VALUE_0=master
  export JUNIT_DIR="${JUNIT_DIR:-junit}"
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   The command line.
# Returns:
#   bats's own exit status.
########################################
main() {
  parse_options "$@"

  local jobs
  jobs="$(resolve_jobs)"

  [[ "${_ci}" == true ]] && apply_ci_environment

  # Run from the repository root so that a relative target, and every path bats prints, mean the same
  # thing however the tool was invoked.
  cd "${REPO_ROOT}"

  local -a command=("${BATS_BIN}" --recursive --print-output-on-failure)
  (( jobs > 1 )) && command+=(--jobs "${jobs}")
  command+=("${_target}")

  if (( jobs > 1 )); then
    log_info "Running ${_target} with ${jobs} jobs."
  else
    log_info "Running ${_target} one test at a time."
  fi

  "${command[@]}"
}

main "$@"

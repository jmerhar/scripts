#!/usr/bin/env bash
#
# Purges the kernel packages a Debian or Ubuntu system no longer needs.
#
# Each kernel keeps an image, its modules and usually its headers, and nothing removes the old ones on a
# machine that is not short of space in /boot — so they accumulate, and an OS upgrade later has more to
# think about than it needs to.
#
# What makes this worth a script rather than a command is which packages must survive. The running
# kernel is not necessarily the newest installed one: a machine that has not rebooted since the last
# update is running the older of the two, and removing either would leave it unbootable or unable to
# boot into what it just installed. Both are kept, along with any further recent ones asked for.
#
# The packages are named individually and purged by name. `apt autoremove --purge` would find most of
# them too, and would also take whatever else it currently considers unneeded — which on a machine
# with hand-installed packages is not a list anyone has reviewed.
#
# Usage:
#   ./remove-old-kernels.sh [OPTIONS]

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../../lib/colors.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/colors.sh"
# @include ../../lib/colors.sh
# shellcheck source=../../lib/prompt.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/prompt.sh"
# @include ../../lib/prompt.sh
# shellcheck source=../../lib/cli.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/cli.sh"
# @include ../../lib/cli.sh
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
# shellcheck source=../../lib/config.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/config.sh"
# @include ../../lib/config.sh

# --- Environment seams ---
# The running kernel and the two package tools, so a test can describe a machine rather than act on one.
: "${RUNNING_KERNEL:=$(uname -r)}"
: "${DPKG_QUERY_BIN:=dpkg-query}"
: "${APT_GET_BIN:=apt-get}"
readonly RUNNING_KERNEL DPKG_QUERY_BIN APT_GET_BIN

# --- Global State (option flags) ---
_assume_yes=false
_dry_run=false
_no_color=false
_keep_opt=""

# Resolved settings, filled in by apply_config.
_keep_count=1

# Holds the most recent key entered by the user (set by prompt_key).
_answer=""

# --- Color Variables (set by setup_colors "${_no_color}") ---

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Purge the kernel packages this system no longer needs, keeping the running
kernel and the most recent installed ones.

Options:
  -k, --keep N    Keep the N most recent kernels besides the running one (default ${_keep_count}).
  -y, --yes       Purge without asking.
  -n, --dry-run   List what would be purged without purging anything.
  -C, --no-color  Disable colored output.
  -d, --debug     Enable verbose debug logging.
  -h, --help      Show this help message.

The running kernel is always kept, whether or not it is among the most recent.
Only the packages listed are purged; nothing is auto-removed alongside them.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   _keep_opt, _assume_yes, _dry_run, _no_color
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -k|--keep)
        require_option_value "$@"
        _keep_opt="$2"
        shift 2
        ;;
      -y|--yes)
        _assume_yes=true
        shift
        ;;
      -n|--dry-run)
        _dry_run=true
        shift
        ;;
      -C|--no-color)
        _no_color=true
        shift
        ;;
      -d|--debug)
        enable_debug_mode
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      -*)
        die_usage "Unknown option '$1'."
        ;;
      *)
        # Collected rather than refused here, so that a stray path is reported as the unexpected
        # argument it is rather than as an option nobody recognised.
        positional+=("$1")
        shift
        ;;
    esac
  done

  reject_positionals "${positional[@]+"${positional[@]}"}"
}

########################################
# Resolves the settings that come from either an option or the config file, the option winning.
# Globals:
#   KEEP_COUNT, _keep_opt, _keep_count
# Arguments:
#   None
# Returns:
#   0 when the settings are usable, 1 otherwise.
########################################
apply_config() {
  _keep_count="${_keep_opt:-${KEEP_COUNT:-${_keep_count}}}"

  if [[ ! "${_keep_count}" =~ ^[0-9]+$ ]]; then
    log_error "The number of kernels to keep must be a whole number, got '${_keep_count}'."
    return 1
  fi
}

########################################
# Prints the kernel versions dpkg knows about and could purge, oldest first.
#
# Only packages dpkg still holds something for are listed — installed, or removed with its
# configuration files left behind. A package dpkg merely knows the name of has nothing to purge, and
# naming one would make apt report a package that is not installed as though this script had misread the
# system.
#
# Sorted by version rather than lexically, so 6.8.0-99 comes before 6.8.0-136.
# Globals:
#   DPKG_QUERY_BIN
# Arguments:
#   None
# Outputs:
#   One kernel version per line, e.g. 6.8.0-136-generic.
########################################
installed_versions() {
  local line package status
  while IFS=' ' read -r package status; do
    [[ -n "${package}" ]] || continue
    # Held or half-configured states are as much this script's business as a clean install; only "no
    # files at all" is not.
    [[ "${status}" == i* || "${status}" == r* ]] || continue
    line="${package#linux-image-}"
    line="${line#unsigned-}"
    printf '%s\n' "${line}"
  done < <("${DPKG_QUERY_BIN}" -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-[0-9]*' 'linux-image-unsigned-[0-9]*' 2>/dev/null) | sort -uV
}

########################################
# Prints every package belonging to one kernel version that dpkg has something to purge for.
# Globals:
#   DPKG_QUERY_BIN
# Arguments:
#   version: The kernel version, e.g. 6.8.0-124-generic.
# Outputs:
#   One package name per line.
########################################
packages_for() {
  local version="$1" package status
  while IFS=' ' read -r package status; do
    [[ -n "${package}" ]] || continue
    [[ "${status}" == i* || "${status}" == r* ]] || continue
    printf '%s\n' "${package}"
  done < <("${DPKG_QUERY_BIN}" -W -f='${Package} ${db:Status-Abbrev}\n' "linux-*-${version}" "linux-*-${version%-*}" 2>/dev/null) | sort -u
}

########################################
# Prints the kernel versions to keep: the running one, and the most recent ones.
# Globals:
#   RUNNING_KERNEL, _keep_count
# Arguments:
#   Every installed version, oldest first.
# Outputs:
#   One version per line.
########################################
versions_to_keep() {
  local -a all=("$@")
  local -a keep=("${RUNNING_KERNEL}")

  local index=$(( ${#all[@]} - 1 )) taken=0
  while (( index >= 0 && taken < _keep_count )); do
    keep+=("${all[index]}")
    index=$(( index - 1 ))
    taken=$(( taken + 1 ))
  done

  printf '%s\n' "${keep[@]}" | sort -uV
}

########################################
# Prints the confirmation prompt and reads the answer.
# Globals:
#   _assume_yes, _answer, and color globals.
# Arguments:
#   count: How many packages are about to be purged.
# Returns:
#   0 to proceed, 1 otherwise.
########################################
confirm() {
  [[ "${_assume_yes}" == true ]] && return 0

  printf '\n%s' "${_C_BOLD}${_C_CYAN}Purge these ${1} package(s)? ${_C_RESET}"
  printf '%s' "${_C_DIM}[y/N] ${_C_RESET}"
  prompt_key || return 1
  printf '\n'
  [[ "${_answer}" == "y" || "${_answer}" == "Y" ]]
}

########################################
# Purges the named packages, through sudo when this is not already root.
#
# Named individually and never with --autoremove, because apt's own idea of what else is unneeded
# includes anything installed by hand and not depended upon — which is a list nobody has reviewed.
# Globals:
#   APT_GET_BIN
# Arguments:
#   The packages to purge.
# Returns:
#   apt-get's exit status.
########################################
purge_packages() {
  local -a command=()
  if [[ "${EUID}" -ne 0 ]]; then
    command+=(sudo)
  fi
  command+=("${APT_GET_BIN}" purge -y "$@")
  log_command "${command[@]}"
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 when there was nothing to do or the purge succeeded, 1 otherwise.
########################################
main() {
  parse_options "$@"
  setup_colors "${_no_color}"
  [[ "${_no_color}" == true ]] && disable_log_colors

  load_optional_config >/dev/null || exit 1
  apply_config || exit 1

  if ! command -v "${DPKG_QUERY_BIN}" &>/dev/null; then
    log_error "'${DPKG_QUERY_BIN}' was not found; this script only makes sense on a Debian or Ubuntu system."
    exit 1
  fi

  local -a installed=()
  local version
  while IFS= read -r version; do
    [[ -n "${version}" ]] && installed+=("${version}")
  done < <(installed_versions)

  if (( ${#installed[@]} == 0 )); then
    log_error "No kernel image packages found, which should not be possible on a running system."
    exit 1
  fi
  log_debug "Installed kernels: ${installed[*]}"

  local -a keep=()
  while IFS= read -r version; do
    [[ -n "${version}" ]] && keep+=("${version}")
  done < <(versions_to_keep "${installed[@]}")

  printf '%s\n' "${_C_BOLD}${_C_GREEN}Keeping:${_C_RESET}"
  for version in "${keep[@]}"; do
    local note=""
    [[ "${version}" == "${RUNNING_KERNEL}" ]] && note=" ${_C_DIM}(running)${_C_RESET}"
    printf '%s\n' "  ${_C_GREEN}${version}${_C_RESET}${note}"
  done

  local -a doomed=()
  local kept
  for version in "${installed[@]}"; do
    local skip=false
    for kept in "${keep[@]}"; do
      [[ "${version}" == "${kept}" ]] && skip=true
    done
    [[ "${skip}" == true ]] && continue
    doomed+=("${version}")
  done

  if (( ${#doomed[@]} == 0 )); then
    printf '\n%s\n' "${_C_BRIGHT_GREEN}Nothing to remove.${_C_RESET}"
    exit 0
  fi

  local -a packages=()
  local package
  for version in "${doomed[@]}"; do
    while IFS= read -r package; do
      [[ -n "${package}" ]] && packages+=("${package}")
    done < <(packages_for "${version}")
  done

  # The running kernel's own packages must never be in the list, whatever the version arithmetic did.
  # This is the assertion that a mistake above cannot get past.
  for package in "${packages[@]+"${packages[@]}"}"; do
    if [[ "${package}" == *"${RUNNING_KERNEL}"* ]]; then
      log_error "Refusing to continue: '${package}' belongs to the running kernel ${RUNNING_KERNEL}."
      exit 1
    fi
  done

  if (( ${#packages[@]} == 0 )); then
    printf '\n%s\n' "${_C_BRIGHT_GREEN}Nothing to remove: the older kernels have no packages left to purge.${_C_RESET}"
    exit 0
  fi

  printf '\n%s\n' "${_C_BOLD}${_C_YELLOW}Purging ${#packages[@]} package(s) for ${#doomed[@]} kernel(s):${_C_RESET}"
  for package in "${packages[@]}"; do
    printf '%s\n' "  ${_C_MAGENTA}${package}${_C_RESET}"
  done

  if [[ "${_dry_run}" == true ]]; then
    printf '\n%s\n' "${_C_CYAN}Dry run: nothing was purged.${_C_RESET}"
    exit 0
  fi

  if ! confirm "${#packages[@]}"; then
    printf '%s\n' "${_C_DIM}Cancelled.${_C_RESET}"
    exit 0
  fi

  if ! purge_packages "${packages[@]}"; then
    log_error "apt-get did not finish. Nothing further was attempted."
    exit 1
  fi
  printf '%s\n' "${_C_BOLD}${_C_BRIGHT_GREEN}Purged ${#packages[@]} package(s).${_C_RESET}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

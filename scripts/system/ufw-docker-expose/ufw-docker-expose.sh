#!/usr/bin/env bash
#
# ufw-docker-expose.sh — open or close external access to a Docker-published container port, using ufw
# `route` rules that do not name the container's address.
#
# Docker publishes a port by DNAT-ing it to the container, so the packet ufw sees in the FORWARD
# chain is already addressed to the container rather than to the host. A rule naming that address is
# therefore what the obvious approach produces — and it stops matching the moment the container is
# recreated on a different IP, which happens on any redeploy. External access then breaks silently
# while everything reaching the container from the LAN keeps working, so the failure looks like an
# ISP or router problem. Matching the destination *port* instead survives renumbering, because the
# publish is what preserved the port.
#
# The destination is still constrained to the private ranges container addresses are allocated from,
# and that part is not cosmetic. An unqualified `to any port N` matches every forwarded packet
# carrying that port, including traffic the host routes on behalf of something else — a VPN exit
# node, or a subnet router. Firewall front-ends commonly place their forward rules ahead of that
# routing: ufw-docker installs ufw's forward chain into DOCKER-USER, which FORWARD reaches before
# anything a VPN adds. An unqualified rule there accepts such a packet outright, and whatever the
# router still needed to do to it — most often marking it so its own NAT will match — never happens.
# The packet leaves with an unroutable source address and no reply can return. Constraining the
# destination leaves routed traffic to fall through to the rules that own it.
#
# Complements ufw-docker rather than replacing it. That project's `install` is what puts ufw's forward
# chain into DOCKER-USER, without which ufw has no say over forwarded Docker traffic and these rules are
# inert; its `allow` is the part this replaces, because it names the container's address. Its Swarm
# support and its install/check diagnostics have no equivalent here.
#
# Usage:
#   sudo ./ufw-docker-expose.sh 8080 5353/udp     # open (tcp when no protocol is given)
#   sudo ./ufw-docker-expose.sh --close 8080      # close
#   sudo ./ufw-docker-expose.sh --list            # show the forwarded allow rules
#
set -o errexit
set -o nounset
set -o pipefail

# shellcheck source=../../lib/cli.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/cli.sh"
# @include ../../lib/cli.sh
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
# shellcheck source=../../lib/config.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/config.sh"
# @include ../../lib/config.sh

# The private ranges a container address may come from. Overridable because Docker's
# `default-address-pools` is configurable, and because narrowing this is worth doing on a host that
# routes one of these ranges itself: a range carrying both containers and routed traffic gives the
# rules a wider reach than they need.
DEFAULT_SUBNETS=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16)
readonly DEFAULT_SUBNETS

# The docker CLI is named through the environment rather than called by a fixed name, so the publish
# check can be driven against a double without a second `docker` appearing earlier on PATH. Shadowing
# the real one by name is not an option here: other tooling in this repository invokes docker for real,
# to run pinned images, and would silently get the double instead. Unset, this is the real CLI.
: "${DOCKER_BIN:=docker}"
readonly DOCKER_BIN

_action="allow"
_dry_run=false
_specs=()
_subnets=()

########################################
# Print usage information.
# Globals:
#   DEFAULT_SUBNETS
########################################
show_usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [options] <port>[/tcp|/udp] ...

Opens external access to Docker-published container ports with ufw route rules that survive the
container being renumbered, and that do not match traffic this host merely routes.

Options:
  -c, --close            close the given ports instead of opening them
  -l, --list             list the forwarded allow rules and exit
  -s, --subnet <cidr>    destination range to constrain the rules to; repeatable, and
                         replaces the defaults (${DEFAULT_SUBNETS[*]})
  -n, --dry-run          show what ufw would do, changing nothing
  -d, --debug            enable debug output
  -h, --help             show this help and exit

Examples:
  sudo $(basename "$0") 8080                 # tcp 8080
  sudo $(basename "$0") 5353/udp 5353/tcp    # both protocols
  sudo $(basename "$0") --close 8080
  sudo $(basename "$0") --subnet 172.16.0.0/12 8080

Notes:
  * These are \`ufw route\` rules, which govern forwarded traffic. For a port on the HOST
    (sshd, a reverse proxy) use \`ufw allow\` instead.
  * The container must publish the port on 0.0.0.0 with matching host and container port
    numbers, and any upstream router must forward the port to this host.
EOF
}

########################################
# Abort unless running as root, which changing the firewall requires.
########################################
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "must run as root (use sudo)."
    exit 1
  fi
}

########################################
# Warn when ufw has no say over forwarded Docker traffic, which makes these rules inert.
#
# Docker's own chain ACCEPTs a published port before ufw is consulted, so ufw only governs container
# traffic once something hands DOCKER-USER off to ufw's forward chain — what `ufw-docker install`
# writes. Absent that, the rules below are added successfully and do nothing, and the port is reachable
# regardless: the one failure worth interrupting for, since a firewall tool that appears to have worked
# is worse than one that refuses.
#
# Checked rather than declared as a package dependency because ufw-docker is not packaged, so nothing
# in the .deb's Depends can express it. Advisory rather than fatal: rules may legitimately be staged
# before the hook exists, and a host may arrange the handoff under another name.
# Outputs:
#   An advisory line when the handoff is missing.
########################################
check_docker_user_hook() {
  if ! command -v iptables >/dev/null 2>&1; then
    log_debug "iptables not found; skipping the DOCKER-USER handoff check."
    return 0
  fi
  if iptables -S DOCKER-USER 2>/dev/null | grep -qE '^-A DOCKER-USER -j ufw-'; then
    log_debug "DOCKER-USER hands off to ufw; these rules will be consulted."
    return 0
  fi
  log_error "DOCKER-USER does not hand off to ufw, so these rules will be INERT and the port stays reachable regardless. Run 'ufw-docker install' first."
}

########################################
# Split "<port>[/proto]" into the PORT and PROTO globals, defaulting the protocol to tcp.
# Arguments:
#   The specification to parse.
# Outputs:
#   Sets PORT and PROTO.
# Returns:
#   Does not return on invalid input; exits 1.
########################################
parse_spec() {
  local spec="$1"
  PORT="${spec%%/*}"
  PROTO="tcp"
  if [[ "${spec}" == */* ]]; then
    PROTO="${spec##*/}"
  fi
  if [[ ! "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 )) || (( PORT > 65535 )); then
    die_usage "Invalid port in '${spec}'."
  fi
  if [[ "${PROTO}" != "tcp" && "${PROTO}" != "udp" ]]; then
    die_usage "Invalid protocol in '${spec}' (use tcp or udp)."
  fi
}

########################################
# Report whether a running container publishes the port in a way that makes an external rule useful.
#
# Advisory only, and skipped when the docker CLI is unavailable: the rule is worth adding before the
# container exists, and a host may manage the firewall without granting access to the daemon. What it
# catches is the two publishes that look right and cannot work — one bound to loopback, and one whose
# host port differs from the container port the rule will match.
# Globals:
#   DOCKER_BIN
# Arguments:
#   Port number.
# Outputs:
#   Advisory lines describing what was found.
########################################
check_published() {
  local port="$1" published
  if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
    log_debug "${DOCKER_BIN} not found; skipping the publish check for ${port}."
    return 0
  fi
  published=$("${DOCKER_BIN}" ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E ":${port}->" || true)
  if [[ -z "${published}" ]]; then
    log_info "no running container publishes ${port} yet; adding the rule anyway."
    return 0
  fi
  if grep -q "127.0.0.1:${port}->" <<<"${published}"; then
    log_error "${port} is published on 127.0.0.1 only; external access cannot work until it is published on 0.0.0.0."
    return 0
  fi
  if grep -q "0.0.0.0:${port}->" <<<"${published}" && ! grep -qE "0.0.0.0:${port}->${port}/" <<<"${published}"; then
    log_error "${port} is published from a different container port; these rules match the CONTAINER port, so republish with matching numbers."
  fi
}

########################################
# Add or remove the rules for one port across every configured subnet.
# Globals:
#   SCRIPT_NAME, _action, _subnets
# Arguments:
#   Port number.
#   Protocol.
########################################
apply_rules() {
  local port="$1" proto="$2" subnet
  for subnet in "${_subnets[@]}"; do
    if [[ "${_action}" == "allow" ]]; then
      run_ufw route allow proto "${proto}" to "${subnet}" port "${port}" \
        comment "${SCRIPT_NAME}: container port ${port}/${proto}"
    else
      run_ufw route delete allow proto "${proto}" to "${subnet}" port "${port}"
    fi
  done
}

########################################
# Run ufw, or ask ufw what it would do when --dry-run was given.
#
# Delegated to ufw's own --dry-run rather than printed here, so what is shown is the rule set ufw
# would actually write, including its own validation of the arguments.
# Globals:
#   _dry_run
# Arguments:
#   The ufw arguments.
########################################
run_ufw() {
  if [[ "${_dry_run}" == true ]]; then
    ufw --dry-run "$@"
    return 0
  fi
  ufw "$@"
}

########################################
# List the forwarded allow rules, which is where this script's rules appear.
########################################
list_rules() {
  local rules
  rules=$(ufw status numbered | grep -E 'ALLOW FWD' || true)
  if [[ -z "${rules}" ]]; then
    log_info "no forwarded allow rules."
    return 0
  fi
  printf '%s\n' "${rules}"
}

########################################
# Parse the command line.
# Globals:
#   _action, _dry_run, _specs, _subnets
# Arguments:
#   The command line.
########################################
parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c | --close) _action="delete"; shift ;;
      -l | --list) _action="list"; shift ;;
      -s | --subnet) require_option_value "$@"; _subnets+=("$2"); shift 2 ;;
      -n | --dry-run) _dry_run=true; shift ;;
      -d | --debug) enable_debug_mode; shift ;;
      -h | --help) show_usage; exit 0 ;;
      --) shift; _specs+=("$@"); break ;;
      -*) die_usage "Unknown option '$1'." ;;
      *) _specs+=("$1"); shift ;;
    esac
  done
}

########################################
# Entry point.
# Globals:
#   CONTAINER_SUBNETS, DEFAULT_SUBNETS, _action, _specs, _subnets
# Arguments:
#   The command line.
########################################
main() {
  parse_options "$@"

  # Reading the rules needs root as much as writing them does, so this covers --list too, and says so
  # in this script's terms rather than letting ufw fail further in.
  require_root

  if [[ "${_action}" == "list" ]]; then
    list_rules
    exit 0
  fi

  # Seeded before the config is read so that a config may override the defaults and a missing config
  # leaves them in place, which is what makes the setting optional without a second default elsewhere.
  CONTAINER_SUBNETS=("${DEFAULT_SUBNETS[@]}")
  # Announcement suppressed: the rules being written are the output worth reading.
  load_optional_config >/dev/null || exit 1
  validate_config array:CONTAINER_SUBNETS || exit 1

  if (( ${#_subnets[@]} == 0 )); then
    _subnets=("${CONTAINER_SUBNETS[@]}")
  fi

  if (( ${#_specs[@]} == 0 )); then
    die_usage "No ports given."
  fi

  check_docker_user_hook

  local past="opened"
  if [[ "${_action}" == "delete" ]]; then
    past="closed"
  fi

  local spec PORT PROTO
  for spec in "${_specs[@]}"; do
    parse_spec "${spec}"
    if [[ "${_action}" == "allow" ]]; then
      check_published "${PORT}"
    fi
    apply_rules "${PORT}" "${PROTO}"
    log_info "${past} ${PORT}/${PROTO} to ${_subnets[*]}"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

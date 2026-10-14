#!/usr/bin/env bash
#
# docker-live-upgrade.sh — run a command that restarts the Docker daemon, typically a package upgrade,
# and repair whatever live-restore did not carry across it.
#
# With `live-restore` enabled, restarting dockerd leaves containers running and the new daemon
# reattaches to them. Docker guarantees that only across patch releases. When it fails, the daemon
# either loses a container (it reads as stopped, and its restart policy may start a second instance) or
# leaves its process running with nothing managing it. That second case is the dangerous one: a fresh
# instance beside a still-running orphan means two processes on one data directory.
#
# So the order matters. Every running container is recorded before the command runs. Afterwards each
# one is checked: unchanged means it was restored. For the rest, any orphaned process is stopped first,
# identified by its cgroup naming the container rather than by PID alone, since a PID can be reused.
# Only then are the affected containers started or restarted, a few at a time in tier order, each batch
# waiting for its healthchecks before the next, and none before its Compose dependencies are ready.
# A container that was restored but is tied to a restarted one, by `restart: true` or by sharing its
# network namespace, is restarted after it.
#
# Usage:
#   sudo ./docker-live-upgrade.sh -- apt upgrade
#   sudo ./docker-live-upgrade.sh -- apt install --only-upgrade docker-ce containerd.io
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

# External commands are named through the environment so the suite can drive doubles without
# shadowing the real binaries by name: other tooling in this repository runs docker for real, and a
# double for kill must never be the shell builtin acting on a real PID. Unset, these are the real ones.
: "${DOCKER_BIN:=docker}"
: "${KILL_BIN:=kill}"
: "${PROC_ROOT:=/proc}"
readonly DOCKER_BIN KILL_BIN PROC_ROOT

# Seconds to wait for an orphan to exit after SIGKILL before giving up on it. Overridable for the
# same reason as the commands above: the suite exercises a process that never exits.
: "${KILL_GRACE:=10}"
readonly KILL_GRACE

# Exit codes.
readonly EXIT_RESTORED=0 EXIT_ERROR=1 EXIT_REPAIRED=2 EXIT_FAILED=3 EXIT_COMMAND_FAILED=4

_command=()

# The snapshot, keyed by full container ID.
_ids=()
declare -A _name=() _started=() _pid=() _tier=() _stop=() _project=() _service=() _depends_on=() _network=()
# Each container's dependencies among the recorded containers, as space-separated IDs.
declare -A _deps=()
# The subset of each container's dependencies it must be restarted with: depends_on entries with
# `restart: true`, and the container whose network namespace it shares.
declare -A _ties=()
# Containers in the repair not yet ready: queued, or started and still being waited on. A dependency in
# here is unsatisfied; one outside it was restored, repaired, or never needed repair.
declare -A _not_ready=()
# Containers the daemon restarted that a follower waits on, checked each round until ready or failed,
# and the time by which they must be ready.
_awaiting=()
_await_deadline=0

# Outcome of the verification and repair, as lists of container IDs.
_restored=()
_daemon_restarted=()
_orphans=()
_to_start=()
_to_restart=()
_repaired=()
_failed=()
# Containers restarted because something they are tied to was restarted; also listed in _to_restart.
_followers=()

########################################
# Print usage information.
########################################
show_usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [options] -- <command> [args...]

Runs a command that restarts the Docker daemon (usually a package upgrade) and repairs any container
that live-restore did not carry across it: orphaned processes are stopped, then affected containers
are started in tier order, a batch at a time, waiting for their healthchecks and their Compose
dependencies. Containers tied to a restarted one are restarted after it.

Options:
  -d, --debug     enable debug output
  -h, --help      show this help and exit

Examples:
  sudo $(basename "$0") -- apt upgrade
  sudo $(basename "$0") -- apt install --only-upgrade docker-ce containerd.io

Exit codes:
  0  every container was live-restored
  1  invalid arguments, not root, Docker unreachable, or live-restore disabled
  2  some containers were restarted, and all are running again
  3  some containers could not be brought back
  4  the command failed, and every container is running
EOF
}

########################################
# Abort unless running as root, which signalling another container's process requires.
########################################
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "must run as root (use sudo)."
    exit "${EXIT_ERROR}"
  fi
}

########################################
# Parse the command line.
# Globals:
#   _command
# Arguments:
#   The command line.
########################################
parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d | --debug) enable_debug_mode; shift ;;
      -h | --help) show_usage; exit 0 ;;
      --) shift; _command=("$@"); break ;;
      -*) die_usage "Unknown option '$1'." ;;
      *) die_usage "Put the command after '--', e.g. $(basename "$0") -- apt upgrade." ;;
    esac
  done
  if (( ${#_command[@]} == 0 )); then
    die_usage "No command given."
  fi
}

########################################
# Load the configuration over the defaults and validate it.
# Globals:
#   DAEMON_TIMEOUT, HEALTH_TIMEOUT, POLL_INTERVAL, BATCH_SIZE, DEFAULT_TIER, TIER_LABEL,
#   CGROUP_PARENT_TIERS, PRE_HOOK, POST_HOOK
# Returns:
#   0 when valid, 1 otherwise (the reason is logged).
########################################
load_settings() {
  # Seeded before the config is read, so a config may override any of them and a missing config
  # leaves them in place.
  DAEMON_TIMEOUT=300
  HEALTH_TIMEOUT=300
  POLL_INTERVAL=2
  BATCH_SIZE=3
  DEFAULT_TIER=50
  TIER_LABEL="docker-live-upgrade.tier"
  CGROUP_PARENT_TIERS=()
  PRE_HOOK=""
  POST_HOOK=""

  load_optional_config >/dev/null || return 1
  validate_config int:DAEMON_TIMEOUT int:HEALTH_TIMEOUT int:POLL_INTERVAL int:BATCH_SIZE int:DEFAULT_TIER TIER_LABEL || return 1

  # The label is spliced into a Go template, so it must not carry anything that could end the string.
  if [[ ! "${TIER_LABEL}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    log_error "TIER_LABEL may contain only letters, digits, '.', '_', '/' and '-', got '${TIER_LABEL}'."
    return 1
  fi

  local entry
  for entry in "${CGROUP_PARENT_TIERS[@]}"; do
    if [[ ! "${entry}" =~ ^[^=]+=[1-9][0-9]*$ ]]; then
      log_error "CGROUP_PARENT_TIERS entries must look like 'name=<tier>', got '${entry}'."
      return 1
    fi
  done
}

########################################
# Print one container's state as a single '|'-separated line.
#
# One template for every lookup, so the snapshot and every later check read the same fields the same
# way. '|' cannot appear in a container name, an ID, a status or a timestamp; the tier label's value
# could carry one, which is why the tier is validated as an integer before it is used.
#
# The template runs against the inspect JSON, where State.Health is absent for a container without a
# healthcheck and Config.StopTimeout is absent when unset. Reaching either with a field access is a
# template error, so both go through `index`, which yields nothing for a missing key; an unset value
# prints as "<no value>", as a missing label does.
#
# Then come the labels Docker Compose records: the project, the service, and depends_on as
# "service:condition:restart" entries separated by commas. The network mode is last; a container
# sharing another's network namespace reads "container:<id or name>".
# Globals:
#   DOCKER_BIN, TIER_LABEL
# Arguments:
#   Container ID.
# Outputs:
#   id|name|status|started|pid|health|tier label|cgroup parent|stop timeout|project|service|depends on|
#   network mode
# Returns:
#   Non-zero when the container does not exist.
########################################
inspect_container() {
  local format
  format='{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.StartedAt}}|{{.State.Pid}}|'
  format+='{{with index .State "Health"}}{{.Status}}{{else}}none{{end}}|'
  format+="{{index .Config.Labels \"${TIER_LABEL}\"}}|{{.HostConfig.CgroupParent}}|{{index .Config \"StopTimeout\"}}|"
  format+='{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|'
  format+='{{index .Config.Labels "com.docker.compose.depends_on"}}|{{.HostConfig.NetworkMode}}'
  "${DOCKER_BIN}" inspect --format "${format}" "$1" 2>/dev/null
}

########################################
# Resolve a container's tier: its label when that is a positive integer, else its cgroup parent's
# entry in CGROUP_PARENT_TIERS, else DEFAULT_TIER.
# Globals:
#   CGROUP_PARENT_TIERS, DEFAULT_TIER
# Arguments:
#   The tier label's value (may be empty).
#   The cgroup parent (may be empty).
# Outputs:
#   The tier.
########################################
resolve_tier() {
  local label="$1" parent="$2" entry
  if [[ "${label}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "${label}"
    return 0
  fi
  if (( ${#parent} > 0 )); then
    for entry in "${CGROUP_PARENT_TIERS[@]}"; do
      if [[ "${entry%=*}" == "${parent}" ]]; then
        printf '%s' "${entry##*=}"
        return 0
      fi
    done
  fi
  printf '%s' "${DEFAULT_TIER}"
}

########################################
# Record every running container, before anything can change.
# Globals:
#   DOCKER_BIN, _ids, _name, _started, _pid, _tier, _stop, _project, _service, _depends_on, _network
# Returns:
#   Non-zero when Docker cannot list or inspect its containers.
########################################
take_snapshot() {
  local ids id line name status started pid health label parent stop project service depends_on network
  ids=$("${DOCKER_BIN}" ps --quiet --no-trunc) || return 1
  for id in ${ids}; do
    # A container that stopped between the listing and this lookup is simply not running.
    line=$(inspect_container "${id}") || continue
    IFS='|' read -r id name status started pid health label parent stop project service depends_on network <<<"${line}"
    [[ "${status}" == "running" ]] || continue
    _ids+=("${id}")
    _name[${id}]="${name#/}"
    _started[${id}]="${started}"
    _pid[${id}]="${pid}"
    _tier[${id}]=$(resolve_tier "${label}" "${parent}")
    if [[ "${stop}" =~ ^[0-9]+$ ]]; then
      _stop[${id}]="${stop}"
    else
      _stop[${id}]=10
    fi
    _project[${id}]="${project}"
    _service[${id}]="${service}"
    _depends_on[${id}]="${depends_on}"
    _network[${id}]="${network}"
  done
  log_debug "recorded ${#_ids[@]} running containers."
}

########################################
# Work out what each recorded container depends on and what it is tied to, and warn wherever a
# container outranks its own dependency.
#
# Two things make a dependency. A Compose depends_on entry names a service, meaning that service's
# container in the same project; with `restart: true` the dependent is also tied to it, to be restarted
# whenever it is. A shared network namespace ("container:<id or name>") is both a dependency and a tie,
# since the sharer cannot start without the owner and loses its network when the owner restarts. Only
# recorded containers count: one that was not running before the command is not brought back, so
# nothing waits for it.
#
# The warning is about configuration, not this run: a container in an earlier tier than its dependency
# waits for that dependency's tier whenever both need repair, so its tier promises more than the order
# can deliver. Usually the tiers are what is wrong.
# Globals:
#   _ids, _name, _tier, _project, _service, _depends_on, _network, _deps, _ties
########################################
resolve_dependencies() {
  local id other entry service restart owner
  local -A by_service=() by_name=()
  for id in "${_ids[@]}"; do
    by_name[${_name[${id}]}]="${id}"
    if (( ${#_service[${id}]} > 0 )) && [[ "${_service[${id}]}" != "<no value>" ]]; then
      by_service["${_project[${id}]}/${_service[${id}]}"]="${id}"
    fi
  done
  for id in "${_ids[@]}"; do
    _deps[${id}]=""
    _ties[${id}]=""
    if [[ "${_depends_on[${id}]}" != "<no value>" ]]; then
      local -a entries=()
      IFS=',' read -r -a entries <<<"${_depends_on[${id}]}"
      for entry in "${entries[@]}"; do
        IFS=':' read -r service _ restart _ <<<"${entry}"
        other="${by_service["${_project[${id}]}/${service}"]:-}"
        (( ${#other} > 0 )) || continue
        add_dependency "${id}" "${other}"
        if [[ "${restart}" == true ]]; then
          _ties[${id}]+="${_ties[${id}]:+ }${other}"
        fi
      done
    fi
    if [[ "${_network[${id}]}" == container:* ]]; then
      owner="${_network[${id}]#container:}"
      other=""
      # Docker records the owner's full ID, even for `--network container:<name>`; the name is only
      # a fallback, for a daemon that keeps what it was given.
      if [[ -n "${_name[${owner}]+set}" ]]; then
        other="${owner}"
      elif [[ -n "${by_name[${owner}]+set}" ]]; then
        other="${by_name[${owner}]}"
      fi
      if (( ${#other} > 0 )); then
        add_dependency "${id}" "${other}"
        # Word-split on purpose: the value is a space-separated list of IDs.
        # shellcheck disable=SC2086
        contains "${other}" ${_ties[${id}]} || _ties[${id}]+="${_ties[${id}]:+ }${other}"
      fi
    fi
  done
}

########################################
# Record that one container depends on another, once, warning when the dependent's tier is earlier.
# Globals:
#   _deps, _name, _tier
# Arguments:
#   The dependent's ID.
#   The dependency's ID.
########################################
add_dependency() {
  local id="$1" other="$2"
  # Word-split on purpose: the value is a space-separated list of IDs.
  # shellcheck disable=SC2086
  if contains "${other}" ${_deps[${id}]}; then
    return 0
  fi
  _deps[${id}]+="${_deps[${id}]:+ }${other}"
  if (( _tier[${id}] < _tier[${other}] )); then
    log_warn "${_name[${id}]} (tier ${_tier[${id}]}) depends on ${_name[${other}]} (tier ${_tier[${other}]}), so it waits for that tier whenever both are repaired; give it tier ${_tier[${other}]} or later."
  fi
}

########################################
# Add to the repair every container tied to one that is being restarted or was restarted by the
# daemon, transitively, so it is restarted once what it is tied to is ready.
#
# Such a container may itself have been live-restored, but it holds connections to, or the network
# namespace of, an instance that no longer exists. Restarting it is what `restart: true` asks of
# Compose, and the only way a namespace sharer gets a network again. One tied to a container that no
# longer exists cannot be put right by a restart, so it is reported as failed rather than counted as
# restored.
# Globals:
#   _ids, _name, _ties, _restored, _daemon_restarted, _to_start, _to_restart, _followers, _failed
########################################
plan_followers() {
  local id tie added=true
  local -A restarting=()
  for id in "${_to_start[@]}" "${_to_restart[@]}" "${_daemon_restarted[@]}"; do
    restarting[${id}]=1
  done
  # At this point _failed holds only the containers that vanished during the command.
  local -a broken=()
  for id in "${_restored[@]}" "${_daemon_restarted[@]}"; do
    # Word-split on purpose: the value is a space-separated list of IDs.
    # shellcheck disable=SC2086
    for tie in ${_ties[${id}]:-}; do
      if contains "${tie}" "${_failed[@]}"; then
        log_error "${_name[${id}]} is tied to ${_name[${tie}]}, which no longer exists; it is still running without it."
        broken+=("${id}")
        break
      fi
    done
  done
  _failed+=("${broken[@]}")
  while [[ "${added}" == true ]]; do
    added=false
    for id in "${_restored[@]}" "${_daemon_restarted[@]}"; do
      contains "${id}" "${_followers[@]}" "${broken[@]}" && continue
      # Word-split on purpose: the value is a space-separated list of IDs.
      # shellcheck disable=SC2086
      for tie in ${_ties[${id}]:-}; do
        [[ "${tie}" != "${id}" && -n "${restarting[${tie}]:-}" ]] || continue
        log_info "${_name[${id}]} is tied to ${_name[${tie}]}, which was restarted; restarting it after."
        _followers+=("${id}")
        _to_restart+=("${id}")
        restarting[${id}]=1
        added=true
        break
      done
    done
  done
  local -a kept=()
  for id in "${_restored[@]}"; do
    contains "${id}" "${_followers[@]}" "${broken[@]}" || kept+=("${id}")
  done
  _restored=("${kept[@]}")
  kept=()
  for id in "${_daemon_restarted[@]}"; do
    contains "${id}" "${_followers[@]}" "${broken[@]}" || kept+=("${id}")
  done
  _daemon_restarted=("${kept[@]}")
}

########################################
# Report whether live-restore is enabled in the running daemon.
# Globals:
#   DOCKER_BIN
# Returns:
#   0 when enabled.
########################################
live_restore_enabled() {
  [[ "$("${DOCKER_BIN}" info --format '{{.LiveRestoreEnabled}}' 2>/dev/null)" == "true" ]]
}

########################################
# Wait for the daemon to answer again.
# Globals:
#   DOCKER_BIN, DAEMON_TIMEOUT, POLL_INTERVAL
# Returns:
#   0 once it answers, 1 on timeout.
########################################
wait_for_daemon() {
  local deadline=$(( SECONDS + DAEMON_TIMEOUT ))
  until "${DOCKER_BIN}" info --format '{{.ID}}' >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep "${POLL_INTERVAL}"
  done
}

########################################
# Run a configured hook, warning rather than stopping when it fails: a maintenance window that could
# not be opened is not a reason to abandon the upgrade or to skip the repair.
# Arguments:
#   What the hook is, for the log.
#   The hook command line (may be empty).
########################################
run_hook() {
  local what="$1" hook="$2"
  (( ${#hook} > 0 )) || return 0
  log_debug "running ${what}: ${hook}"
  if ! bash -c "${hook}"; then
    log_warn "${what} failed; continuing."
  fi
}

########################################
# Report whether a recorded container's process is still alive, outside the daemon's control.
#
# The PID alone is not proof: once the process exits, the kernel may hand the number to anything. The
# process's cgroup names the container ID, which a reused PID would not.
# Globals:
#   PROC_ROOT
# Arguments:
#   Container ID.
#   The PID recorded in the snapshot.
# Returns:
#   0 when that process is alive and belongs to the container.
########################################
is_orphan() {
  local id="$1" pid="$2"
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -r "${PROC_ROOT}/${pid}/cgroup" ]] || return 1
  grep -qF "${id}" "${PROC_ROOT}/${pid}/cgroup" 2>/dev/null
}

########################################
# Stop an orphaned container process: SIGTERM, the container's stop timeout, then SIGKILL.
# Globals:
#   KILL_BIN, KILL_GRACE, POLL_INTERVAL
# Arguments:
#   Container ID.
#   PID.
#   Seconds to allow after SIGTERM.
# Returns:
#   0 once the process is gone, 1 if it survived SIGKILL.
########################################
terminate_orphan() {
  local id="$1" pid="$2" timeout="$3" deadline signal
  for signal in TERM KILL; do
    "${KILL_BIN}" "-${signal}" "${pid}" 2>/dev/null || true
    deadline=$(( SECONDS + timeout ))
    while is_orphan "${id}" "${pid}"; do
      if (( SECONDS >= deadline )); then
        break
      fi
      sleep "${POLL_INTERVAL}"
    done
    is_orphan "${id}" "${pid}" || return 0
    timeout="${KILL_GRACE}"
  done
  return 1
}

########################################
# Compare every recorded container with its state now, and sort it into an outcome.
# Globals:
#   _ids, _name, _started, _pid, _restored, _daemon_restarted, _orphans, _to_start, _to_restart,
#   _failed
########################################
verify_containers() {
  local id line name status started pid health label parent stop
  for id in "${_ids[@]}"; do
    if ! line=$(inspect_container "${id}"); then
      log_error "${_name[${id}]} no longer exists; it cannot be restored."
      # With no container left to start, the orphan is not stopped automatically: whatever replaces the
      # container is unknown here, so the process is named for someone to decide about.
      if is_orphan "${id}" "${_pid[${id}]}"; then
        log_error "its process ${_pid[${id}]} is still running outside Docker's control."
      fi
      _failed+=("${id}")
      continue
    fi
    IFS='|' read -r id name status started pid health label parent stop _ <<<"${line}"

    if [[ "${status}" == "running" && "${started}" == "${_started[${id}]}" ]]; then
      _restored+=("${id}")
      continue
    fi

    local orphaned=false
    if [[ "${pid}" != "${_pid[${id}]}" ]] && is_orphan "${id}" "${_pid[${id}]}"; then
      orphaned=true
      _orphans+=("${id}")
    fi

    if [[ "${status}" == "running" ]]; then
      if [[ "${orphaned}" == true ]]; then
        # A second instance beside the orphan, started by the restart policy. It may have failed to
        # take its ports or data, so it is restarted once the orphan is gone.
        _to_restart+=("${id}")
      else
        _daemon_restarted+=("${id}")
      fi
    else
      _to_start+=("${id}")
    fi
  done
}

########################################
# Wait for a container to be running and, if it has a healthcheck, healthy.
# Globals:
#   HEALTH_TIMEOUT, POLL_INTERVAL
# Arguments:
#   Container ID.
# Returns:
#   0 when ready, 1 when it exited or the timeout passed.
########################################
wait_until_ready() {
  local id="$1" deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  local line name status started pid health label parent stop
  while true; do
    line=$(inspect_container "${id}") || return 1
    IFS='|' read -r id name status started pid health label parent stop _ <<<"${line}"
    case "${status}" in
      running)
        if [[ "${health}" == "none" || "${health}" == "healthy" ]]; then
          return 0
        fi
        ;;
      exited | dead) return 1 ;;
    esac
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep "${POLL_INTERVAL}"
  done
}

########################################
# Report whether an ID is in a list.
# Arguments:
#   The ID.
#   The list.
# Returns:
#   0 when present.
########################################
contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

########################################
# Stop every orphan, then start or restart the affected containers in tier order, BATCH_SIZE at a
# time, each batch waiting for its containers to be ready before the next begins. A container never
# starts before its Compose dependencies are ready, whatever its tier, and one whose dependency failed,
# or whose dependencies form a cycle, is not started at all.
#
# Orphans go first and all together: until one is gone, starting its container could put two
# processes on one data directory. A container whose orphan survives is not started at all.
# Globals:
#   DOCKER_BIN, BATCH_SIZE, _name, _pid, _stop, _tier, _orphans, _to_start, _to_restart,
#   _repaired, _failed, _not_ready
########################################
repair_containers() {
  local id
  local -a unkillable=()
  for id in "${_orphans[@]}"; do
    log_warn "stopping orphaned process ${_pid[${id}]} of ${_name[${id}]}."
    if ! terminate_orphan "${id}" "${_pid[${id}]}" "${_stop[${id}]}"; then
      log_error "process ${_pid[${id}]} of ${_name[${id}]} survived SIGKILL; leaving the container alone."
      unkillable+=("${id}")
      _failed+=("${id}")
    fi
  done

  # A container the daemon restarted is in no round, so nothing would wait for it, and a follower tied
  # to one would restart at once against a dependency that may still be starting. Each such container
  # counts as not ready until a round's check finds it ready, so only its followers wait for it.
  local tie
  _awaiting=()
  _await_deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  for id in "${_followers[@]}"; do
    # Word-split on purpose: the value is a space-separated list of IDs.
    # shellcheck disable=SC2086
    for tie in ${_ties[${id}]:-}; do
      if contains "${tie}" "${_daemon_restarted[@]}" && ! contains "${tie}" "${_awaiting[@]}"; then
        _awaiting+=("${tie}")
        _not_ready[${tie}]=1
      fi
    done
  done

  # One line per container, "tier name id action", sorted so tiers run in order and a tier runs in a
  # stable order.
  local -a plan=()
  for id in "${_to_start[@]}"; do
    contains "${id}" "${unkillable[@]}" || plan+=("${_tier[${id}]} ${_name[${id}]} ${id} start")
  done
  for id in "${_to_restart[@]}"; do
    contains "${id}" "${unkillable[@]}" || plan+=("${_tier[${id}]} ${_name[${id}]} ${id} restart")
  done
  (( ${#plan[@]} > 0 )) || return 0

  local entry tier name action state
  local -a pending=()
  mapfile -t pending < <(printf '%s\n' "${plan[@]}" | sort -k1,1n -k2,2)
  for entry in "${pending[@]}"; do
    read -r tier name id action <<<"${entry}"
    _not_ready[${id}]=1
  done

  # Rounds: each takes, in order, up to BATCH_SIZE containers of one tier whose dependencies are all
  # satisfied, starts them, and waits for them. A container whose dependency is not ready waits for a
  # later round, which is what keeps a dependency and its dependent out of one batch.
  while (( ${#pending[@]} > 0 )); do
    check_awaited
    local -a batch=() remaining=()
    local batch_tier="" progressed=false
    for entry in "${pending[@]}"; do
      read -r tier name id action <<<"${entry}"
      state=$(dependency_state "${id}")
      if [[ "${state}" == failed:* ]]; then
        if contains "${id}" "${_followers[@]}"; then
          log_error "not restarting ${name}: ${state#failed:}, which it is tied to, could not be brought back; it is still running."
        else
          log_error "not ${action}ing ${name}: its dependency ${state#failed:} could not be brought back."
        fi
        _failed+=("${id}")
        unset "_not_ready[${id}]"
        progressed=true
        continue
      fi
      if [[ "${state}" == waiting ]] || (( ${#batch[@]} >= BATCH_SIZE )) || [[ -n "${batch_tier}" && "${tier}" != "${batch_tier}" ]]; then
        remaining+=("${entry}")
        continue
      fi
      batch_tier="${tier}"
      progressed=true
      log_info "${action}ing ${name} (tier ${tier})."
      if "${DOCKER_BIN}" "${action}" "${id}" >/dev/null </dev/null; then
        batch+=("${id}")
      else
        log_error "could not ${action} ${name}."
        _failed+=("${id}")
        unset "_not_ready[${id}]"
      fi
    done
    await_batch "${batch[@]}"
    for id in "${batch[@]}"; do
      unset "_not_ready[${id}]"
    done
    pending=("${remaining[@]}")
    if [[ "${progressed}" == false ]]; then
      if (( ${#_awaiting[@]} > 0 )); then
        # Nothing could start yet, but a container the daemon restarted may still become ready.
        sleep "${POLL_INTERVAL}"
        continue
      fi
      # Everything left waits on something else left: a dependency cycle.
      for entry in "${pending[@]}"; do
        read -r tier name id action <<<"${entry}"
        log_error "not ${action}ing ${name}: its dependencies form a cycle."
        _failed+=("${id}")
      done
      break
    fi
  done

  local -a kept=()
  for id in "${_daemon_restarted[@]}"; do
    contains "${id}" "${_failed[@]}" || kept+=("${id}")
  done
  _daemon_restarted=("${kept[@]}")
}

########################################
# Check, without waiting, each container the daemon restarted that a follower is waiting on. One
# that is running and, if it has a healthcheck, healthy stops counting as not ready. One that exited
# or is gone is recorded as failed at once; anything else, such as `restarting` while its restart
# policy backs off a crash at startup, is checked again until HEALTH_TIMEOUT after the repair began,
# as wait_until_ready does.
# Globals:
#   _awaiting, _await_deadline, _failed, _name, _not_ready, HEALTH_TIMEOUT
########################################
check_awaited() {
  (( ${#_awaiting[@]} > 0 )) || return 0
  local tie line name status started pid health label parent stop
  local -a still=()
  for tie in "${_awaiting[@]}"; do
    status=gone health=none
    if line=$(inspect_container "${tie}"); then
      IFS='|' read -r _ name status started pid health label parent stop _ <<<"${line}"
    fi
    if [[ "${status}" == running && ( "${health}" == none || "${health}" == healthy ) ]]; then
      unset "_not_ready[${tie}]"
      continue
    fi
    case "${status}" in
      exited | dead | gone)
        log_error "${_name[${tie}]}, restarted by the daemon, ${status/gone/no longer exists}."
        ;;
      *)
        if (( SECONDS < _await_deadline )); then
          still+=("${tie}")
          continue
        fi
        log_error "${_name[${tie}]}, restarted by the daemon, is not running and healthy after ${HEALTH_TIMEOUT}s."
        ;;
    esac
    _failed+=("${tie}")
    unset "_not_ready[${tie}]"
  done
  _awaiting=("${still[@]}")
}

########################################
# Report whether a container's dependencies allow it to start.
# Globals:
#   _deps, _failed, _name, _not_ready
# Arguments:
#   Container ID.
# Outputs:
#   "ready", "waiting", or "failed:<name of the failed dependency>".
########################################
dependency_state() {
  local id="$1" dep
  local -a deps=()
  read -r -a deps <<<"${_deps[${id}]:-}"
  for dep in "${deps[@]}"; do
    if contains "${dep}" "${_failed[@]}"; then
      printf 'failed:%s' "${_name[${dep}]}"
      return 0
    fi
  done
  for dep in "${deps[@]}"; do
    if [[ -n "${_not_ready[${dep}]:-}" ]]; then
      printf 'waiting'
      return 0
    fi
  done
  printf 'ready'
}

########################################
# Wait for every container in a batch to be ready, recording each as repaired or failed.
# Globals:
#   _name, _repaired, _failed
# Arguments:
#   Container IDs (may be none).
########################################
await_batch() {
  local id
  for id in "$@"; do
    if wait_until_ready "${id}"; then
      _repaired+=("${id}")
    else
      log_error "${_name[${id}]} is not running and healthy after ${HEALTH_TIMEOUT}s."
      _failed+=("${id}")
    fi
  done
}

########################################
# Print the names of a list of containers, comma-separated.
# Globals:
#   _name
# Arguments:
#   Container IDs.
# Outputs:
#   The names.
########################################
names_of() {
  local id out=""
  for id in "$@"; do
    out+="${out:+, }${_name[${id}]}"
  done
  printf '%s' "${out}"
}

########################################
# Entry point.
# Globals:
#   _command, _ids, _restored, _daemon_restarted, _repaired, _failed, POST_HOOK, PRE_HOOK
# Arguments:
#   The command line.
########################################
main() {
  parse_options "$@"
  require_root
  load_settings || exit "${EXIT_ERROR}"

  # A durable record of what was repaired, since the run often happens in a terminal nobody keeps. From
  # a working tree default_log_file names nothing, so only an installed copy writes one.
  LOG_FILE="${LOG_FILE:-$(default_log_file)}"

  if ! "${DOCKER_BIN}" info --format '{{.ID}}' >/dev/null 2>&1; then
    log_error "the Docker daemon is not reachable."
    exit "${EXIT_ERROR}"
  fi
  if ! live_restore_enabled; then
    log_error "live-restore is disabled, so restarting the daemon stops every container. Set \"live-restore\": true in /etc/docker/daemon.json and run 'systemctl reload docker'."
    exit "${EXIT_ERROR}"
  fi

  # Before the pre-hook, so that no exit between the two hooks can leave a window it opened unclosed.
  if ! take_snapshot; then
    log_error "could not list the running containers."
    exit "${EXIT_ERROR}"
  fi
  resolve_dependencies

  run_hook "PRE_HOOK" "${PRE_HOOK}"

  # Ctrl-C reaches the whole foreground process group, so without a trap it would end this script along
  # with the command, skipping the check exactly when an interrupted upgrade may already have restarted
  # the daemon. A trap that runs a command is reset to the default in children, so the command itself
  # is still interrupted as usual. The handler only sets a flag: in bash 5.2 a bare `return` in a
  # function called from a handler yields the status from before the trap, here the command's 130, so a
  # logger returning early would end the script under errexit.
  local command_status=0 interrupted=false
  trap 'interrupted=true' INT
  "${_command[@]}" || command_status=$?
  trap - INT
  if [[ "${interrupted}" == true ]]; then
    log_warn "interrupted; checking the containers anyway."
  fi
  if (( command_status != 0 )); then
    log_error "'${_command[*]}' exited with status ${command_status}; checking the containers anyway."
  fi

  local result summary code
  if ! wait_for_daemon; then
    summary="the Docker daemon did not come back within ${DAEMON_TIMEOUT}s"
    log_error "${summary}."
    export DOCKER_LIVE_UPGRADE_RESULT=failed DOCKER_LIVE_UPGRADE_SUMMARY="${summary}"
    run_hook "POST_HOOK" "${POST_HOOK}"
    exit "${EXIT_FAILED}"
  fi

  verify_containers
  plan_followers
  if (( ${#_daemon_restarted[@]} > 0 )); then
    log_warn "restarted by the daemon: $(names_of "${_daemon_restarted[@]}")."
  fi
  repair_containers

  summary="${#_restored[@]} of ${#_ids[@]} containers live-restored"
  (( ${#_daemon_restarted[@]} == 0 )) || summary+="; restarted by the daemon: $(names_of "${_daemon_restarted[@]}")"
  (( ${#_repaired[@]} == 0 )) || summary+="; repaired: $(names_of "${_repaired[@]}")"
  (( ${#_failed[@]} == 0 )) || summary+="; FAILED: $(names_of "${_failed[@]}")"
  (( command_status == 0 )) || summary+="; the command exited with status ${command_status}"

  if (( ${#_failed[@]} > 0 )); then
    result=failed code="${EXIT_FAILED}"
    log_error "${summary}."
  elif (( command_status != 0 )); then
    result=command-failed code="${EXIT_COMMAND_FAILED}"
    log_error "${summary}."
  elif (( ${#_daemon_restarted[@]} + ${#_repaired[@]} > 0 )); then
    result=repaired code="${EXIT_REPAIRED}"
    log_warn "${summary}."
  else
    result=restored code="${EXIT_RESTORED}"
    log_info "${summary}."
  fi

  export DOCKER_LIVE_UPGRADE_RESULT="${result}" DOCKER_LIVE_UPGRADE_SUMMARY="${summary}"
  run_hook "POST_HOOK" "${POST_HOOK}"
  exit "${code}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

#!/usr/bin/env bats
#
# This script decides which containers to leave alone, which processes to signal, and in what order to
# start things, so those decisions are what is tested: a restored container is never touched, an
# orphan is always stopped before its container is started, a reused PID is never signalled, tiers and
# batches run in order, and every outcome maps to its exit code.
#
# Docker is a stateful double reached through DOCKER_BIN: containers live as one line each under
# $FAKE/state, in the same '|'-separated shape the script's inspect template produces, and the wrapped
# "upgrade" is a script that rewrites them. Container processes live under a fake PROC_ROOT, and kill
# is a double reached through KILL_BIN that removes them. KILL_BIN is set for every test and the fake
# PIDs are above any real pid_max, so no test can signal a real process. Every double logs to
# STUB_CALLS, and order assertions read line numbers from that log.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/docker-live-upgrade/docker-live-upgrade.sh"
  FAKE="$BATS_TEST_TMPDIR/fake"
  PROC="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$FAKE/state" "$PROC"
  export FAKE PROC
  CONF="$BATS_TEST_TMPDIR/docker-live-upgrade.conf"
  printf 'POLL_INTERVAL=1\n' > "$CONF"
  printf 'true' > "$FAKE/live-restore"
  printf '# no change\n' > "$FAKE/upgrade.sh"
  write_docker_double
  write_kill_double
}

########################################
# Writes the docker double. It answers exactly the calls the script makes: info, ps, inspect, start
# and restart. start and restart give the container a new start time, a new PID and a healthy status,
# unless a fixture under $FAKE says the start fails, the container exits, or it never becomes healthy.
# ps fails when $FAKE/ps-fails exists.
########################################
write_docker_double() {
  cat > "$BATS_TEST_TMPDIR/docker-double" <<'DOUBLE'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_CALLS"
case "$1" in
  info)
    [[ -e "$FAKE/daemon-down" ]] && exit 1
    if [[ "$*" == *LiveRestoreEnabled* ]]; then cat "$FAKE/live-restore"; else echo ID; fi
    ;;
  ps)
    [[ -e "$FAKE/ps-fails" ]] && exit 1
    for f in "$FAKE/state"/*; do
      [[ -e "$f" ]] || continue
      IFS='|' read -r id _ status _ <"$f"
      [[ "$status" == running ]] && echo "$id"
    done
    ;;
  inspect)
    f="$FAKE/state/${*: -1}"
    [[ -e "$f" ]] || exit 1
    cat "$f"
    ;;
  start | restart)
    id="$2" f="$FAKE/state/$2"
    [[ -e "$FAKE/fail-start-$id" ]] && exit 1
    IFS='|' read -r id name _ _ _ health label parent stop compose <"$f"
    if [[ -e "$FAKE/unhealthy-$id" ]]; then health=unhealthy; elif [[ "$health" != none ]]; then health=healthy; fi
    state=running
    [[ -e "$FAKE/exits-$id" ]] && state=exited
    printf '%s|%s|%s|restarted|9999800|%s|%s|%s|%s|%s\n' "$id" "$name" "$state" "$health" "$label" "$parent" "$stop" "${compose:-<no value>|<no value>|<no value>}" >"$f"
    echo "$id"
    ;;
esac
exit 0
DOUBLE
  chmod +x "$BATS_TEST_TMPDIR/docker-double"
}

########################################
# Writes the kill double: SIGTERM removes the fake process unless $FAKE/ignores-term-<pid> exists, and
# SIGKILL removes it unless $FAKE/unkillable-<pid> exists.
########################################
write_kill_double() {
  cat > "$BATS_TEST_TMPDIR/kill-double" <<'DOUBLE'
#!/usr/bin/env bash
printf 'kill %s\n' "$*" >> "$STUB_CALLS"
pid="$2"
case "$1" in
  -TERM) [[ -e "$FAKE/ignores-term-$pid" ]] || rm -rf "${PROC:?}/$pid" ;;
  -KILL) [[ -e "$FAKE/unkillable-$pid" ]] || rm -rf "${PROC:?}/$pid" ;;
esac
DOUBLE
  chmod +x "$BATS_TEST_TMPDIR/kill-double"
}

########################################
# Writes a container's current state.
# Arguments:
#   id, name, status, started, pid, then optionally health (default healthy), tier label, cgroup
#   parent, stop timeout, Compose project, Compose service, Compose depends_on. An absent label or stop
#   timeout reads "<no value>", as real Docker prints it.
########################################
container() {
  printf '%s|/%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "${6:-healthy}" "${7:-<no value>}" "${8:-}" "${9:-<no value>}" "${10:-<no value>}" "${11:-<no value>}" "${12:-<no value>}" > "$FAKE/state/$1"
}

########################################
# Marks a container as lost by the daemon: exited, keeping every other field, as the wrapped upgrade.
# Arguments:
#   Container IDs.
########################################
lost_in_upgrade() {
  local id
  for id in "$@"; do
    printf 'IFS="|" read -r id n s st p h rest <"$FAKE/state/%s"; printf "%%s|%%s|exited|%%s|0|%%s|%%s\\n" "$id" "$n" "$st" "$h" "$rest" >"$FAKE/state/%s"\n' "$id" "$id"
  done > "$FAKE/upgrade.sh"
}

########################################
# Makes a fake process alive under PROC_ROOT, belonging to the named container.
# Arguments:
#   pid, container id.
########################################
process() {
  mkdir -p "$PROC/$1"
  printf '0::/system.slice/docker-%s.scope\n' "$2" > "$PROC/$1/cgroup"
}

########################################
# Sets what the wrapped upgrade does, as a bash snippet run when the script runs its command. The
# helpers above are not available inside it, so it writes state lines directly.
# Arguments:
#   The snippet.
########################################
upgrade_does() {
  printf '%s\n' "$1" > "$FAKE/upgrade.sh"
}

########################################
# Runs main as though root, with the doubles and the fixture config.
#
# EUID is not assignable, so require_root is replaced for the run; the refusal is asserted
# separately, unpatched. Extra arguments go before the command.
########################################
dlu_run() {
  CONFIG_FILE="$CONF" DOCKER_BIN="$BATS_TEST_TMPDIR/docker-double" KILL_BIN="$BATS_TEST_TMPDIR/kill-double" PROC_ROOT="$PROC" KILL_GRACE=1 run_snippet "$SCRIPT" "
    require_root() { :; }
    main $* -- bash \"\$FAKE/upgrade.sh\"
  "
}

########################################
# Prints the line number of the first call-log entry matching a basic regular expression.
# Arguments:
#   The pattern.
########################################
call_line() {
  grep -n -- "$1" "$STUB_CALLS" | head -1 | cut -d: -f1
}

########################################
# Prints how many call-log entries match a basic regular expression.
#
# Negative assertions are written as a count compared with zero, never as a negated grep: bats runs
# tests under errexit, and a negated command is exempt from it, so it fails a test only as its last
# line and passes silently anywhere else.
# Arguments:
#   The pattern.
########################################
count_calls() {
  grep -c -- "$1" "$STUB_CALLS" || true
}

########################################
# Skips the calling test when running as root, for the assertions about refusing non-root.
########################################
require_non_root() {
  [ "${EUID:-$(id -u)}" -ne 0 ] || skip "asserts the non-root refusal; this run is root"
}

# --- Usage and refusals ------------------------------------------------------------------------

@test "-h prints the usage and succeeds" {
  run_script "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"-- <command>"* ]]
}

@test "no command is a usage error" {
  run_script "$SCRIPT" --
  [ "$status" -eq 1 ]
  [[ "$output" == *"No command given"* ]]
}

@test "a command without '--' is a usage error" {
  run_script "$SCRIPT" apt upgrade
  [ "$status" -eq 1 ]
  [[ "$output" == *"Put the command after '--'"* ]]
}

@test "an unknown option is a usage error" {
  run_script "$SCRIPT" --nope -- true
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "refuses to run as a non-root user" {
  require_non_root
  DOCKER_BIN="$BATS_TEST_TMPDIR/docker-double" run_script "$SCRIPT" -- touch "$FAKE/ran"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must run as root"* ]]
  [ ! -e "$FAKE/ran" ]
}

@test "an unreachable daemon stops the run before the command" {
  touch "$FAKE/daemon-down"
  upgrade_does 'touch "$FAKE/ran"'
  dlu_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"not reachable"* ]]
  [ ! -e "$FAKE/ran" ]
}

@test "disabled live-restore stops the run before the command" {
  printf 'false' > "$FAKE/live-restore"
  upgrade_does 'touch "$FAKE/ran"'
  dlu_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"live-restore is disabled"* ]]
  [ ! -e "$FAKE/ran" ]
}

@test "a container listing Docker refuses stops the run before the command and both hooks" {
  printf 'PRE_HOOK='\''touch "$FAKE/pre"'\''\nPOST_HOOK='\''touch "$FAKE/post"'\''\n' >> "$CONF"
  touch "$FAKE/ps-fails"
  upgrade_does 'touch "$FAKE/ran"'
  dlu_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not list the running containers"* ]]
  [ ! -e "$FAKE/ran" ]
  [ ! -e "$FAKE/pre" ]
  [ ! -e "$FAKE/post" ]
}

@test "--debug reports how many containers were recorded" {
  container aaa web running t1 9999901
  dlu_run --debug
  [ "$status" -eq 0 ]
  [[ "$output" == *"recorded 1 running containers"* ]]
}

@test "an invalid TIER_LABEL is rejected before the command" {
  printf 'TIER_LABEL="x\\"}}"\n' >> "$CONF"
  upgrade_does 'touch "$FAKE/ran"'
  dlu_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"TIER_LABEL may contain only"* ]]
  [ ! -e "$FAKE/ran" ]
}

@test "a malformed CGROUP_PARENT_TIERS entry is rejected" {
  printf 'CGROUP_PARENT_TIERS=(system-crit.slice)\n' >> "$CONF"
  dlu_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"name=<tier>"* ]]
}

@test "a non-integer timeout is rejected" {
  printf 'HEALTH_TIMEOUT=soon\n' >> "$CONF"
  dlu_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"HEALTH_TIMEOUT must be a positive integer"* ]]
}

# --- Restored containers -----------------------------------------------------------------------

@test "containers live-restored are left alone and the run succeeds" {
  container aaa web running t1 9999901
  container bbb db running t2 9999902
  upgrade_does 'true'
  dlu_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 of 2 containers live-restored"* ]]
  [ "$(count_calls '^docker \(start\|restart\)\|^kill ')" -eq 0 ]
}

@test "containers not running before the command are not checked or started" {
  container aaa web running t1 9999901
  container ccc old exited t0 0
  dlu_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 of 1 containers live-restored"* ]]
  [ "$(count_calls '^docker start ')" -eq 0 ]
}

@test "the command's failure is reported with exit 4 when every container is fine" {
  container aaa web running t1 9999901
  upgrade_does 'exit 7'
  dlu_run
  [ "$status" -eq 4 ]
  [[ "$output" == *"exited with status 7"* ]]
  [[ "$output" == *"1 of 1 containers live-restored"* ]]
}

@test "Ctrl-C during the command still checks and repairs the containers" {
  container aaa web running t1 9999901
  # A terminal's Ctrl-C signals the whole foreground group: the script, and the command, which dies of it.
  upgrade_does 'printf "aaa|/web|exited|t1|0|none|<no value>||<no value>\n" > "$FAKE/state/aaa"
kill -INT "$PPID"; kill -INT $$'
  # SIGINT_DEFAULT: a parallel runner starts jobs with SIGINT ignored, which no shell can undo.
  SIGINT_DEFAULT=1 dlu_run
  [ "$status" -eq 4 ]
  [[ "$output" == *"interrupted; checking the containers anyway"* ]]
  stub_called 'docker start aaa'
}

# --- Lost containers ---------------------------------------------------------------------------

@test "a container the daemon restarted itself is reported, not touched" {
  container aaa web running t1 9999901
  upgrade_does 'printf "aaa|/web|running|t9|9999950|healthy|<no value>||<no value>\n" > "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 2 ]
  [[ "$output" == *"restarted by the daemon: web"* ]]
  [ "$(count_calls '^docker \(start\|restart\)\|^kill ')" -eq 0 ]
}

@test "a container lost by the daemon is started and the run reports a repair" {
  container aaa web running t1 9999901
  upgrade_does 'printf "aaa|/web|exited|t1|0|none|<no value>||<no value>\n" > "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 2 ]
  stub_called 'docker start aaa'
  [[ "$output" == *"repaired: web"* ]]
}

@test "an orphaned process is stopped before its container is started" {
  container aaa db running t1 9999901
  process 9999901 aaa
  upgrade_does 'printf "aaa|/db|exited|t1|0|none|<no value>||<no value>\n" > "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 2 ]
  [ "$(call_line '^kill -TERM 9999901')" -lt "$(call_line '^docker start aaa')" ]
  [ ! -e "$PROC/9999901" ]
}

@test "a second instance beside an orphan is restarted once the orphan is gone" {
  container aaa db running t1 9999901
  process 9999901 aaa
  upgrade_does 'printf "aaa|/db|running|t9|9999950|starting|<no value>||<no value>\n" > "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 2 ]
  [ "$(call_line '^kill -TERM 9999901')" -lt "$(call_line '^docker restart aaa')" ]
  [[ "$output" != *"restarted by the daemon"* ]]
}

@test "a reused PID belonging to something else is never signalled" {
  container aaa db running t1 9999901
  mkdir -p "$PROC/9999901"
  printf '0::/user.slice/session-1.scope\n' > "$PROC/9999901/cgroup"
  upgrade_does 'printf "aaa|/db|exited|t1|0|none|<no value>||<no value>\n" > "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 2 ]
  [ "$(count_calls '^kill ')" -eq 0 ]
  stub_called 'docker start aaa'
}

@test "an orphan that ignores SIGTERM gets SIGKILL after the container's stop timeout" {
  container aaa db running t1 9999901 healthy "" "" 1
  process 9999901 aaa
  touch "$FAKE/ignores-term-9999901"
  upgrade_does 'printf "aaa|/db|exited|t1|0|none|||1\n" > "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 2 ]
  [ "$(call_line '^kill -TERM 9999901')" -lt "$(call_line '^kill -KILL 9999901')" ]
  [ "$(call_line '^kill -KILL 9999901')" -lt "$(call_line '^docker start aaa')" ]
}

@test "a container whose orphan survives SIGKILL is not started, and the run fails" {
  container aaa db running t1 9999901 healthy "" "" 1
  container bbb web running t2 9999902
  process 9999901 aaa
  touch "$FAKE/ignores-term-9999901" "$FAKE/unkillable-9999901"
  upgrade_does 'printf "aaa|/db|exited|t1|0|none|||1\n" > "$FAKE/state/aaa"
printf "bbb|/web|exited|t2|0|none|<no value>||<no value>\n" > "$FAKE/state/bbb"'
  dlu_run
  [ "$status" -eq 3 ]
  [ "$(count_calls '^docker start aaa')" -eq 0 ]
  stub_called 'docker start bbb'
  [[ "$output" == *"FAILED: db"* ]]
}

# --- Order ------------------------------------------------------------------------------------

@test "containers are started by tier: label, then cgroup parent, then the default" {
  printf 'CGROUP_PARENT_TIERS=(crit.slice=10 bulk.slice=90)\n' >> "$CONF"
  container a1 bulky running t 9999901 healthy "" bulk.slice
  container a2 plain running t 9999902
  container a3 critical running t 9999903 healthy "" crit.slice
  container a4 labelled running t 9999904 healthy 5 bulk.slice
  upgrade_does 'for f in "$FAKE"/state/*; do IFS="|" read -r id name s st p h l c t <"$f"
printf "%s|%s|exited|%s|0|none|%s|%s|%s\n" "$id" "$name" "$st" "$l" "$c" "$t" >"$f"; done'
  dlu_run
  [ "$status" -eq 2 ]
  [ "$(call_line '^docker start a4')" -lt "$(call_line '^docker start a3')" ]
  [ "$(call_line '^docker start a3')" -lt "$(call_line '^docker start a2')" ]
  [ "$(call_line '^docker start a2')" -lt "$(call_line '^docker start a1')" ]
}

@test "a tier label that is not an integer falls back to the cgroup parent's tier" {
  run_snippet "$SCRIPT" '
    CGROUP_PARENT_TIERS=(crit.slice=10) DEFAULT_TIER=50
    printf "%s %s %s\n" "$(resolve_tier high crit.slice)" "$(resolve_tier 7 crit.slice)" "$(resolve_tier "" other)"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "10 7 50" ]
}

@test "a batch is waited on before the next batch in the same tier starts" {
  printf 'BATCH_SIZE=2\n' >> "$CONF"
  # Within a tier containers start in name order, so the names fix the batches: [a b], then [c].
  container a1 a running t 9999901
  container a2 b running t 9999902
  container a3 c running t 9999903
  upgrade_does 'for f in "$FAKE"/state/*; do IFS="|" read -r id name rest <"$f"
printf "%s|%s|exited|t|0|healthy|<no value>||<no value>\n" "$id" "$name" >"$f"; done'
  dlu_run
  [ "$status" -eq 2 ]
  local start3 last_wait
  start3=$(call_line '^docker start a3')
  last_wait=$(grep -n '^docker inspect .* a2$' "$STUB_CALLS" | tail -1 | cut -d: -f1)
  [ "$(call_line '^docker start a2')" -lt "$start3" ]
  [ "$last_wait" -lt "$start3" ]
}

# --- Dependencies -----------------------------------------------------------------------------

@test "a container waits for its dependency even when its own tier is earlier, and that is warned about" {
  container n1 db running t 9999901 healthy 90 "" "" shop db
  container e1 api running t 9999902 healthy 50 "" "" shop api "db:service_healthy:false"
  lost_in_upgrade n1 e1
  dlu_run
  [ "$status" -eq 2 ]
  [[ "$output" == *"api (tier 50) depends on db (tier 90)"* ]]
  local ready
  ready=$(grep -n '^docker inspect .* n1$' "$STUB_CALLS" | tail -1 | cut -d: -f1)
  [ "$(call_line '^docker start n1')" -lt "$(call_line '^docker start e1')" ]
  [ "$ready" -lt "$(call_line '^docker start e1')" ]
}

@test "a container waiting on a dependency does not hold back ready containers in later tiers" {
  container n1 db running t 9999901 healthy 90 "" "" shop db
  container e1 api running t 9999902 healthy 50 "" "" shop api "db:service_healthy:false"
  container w1 web running t 9999903 healthy 60
  lost_in_upgrade n1 e1 w1
  dlu_run
  [ "$status" -eq 2 ]
  [ "$(call_line '^docker start w1')" -lt "$(call_line '^docker start n1')" ]
  [ "$(call_line '^docker start n1')" -lt "$(call_line '^docker start e1')" ]
}

@test "a container whose dependency could not be started is not started either" {
  container d1 db running t 9999901 healthy 50 "" "" app db
  container a1 api running t 9999902 healthy 50 "" "" app api "db:service_healthy:false"
  touch "$FAKE/fail-start-d1"
  lost_in_upgrade d1 a1
  dlu_run
  [ "$status" -eq 3 ]
  [ "$(count_calls '^docker start a1')" -eq 0 ]
  [[ "$output" == *"not starting api: its dependency db could not be brought back"* ]]
}

@test "containers whose dependencies form a cycle are reported, not started, and the run ends" {
  container x1 one running t 9999901 healthy 50 "" "" loop one "two:service_started:false"
  container x2 two running t 9999902 healthy 50 "" "" loop two "one:service_started:false"
  lost_in_upgrade x1 x2
  dlu_run
  [ "$status" -eq 3 ]
  [ "$(count_calls '^docker start ')" -eq 0 ]
  [[ "$output" == *"its dependencies form a cycle"* ]]
}

@test "a live-restored dependency does not delay its dependent" {
  container n1 db running t 9999901 healthy 90 "" "" shop db
  container e1 api running t 9999902 healthy 50 "" "" shop api "db:service_healthy:false"
  container w1 web running t 9999903 healthy 60
  lost_in_upgrade e1 w1
  dlu_run
  [ "$status" -eq 2 ]
  [ "$(count_calls '^docker start n1')" -eq 0 ]
  [ "$(call_line '^docker start e1')" -lt "$(call_line '^docker start w1')" ]
}

@test "a dependency is the named service in the same Compose project only" {
  # The other project's db sorts last, so a lookup by service name alone would land on it.
  container b1 db running t 9999902 healthy 90 "" "" beta db
  container b2 app running t 9999903 healthy 10 "" "" beta app "db:service_healthy:false"
  container z1 db running t 9999901 healthy 90 "" "" alpha db
  lost_in_upgrade z1 b2
  dlu_run
  [ "$status" -eq 2 ]
  [ "$(call_line '^docker start b2')" -lt "$(call_line '^docker start z1')" ]
}

# --- Failures ---------------------------------------------------------------------------------

@test "a container that never becomes healthy fails the run" {
  printf 'HEALTH_TIMEOUT=1\n' >> "$CONF"
  container aaa web running t1 9999901
  touch "$FAKE/unhealthy-aaa"
  upgrade_does 'printf "aaa|/web|exited|t1|0|healthy|<no value>||<no value>\n" > "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 3 ]
  [[ "$output" == *"not running and healthy after 1s"* ]]
}

@test "a started container that exits fails without waiting out the health timeout" {
  printf 'HEALTH_TIMEOUT=60\n' >> "$CONF"
  container aaa web running t1 9999901
  touch "$FAKE/exits-aaa"
  upgrade_does 'printf "aaa|/web|exited|t1|0|healthy|<no value>||<no value>\n" > "$FAKE/state/aaa"'
  local before=$SECONDS
  dlu_run
  [ "$status" -eq 3 ]
  [ $(( SECONDS - before )) -lt 30 ]
}

@test "a failed start fails the run but the other containers are still started" {
  container aaa web running t1 9999901
  container bbb db running t2 9999902
  touch "$FAKE/fail-start-aaa"
  upgrade_does 'printf "aaa|/web|exited|t1|0|none|<no value>||<no value>\n" > "$FAKE/state/aaa"
printf "bbb|/db|exited|t2|0|none|<no value>||<no value>\n" > "$FAKE/state/bbb"'
  dlu_run
  [ "$status" -eq 3 ]
  stub_called 'docker start bbb'
  [[ "$output" == *"FAILED: web"* ]]
  [[ "$output" == *"repaired: db"* ]]
}

@test "a container removed during the command is reported as failed" {
  container aaa web running t1 9999901
  upgrade_does 'rm "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 3 ]
  [[ "$output" == *"web no longer exists"* ]]
}

@test "the process of a container removed during the command is named, not signalled" {
  container aaa web running t1 9999901
  process 9999901 aaa
  upgrade_does 'rm "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 3 ]
  [[ "$output" == *"process 9999901 is still running outside Docker's control"* ]]
  [ "$(count_calls '^kill ')" -eq 0 ]
}

@test "a failed container outranks a failed command in the exit code" {
  container aaa web running t1 9999901
  upgrade_does 'rm "$FAKE/state/aaa"; exit 7'
  dlu_run
  [ "$status" -eq 3 ]
}

@test "a daemon that does not come back fails the run and tells the post-hook" {
  printf 'DAEMON_TIMEOUT=1\nPOST_HOOK='\''echo "$DOCKER_LIVE_UPGRADE_RESULT" > "$FAKE/post"'\''\n' >> "$CONF"
  container aaa web running t1 9999901
  upgrade_does 'touch "$FAKE/daemon-down"'
  dlu_run
  [ "$status" -eq 3 ]
  [[ "$output" == *"did not come back"* ]]
  [ "$(cat "$FAKE/post")" = "failed" ]
}

# --- Hooks ------------------------------------------------------------------------------------

@test "the pre-hook runs before the command and the post-hook gets the outcome" {
  printf 'PRE_HOOK='\''echo pre >> "$FAKE/order"'\''\n' >> "$CONF"
  printf 'POST_HOOK='\''echo "$DOCKER_LIVE_UPGRADE_RESULT|$DOCKER_LIVE_UPGRADE_SUMMARY" >> "$FAKE/order"'\''\n' >> "$CONF"
  container aaa web running t1 9999901
  upgrade_does 'echo upgrade >> "$FAKE/order"; printf "aaa|/web|exited|t1|0|none|<no value>||<no value>\n" > "$FAKE/state/aaa"'
  dlu_run
  [ "$status" -eq 2 ]
  [ "$(sed -n 1p "$FAKE/order")" = "pre" ]
  [ "$(sed -n 2p "$FAKE/order")" = "upgrade" ]
  [ "$(sed -n 3p "$FAKE/order")" = "repaired|0 of 1 containers live-restored; repaired: web" ]
}

@test "a failing pre-hook is reported and the run continues" {
  printf 'PRE_HOOK=false\n' >> "$CONF"
  container aaa web running t1 9999901
  upgrade_does 'touch "$FAKE/ran"'
  dlu_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRE_HOOK failed; continuing"* ]]
  [ -e "$FAKE/ran" ]
}

#!/usr/bin/env bats
#
# This script writes firewall rules, so the properties worth testing are the ones that decide whether a
# rule does what opening a container port needs and nothing more: that the destination is constrained
# rather than left as `any` (an unconstrained rule swallows traffic the host routes, which is the whole
# reason the destination is there), that one rule is written per configured range, that the protocol
# defaults to tcp, and that closing removes exactly what opening added.
#
# ufw and iptables are stubbed, so every assertion reads their argv out of the stub call log rather than
# inspecting a firewall. The docker double is reached through DOCKER_BIN and named docker-cli rather
# than shadowing `docker` on PATH: this repository's own tooling runs docker for real, to drive pinned
# images, and a stub called `docker` would be handed to it instead. CONFIG_FILE is named by every test that cares about the ranges: unset, the
# script would read the repository's own committed .conf and the expected rule set would depend on it.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/ufw-docker-expose/ufw-docker-expose.sh"
  CONF="$BATS_TEST_TMPDIR/ufw-docker-expose.conf"
  printf 'CONTAINER_SUBNETS=(172.16.0.0/12 192.168.0.0/16)\n' > "$CONF"
  # The handoff is present unless a test says otherwise, so no other test asserts against its warning
  # by accident. iptables is stubbed, so this is what the script reads.
  printf -- '-A DOCKER-USER -j ufw-user-forward\n' > "$STUB_FIXTURES/iptables.stdout"
}

########################################
# Skips the calling test when running as root, for the assertions about refusing non-root.
########################################
require_non_root() {
  [ "${EUID:-$(id -u)}" -ne 0 ] || skip "asserts the non-root refusal; this run is root"
}

########################################
# Runs the script as though it were root, against the fixture config.
#
# EUID is not assignable, so the root check is neutralised by replacing require_root for the run
# rather than by faking the identity. The refusal itself is asserted separately, unpatched.
########################################
expose_run() {
  CONFIG_FILE="$CONF" DOCKER_BIN=docker-cli run_snippet "$SCRIPT" "
    require_root() { :; }
    main $*
  "
}

########################################
# Prints the ufw calls the run made, one per line.
########################################
ufw_calls() {
  grep '^ufw ' "$STUB_CALLS" || true
}

# --- Usage and refusals ------------------------------------------------------------------------

@test "-h prints the usage and succeeds" {
  run_script "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"<port>[/tcp|/udp]"* ]]
}

@test "refuses to run as a non-root user" {
  require_non_root
  run_script "$SCRIPT" 8080
  [ "$status" -eq 1 ]
  [[ "$output" == *"must run as root"* ]]
  [ -z "$(ufw_calls)" ]
}

@test "no ports given is a usage error" {
  expose_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"No ports given"* ]]
}

@test "an unknown option is a usage error" {
  run_script "$SCRIPT" --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "--subnet without a value is a usage error" {
  run_script "$SCRIPT" --subnet
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an argument"* ]]
}

@test "a non-numeric port is rejected" {
  expose_run http
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid port"* ]]
}

@test "a port above the valid range is rejected" {
  expose_run 65536
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid port"* ]]
}

@test "an unsupported protocol is rejected" {
  expose_run 8080/sctp
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid protocol"* ]]
}

# --- The rules that get written ----------------------------------------------------------------

@test "never writes an unconstrained 'to any' rule" {
  expose_run 8080
  [ "$status" -eq 0 ]
  ! grep -qE 'ufw route allow proto tcp to any port' "$STUB_CALLS"
}

@test "writes one rule per configured subnet, naming the port" {
  expose_run 8080
  [ "$status" -eq 0 ]
  stub_called 'ufw route allow proto tcp to 172.16.0.0/12 port 8080'
  stub_called 'ufw route allow proto tcp to 192.168.0.0/16 port 8080'
  [ "$(ufw_calls | wc -l | tr -d ' ')" -eq 2 ]
}

@test "the protocol defaults to tcp and is honoured when given" {
  expose_run 5353/udp
  [ "$status" -eq 0 ]
  stub_called 'ufw route allow proto udp to 172.16.0.0/12 port 5353'
  ! grep -q 'proto tcp' "$STUB_CALLS"
}

@test "tags each rule with a comment naming the script and the port" {
  expose_run 8080/udp
  [ "$status" -eq 0 ]
  stub_called 'comment ufw-docker-expose: container port 8080/udp'
}

@test "opens several ports in one run" {
  expose_run 8080 5353/udp
  [ "$status" -eq 0 ]
  stub_called 'to 172.16.0.0/12 port 8080'
  stub_called 'to 172.16.0.0/12 port 5353'
  [ "$(ufw_calls | wc -l | tr -d ' ')" -eq 4 ]
}

@test "--close removes exactly what opening added" {
  expose_run --close 8080
  [ "$status" -eq 0 ]
  stub_called 'ufw route delete allow proto tcp to 172.16.0.0/12 port 8080'
  stub_called 'ufw route delete allow proto tcp to 192.168.0.0/16 port 8080'
  ! grep -q 'route allow proto' "$STUB_CALLS"
}

# --- Where the ranges come from ----------------------------------------------------------------

@test "--subnet replaces the configured ranges rather than adding to them" {
  expose_run --subnet 10.9.0.0/16 8080
  [ "$status" -eq 0 ]
  stub_called 'to 10.9.0.0/16 port 8080'
  ! grep -q '172.16.0.0/12' "$STUB_CALLS"
  [ "$(ufw_calls | wc -l | tr -d ' ')" -eq 1 ]
}

@test "--subnet is repeatable" {
  expose_run --subnet 10.9.0.0/16 --subnet 10.10.0.0/16 8080
  [ "$status" -eq 0 ]
  stub_called 'to 10.9.0.0/16 port 8080'
  stub_called 'to 10.10.0.0/16 port 8080'
}

@test "falls back to the RFC 1918 defaults when no config sets the ranges" {
  printf '# nothing set here\n' > "$CONF"
  expose_run 8080
  [ "$status" -eq 0 ]
  stub_called 'to 10.0.0.0/8 port 8080'
  stub_called 'to 172.16.0.0/12 port 8080'
  stub_called 'to 192.168.0.0/16 port 8080'
}

@test "an unreadable CONFIG_FILE is refused rather than silently defaulted" {
  CONFIG_FILE="$BATS_TEST_TMPDIR/absent.conf" DOCKER_BIN=docker-cli run_snippet "$SCRIPT" '
    require_root() { :; }
    main 8080
  '
  [ "$status" -ne 0 ]
  [ -z "$(ufw_calls)" ]
}

# --- Dry run and listing ----------------------------------------------------------------------

@test "--dry-run asks ufw what it would do and changes nothing" {
  expose_run --dry-run 8080
  [ "$status" -eq 0 ]
  stub_called 'ufw --dry-run route allow proto tcp to 172.16.0.0/12 port 8080'
  ! grep -qE '^ufw route ' "$STUB_CALLS"
}

@test "--list shows the forwarded rules ufw reports" {
  printf 'Status: active\n[ 1] 8080/tcp ALLOW FWD Anywhere\n[ 2] 22/tcp ALLOW IN Anywhere\n' \
    > "$STUB_FIXTURES/ufw.stdout"
  expose_run --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALLOW FWD"* ]]
  [[ "$output" != *"ALLOW IN"* ]]
}

@test "--list says so plainly when there are no forwarded rules" {
  printf 'Status: active\n[ 1] 22/tcp ALLOW IN Anywhere\n' > "$STUB_FIXTURES/ufw.stdout"
  expose_run --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no forwarded allow rules"* ]]
}

# --- The advisory publish check ---------------------------------------------------------------

@test "warns when the port is published on loopback only" {
  printf 'web 127.0.0.1:8080->8080/tcp\n' > "$STUB_FIXTURES/docker-cli.stdout"
  expose_run 8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1"* ]]
  stub_called 'to 172.16.0.0/12 port 8080'
}

@test "warns when the host port differs from the container port" {
  printf 'web 0.0.0.0:8080->9090/tcp\n' > "$STUB_FIXTURES/docker-cli.stdout"
  expose_run 8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"different container port"* ]]
}

@test "says nothing alarming about a correctly published port" {
  printf 'web 0.0.0.0:8080->8080/tcp\n' > "$STUB_FIXTURES/docker-cli.stdout"
  expose_run 8080
  [ "$status" -eq 0 ]
  [[ "$output" != *"127.0.0.1"* ]]
  [[ "$output" != *"different container port"* ]]
}

@test "notes when no container publishes the port yet, and writes the rule anyway" {
  expose_run 8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"no running container publishes 8080"* ]]
  stub_called 'to 172.16.0.0/12 port 8080'
}

# --- The ufw-docker prerequisite ---------------------------------------------------------------

@test "warns that the rules are inert when DOCKER-USER does not hand off to ufw" {
  : > "$STUB_FIXTURES/iptables.stdout"
  expose_run 8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"INERT"* ]]
  [[ "$output" == *"ufw-docker install"* ]]
}

@test "stays quiet about the handoff when it is in place" {
  expose_run 8080
  [ "$status" -eq 0 ]
  [[ "$output" != *"INERT"* ]]
}

@test "writes the rules anyway when the handoff is missing, so they can be staged" {
  : > "$STUB_FIXTURES/iptables.stdout"
  expose_run 8080
  [ "$status" -eq 0 ]
  stub_called 'ufw route allow proto tcp to 172.16.0.0/12 port 8080'
}

@test "checks the handoff when closing a port too" {
  : > "$STUB_FIXTURES/iptables.stdout"
  expose_run --close 8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"INERT"* ]]
}

@test "a chain that exists but jumps elsewhere still counts as missing" {
  printf -- '-A DOCKER-USER -j RETURN\n' > "$STUB_FIXTURES/iptables.stdout"
  expose_run 8080
  [ "$status" -eq 0 ]
  [[ "$output" == *"INERT"* ]]
}

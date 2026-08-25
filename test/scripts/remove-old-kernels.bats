#!/usr/bin/env bats
#
# remove-old-kernels purges packages, and the one mistake that matters is purging something the machine
# needs to boot. The running kernel is not always the newest installed — a machine that has updated and
# not rebooted is running the older of two — so most of this suite is about which versions survive.
#
# Both package tools are doubles written here rather than shared stubs. dpkg has to answer two different
# queries differently — the list of kernel images, and the packages belonging to one version — and a
# shared apt-get would shadow the double that test/bin/in-container.bats writes for itself, since the stub
# directory comes first on PATH for every suite.
#
# The purge is asserted from a call log either way: as root the double records itself, and as a normal user
# the shared sudo stub records the whole command without running it.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/remove-old-kernels/remove-old-kernels.sh"

  CONFIG_FILE="$BATS_TEST_TMPDIR/kernels.conf"
  export CONFIG_FILE
  : > "$CONFIG_FILE"

  export RUNNING_KERNEL="6.8.0-136-generic"
  DPKG_QUERY_BIN="$BATS_TEST_TMPDIR/dpkg-query-double"
  APT_GET_BIN="$BATS_TEST_TMPDIR/apt-get-double"
  export DPKG_QUERY_BIN APT_GET_BIN
  dpkg_describes
  apt_get_succeeds
}

########################################
# Writes an apt-get double that records its call and succeeds.
########################################
apt_get_succeeds() {
  printf '#!/usr/bin/env bash\nprintf "apt-get %%s\\n" "$*" >> "%s"\nexit 0\n' "$STUB_CALLS" > "$APT_GET_BIN"
  chmod +x "$APT_GET_BIN"
}

########################################
# Writes an apt-get double that records its call and fails.
########################################
apt_get_fails() {
  printf '#!/usr/bin/env bash\nprintf "apt-get %%s\\n" "$*" >> "%s"\nexit 100\n' "$STUB_CALLS" > "$APT_GET_BIN"
  chmod +x "$APT_GET_BIN"
}

########################################
# Writes a dpkg-query double describing a machine.
#
# Images are given as "version:status", statuses as dpkg's abbreviations — ii installed, rc removed but
# configured, un never installed. Everything a version owns is derived from its status, which is how the
# real thing behaves: a package dpkg holds nothing for cannot be purged.
# Arguments:
#   Image specifications; none means the aurora-shaped default.
########################################
dpkg_describes() {
  local -a images=("$@")
  if (( ${#images[@]} == 0 )); then
    images=(6.8.0-124-generic:rc 6.8.0-134-generic:rc 6.8.0-136-generic:ii 6.8.0-137-generic:rc 6.8.0-138-generic:ii)
  fi
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "dpkg-query %%s\\n" "$*" >> "%s"\n' "$STUB_CALLS"
    printf 'if [[ "$*" == *"linux-image-[0-9]*"* ]]; then\n'
    for spec in "${images[@]}"; do
      printf '  printf "linux-image-%s %s\\n"\n' "${spec%%:*}" "${spec##*:}"
      printf '  printf "linux-image-unsigned-%s un\\n"\n' "${spec%%:*}"
    done
    printf '  exit 0\nfi\n'
    # Packages for one version: the pattern names it, so answer for whichever one matches.
    for spec in "${images[@]}"; do
      printf 'if [[ "$*" == *"linux-*-%s"* ]]; then\n' "${spec%%:*}"
      printf '  printf "linux-image-%s %s\\n"\n' "${spec%%:*}" "${spec##*:}"
      printf '  printf "linux-modules-%s %s\\n"\n' "${spec%%:*}" "${spec##*:}"
      printf '  printf "linux-headers-%s %s\\n"\n' "${spec%%:*}" "${spec##*:}"
      printf '  printf "linux-image-unsigned-%s un\\n"\n' "${spec%%:*}"
      printf '  exit 0\nfi\n'
    done
    printf 'exit 0\n'
  } > "$DPKG_QUERY_BIN"
  chmod +x "$DPKG_QUERY_BIN"
}

# --- Which kernels survive ----------------------------------------------------------------------

@test "installed versions are listed oldest first, ignoring what dpkg holds nothing for" {
  run_func "$SCRIPT" installed_versions
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "6.8.0-124-generic" ]
  [ "${lines[4]}" = "6.8.0-138-generic" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "versions are ordered by number, not lexically" {
  dpkg_describes 6.8.0-99-generic:ii 6.8.0-136-generic:ii
  run_func "$SCRIPT" installed_versions
  [ "${lines[0]}" = "6.8.0-99-generic" ]
  [ "${lines[1]}" = "6.8.0-136-generic" ]
}

# This is the case that makes the script worth having: the newest installed is not what is running.
@test "both the running kernel and the newest installed are kept" {
  run_snippet "$SCRIPT" '_keep_count=1; versions_to_keep 6.8.0-124-generic 6.8.0-134-generic 6.8.0-136-generic 6.8.0-137-generic 6.8.0-138-generic'
  [ "${lines[0]}" = "6.8.0-136-generic" ]
  [ "${lines[1]}" = "6.8.0-138-generic" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "keeping more holds further recent kernels as fallbacks" {
  run_snippet "$SCRIPT" '_keep_count=2; versions_to_keep 6.8.0-124-generic 6.8.0-134-generic 6.8.0-136-generic 6.8.0-137-generic 6.8.0-138-generic'
  [ "${#lines[@]}" -eq 3 ]
  [[ "$output" == *"6.8.0-137-generic"* ]]
  [[ "$output" == *"6.8.0-138-generic"* ]]
  [[ "$output" == *"6.8.0-136-generic"* ]]
}

@test "keeping none still keeps the running kernel" {
  run_snippet "$SCRIPT" '_keep_count=0; versions_to_keep 6.8.0-124-generic 6.8.0-136-generic 6.8.0-138-generic'
  [ "$output" = "6.8.0-136-generic" ]
}

@test "the running kernel being the newest keeps just it" {
  RUNNING_KERNEL="6.8.0-138-generic" run_snippet "$SCRIPT" '_keep_count=1; versions_to_keep 6.8.0-136-generic 6.8.0-138-generic'
  [ "$output" = "6.8.0-138-generic" ]
}

@test "only packages dpkg has something to purge are named" {
  run_func "$SCRIPT" packages_for 6.8.0-124-generic
  [ "$status" -eq 0 ]
  [[ "$output" == *"linux-image-6.8.0-124-generic"* ]]
  [[ "$output" == *"linux-modules-6.8.0-124-generic"* ]]
  [[ "$output" != *"unsigned"* ]]
}

# --- Driving it ---------------------------------------------------------------------------------

@test "the report names what is kept and what goes" {
  run_script "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"6.8.0-136-generic"* ]]
  [[ "$output" == *"(running)"* ]]
  [[ "$output" == *"6.8.0-138-generic"* ]]
  [[ "$output" == *"linux-image-6.8.0-124-generic"* ]]
  [[ "$output" == *"Dry run: nothing was purged."* ]]
}

@test "--dry-run purges nothing" {
  run_script "$SCRIPT" --dry-run
  run bash -c "grep -cE 'apt-get(-double)? purge' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "the running kernel's packages are never in the purge list" {
  run_script "$SCRIPT" --dry-run
  run bash -c "printf '%s\n' \"\$1\" | grep -c '6.8.0-136-generic' " _ "$(printf '%s\n' "$output" | grep -A100 'Purging')"
  [ "$output" = "0" ]
}

@test "confirming purges every named package in one apt-get call" {
  printf 'y\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  stub_called 'apt-get-double purge -y\|apt-get purge -y'
  stub_called 'linux-image-6.8.0-124-generic'
  run bash -c "grep -cE 'apt-get(-double)? purge' '$STUB_CALLS'"
  [ "$output" = "1" ]
}

@test "declining purges nothing" {
  printf 'n\n' > "$BATS_TEST_TMPDIR/answers"
  run_script "$SCRIPT" < "$BATS_TEST_TMPDIR/answers"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled."* ]]
  run bash -c "grep -cE 'apt-get(-double)? purge' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "--yes purges without asking" {
  run_script "$SCRIPT" --yes < /dev/null
  [ "$status" -eq 0 ]
  stub_called 'apt-get-double purge -y\|apt-get purge -y'
}

@test "nothing to remove is said plainly" {
  dpkg_describes 6.8.0-136-generic:ii 6.8.0-138-generic:ii
  run_script "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to remove."* ]]
}

@test "a failing apt-get is reported and exits non-zero" {
  apt_get_fails
  # As a normal user the command goes through sudo, which the shared stub answers, so that has to fail too.
  stub_fails sudo
  run_script "$SCRIPT" --yes < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"apt-get did not finish"* ]]
}

@test "a machine with no kernel packages is refused rather than reported empty" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$DPKG_QUERY_BIN"
  chmod +x "$DPKG_QUERY_BIN"
  run_script "$SCRIPT" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"No kernel image packages found"* ]]
}

@test "a system without dpkg-query is refused" {
  DPKG_QUERY_BIN="$BATS_TEST_TMPDIR/absent" run_script "$SCRIPT" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"only makes sense on a Debian or Ubuntu system"* ]]
}

@test "the configured keep count applies when no option overrides it" {
  printf 'KEEP_COUNT=2\n' > "$CONFIG_FILE"
  run_script "$SCRIPT" --dry-run
  [[ "$output" == *"6.8.0-137-generic"* ]]
}

@test "a keep count that is not a number is refused" {
  run_script "$SCRIPT" --keep many --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a whole number"* ]]
}

@test "an unknown option is refused" {
  run_script "$SCRIPT" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'."* ]]
}

@test "a positional argument is refused" {
  run_script "$SCRIPT" extra
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected arguments: extra"* ]]
}

# --- Paths the earlier tests did not reach -------------------------------------------------------

# The assertion of last resort: whatever the version arithmetic decided, a package belonging to the
# running kernel stops the run rather than the boot.
@test "a package list touching the running kernel stops the run" {
  # dpkg is made to claim the running kernel's package belongs to a version that is not being kept, which
  # is the shape a mistake in the version arithmetic would take.
  printf '#!/usr/bin/env bash\nif [[ "$*" == *"linux-image-[0-9]*"* ]]; then printf "linux-image-6.8.0-124-generic ii\\n"; printf "linux-image-6.8.0-138-generic ii\\n"; exit 0; fi\nprintf "linux-image-6.8.0-136-generic ii\\n"\nexit 0\n' > "$DPKG_QUERY_BIN"
  chmod +x "$DPKG_QUERY_BIN"
  run_script "$SCRIPT" --yes < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"belongs to the running kernel 6.8.0-136-generic"* ]]
  run bash -c "grep -cE 'apt-get(-double)? purge' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "an old kernel with nothing left to purge is reported as nothing to do" {
  # The image is known to dpkg but holds no files, and neither does anything else for that version.
  printf '#!/usr/bin/env bash\nif [[ "$*" == *"linux-image-[0-9]*"* ]]; then printf "linux-image-6.8.0-124-generic ii\\n"; printf "linux-image-6.8.0-136-generic ii\\n"; exit 0; fi\nif [[ "$*" == *"6.8.0-124"* ]]; then printf "linux-image-6.8.0-124-generic un\\n"; fi\nexit 0\n' > "$DPKG_QUERY_BIN"
  chmod +x "$DPKG_QUERY_BIN"
  run_script "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no packages left to purge"* ]]
}

@test "--no-color and --debug are accepted" {
  run_script "$SCRIPT" --no-color --debug --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Keeping:"* ]]
}

#!/usr/bin/env bats
#
# This script grants passwordless sudo, so the properties worth testing are the ones that stop a grant
# outliving its session: that the drop-in is validated before being installed, that the boot-time revoke
# unit is in place *before* the grant rather than after, and that the auto-revoke timer is armed with the
# requested timeout — with 0 meaning never, said out loud.
#
# DROPIN and SYSTEMD_UNIT_DIR come from the environment so the writes land in the test's own directory.
# That is not a convenience: the real values are /etc/sudoers.d and /etc/systemd/system, the coverage job
# runs as root in a container, and a test that used the defaults would install a working passwordless-sudo
# rule on whatever machine ran it.
#
# visudo, systemd-run and systemctl are stubbed, so the validation and the timer are asserted from their
# argv. `install -o root -g root` genuinely needs root, so the tests that reach it skip when not root;
# they run in the Linux coverage job, which is where this Debian-only script is measured.

load test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/nopasswd-sudo.sh"
  DROPIN_FILE="$BATS_TEST_TMPDIR/99-temp-nopasswd"
  UNIT_DIR="$BATS_TEST_TMPDIR/systemd"
  mkdir -p "$UNIT_DIR"
}

########################################
# Skips the calling test unless running as root, which `install -o root` requires.
########################################
require_root_run() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || skip "needs root for install -o root (runs in the Linux coverage job)"
}

########################################
# Skips the calling test when running as root, for the assertions about refusing non-root.
########################################
require_non_root() {
  [ "${EUID:-$(id -u)}" -ne 0 ] || skip "asserts the non-root refusal; this run is root"
}

########################################
# Runs the script against the fixture paths.
########################################
sudo_run() {
  DROPIN="$DROPIN_FILE" SYSTEMD_UNIT_DIR="$UNIT_DIR" run_script "$SCRIPT" "$@"
}

########################################
# Evaluates a snippet inside the script against the fixture paths.
########################################
with_paths() {
  DROPIN="$DROPIN_FILE" SYSTEMD_UNIT_DIR="$UNIT_DIR" run_snippet "$SCRIPT" "$1"
}

########################################
# Names a user that certainly exists on the machine running the test.
########################################
real_user() {
  id -un
}

# --- Dispatch and usage ------------------------------------------------------------------------

@test "no arguments prints the usage and succeeds" {
  sudo_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"{on|off|status}"* ]]
}

@test "-h and --help print the usage" {
  sudo_run -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-revoke"* ]]
  sudo_run --help
  [ "$status" -eq 0 ]
}

@test "the usage names the default timeout and the drop-in it manages" {
  sudo_run --help
  [[ "$output" == *"30"* ]]
  [[ "$output" == *"$DROPIN_FILE"* ]]
}

# The usage is shown without root, so someone who forgot sudo still gets told what the tool does.
@test "the usage does not require root" {
  require_non_root
  sudo_run --help
  [ "$status" -eq 0 ]
}

@test "a non-root run is refused" {
  require_non_root
  sudo_run status
  [ "$status" -eq 1 ]
  [[ "$output" == *"must run as root"* ]]
}

# Root is checked before the command is validated, so an unknown command from a non-root caller reports
# the missing privilege rather than the typo.
@test "root is checked before the command is validated" {
  require_non_root
  sudo_run definitely-not-a-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"must run as root"* ]]
  [[ "$output" != *"unknown command"* ]]
}

@test "an unknown command is refused with its own status" {
  require_root_run
  sudo_run definitely-not-a-command
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

# --- Granting ----------------------------------------------------------------------------------

@test "the grant installs a drop-in for the named user" {
  require_root_run
  with_paths "enable_nopasswd $(real_user)"
  [ "$status" -eq 0 ]
  [ -f "$DROPIN_FILE" ]
  run cat "$DROPIN_FILE"
  [[ "$output" == *"$(real_user) ALL=(ALL) NOPASSWD:ALL"* ]]
}

# A syntax error in a sudoers file can lock the machine out of sudo entirely, so the check has to happen
# before the file is put in place, and a failure must leave nothing behind.
@test "a drop-in that fails validation is not installed" {
  require_root_run
  stub_fails visudo
  with_paths "enable_nopasswd $(real_user)"
  [ "$status" -ne 0 ]
  [ ! -e "$DROPIN_FILE" ]
  [[ "$output" == *"syntax check failed"* ]]
}

@test "validation is run against the candidate file, not the installed one" {
  require_root_run
  with_paths "enable_nopasswd $(real_user)"
  stub_called 'visudo -cf'
  run bash -c "grep -c 'visudo -cf $DROPIN_FILE' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "the drop-in is installed read-only for root" {
  require_root_run
  with_paths "enable_nopasswd $(real_user)"
  run stat -c '%a %U %G' "$DROPIN_FILE"
  [ "$output" = "440 root root" ]
}

@test "a user that does not exist is refused" {
  with_paths "enable_nopasswd definitely-no-such-user-here"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such user"* ]]
  [ ! -e "$DROPIN_FILE" ]
}

@test "no determinable user is refused rather than guessed" {
  with_paths "unset SUDO_USER; enable_nopasswd ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not determine target user"* ]]
}

@test "the target user defaults to the invoking sudo user" {
  require_root_run
  SUDO_USER="$(real_user)" with_paths "enable_nopasswd"
  [ "$status" -eq 0 ]
  run cat "$DROPIN_FILE"
  [[ "$output" == *"$(real_user) ALL"* ]]
}

# --- Arming the auto-revoke --------------------------------------------------------------------

@test "the auto-revoke timer is armed with the requested timeout" {
  with_paths "schedule_revoke 45"
  [ "$status" -eq 0 ]
  stub_called 'systemd-run .*--on-active=45min'
  [[ "$output" == *"self-disables in 45 min"* ]]
}

# Asserted as "whatever this script resolved to, followed by off" rather than by filename: reached under
# coverage the code runs through kcov's harness, so $0 — and therefore readlink -f "$0" — is the harness
# path, not the script's. The claim that matters is that the timer re-invokes the tool to revoke.
@test "the timer runs this same script with off" {
  with_paths "schedule_revoke 45"
  stub_called "systemd-run .* off$"
}

# A timeout of zero is a deliberate choice to leave the grant open, so it has to be stated rather than
# quietly leaving nothing armed.
@test "a timeout of zero arms nothing and says so" {
  with_paths "schedule_revoke 0"
  [ "$status" -eq 0 ]
  [ "$(stub_calls systemd-run)" -eq 0 ]
  [[ "$output" == *"auto-revoke DISABLED"* ]]
  [[ "$output" == *"remember to run 'off' yourself"* ]]
}

# Re-arming has to reset the clock, or a second `on` would inherit the first one's remaining time.
@test "arming cancels any previous timer first" {
  with_paths "schedule_revoke 45"
  stub_called 'systemctl stop nopasswd-sudo-autorevoke.timer'
  stub_called 'systemctl reset-failed'
}

@test "cancelling tolerates there being no timer" {
  stub_fails systemctl
  with_paths "cancel_revoke; echo survived"
  [ "$status" -eq 0 ]
  [[ "$output" == *"survived"* ]]
}

# --- The boot-time safety net ------------------------------------------------------------------

@test "the boot unit is written and enabled" {
  with_paths "ensure_boot_revoke"
  [ "$status" -eq 0 ]
  [ -f "$UNIT_DIR/nopasswd-sudo-bootrevoke.service" ]
  run cat "$UNIT_DIR/nopasswd-sudo-bootrevoke.service"
  [[ "$output" == *"Type=oneshot"* ]]
  [[ "$output" == *"WantedBy=multi-user.target"* ]]
  stub_called 'systemctl enable nopasswd-sudo-bootrevoke.service'
}

@test "the boot unit revokes by running this script with off" {
  with_paths "ensure_boot_revoke"
  run cat "$UNIT_DIR/nopasswd-sudo-bootrevoke.service"
  [[ "$output" == *"ExecStart=/"*" off"* ]]
}

@test "an existing boot unit is left alone and not rewritten" {
  printf '[Unit]\nDescription=hand-edited\n' > "$UNIT_DIR/nopasswd-sudo-bootrevoke.service"
  with_paths "ensure_boot_revoke"
  run cat "$UNIT_DIR/nopasswd-sudo-bootrevoke.service"
  [[ "$output" == *"hand-edited"* ]]
  [ "$(stub_calls systemctl)" -ge 1 ]
  run bash -c "grep -c 'systemctl daemon-reload' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "writing the boot unit reloads systemd so it is seen" {
  with_paths "ensure_boot_revoke"
  stub_called 'systemctl daemon-reload'
}

# The whole point of the boot unit is that a reboot cannot strand the grant, so it must be in place before
# the grant exists rather than after.
@test "the boot unit is installed before the grant" {
  require_root_run
  sudo_run on "$(real_user)" 5
  [ "$status" -eq 0 ]
  local enable_line install_line
  enable_line=$(grep -n 'systemctl enable nopasswd-sudo-bootrevoke' "$STUB_CALLS" | head -1 | cut -d: -f1)
  install_line=$(grep -n 'visudo -cf' "$STUB_CALLS" | head -1 | cut -d: -f1)
  [ -n "$enable_line" ]
  [ -n "$install_line" ]
  [ "$enable_line" -lt "$install_line" ]
}

# --- Revoking ----------------------------------------------------------------------------------

@test "revoking removes the drop-in and cancels the timer" {
  printf 'someone ALL=(ALL) NOPASSWD:ALL\n' > "$DROPIN_FILE"
  with_paths "disable_nopasswd"
  [ "$status" -eq 0 ]
  [ ! -e "$DROPIN_FILE" ]
  [[ "$output" == *"DISABLED"* ]]
  stub_called 'systemctl stop nopasswd-sudo-autorevoke.timer'
}

# Revoking has to be safe to run at any time: the boot unit and the timer both call it unconditionally.
@test "revoking when nothing is granted is not an error" {
  with_paths "disable_nopasswd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already disabled"* ]]
}

@test "revoking twice is not an error" {
  printf 'someone ALL=(ALL) NOPASSWD:ALL\n' > "$DROPIN_FILE"
  with_paths "disable_nopasswd; disable_nopasswd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DISABLED"* ]]
  [[ "$output" == *"already disabled"* ]]
}

@test "off from the command line revokes" {
  require_root_run
  printf 'someone ALL=(ALL) NOPASSWD:ALL\n' > "$DROPIN_FILE"
  sudo_run off
  [ "$status" -eq 0 ]
  [ ! -e "$DROPIN_FILE" ]
}

# --- Status ------------------------------------------------------------------------------------

@test "status shows the granted rule when one is in place" {
  printf 'someone ALL=(ALL) NOPASSWD:ALL\n' > "$DROPIN_FILE"
  with_paths "show_status"
  [[ "$output" == *"ENABLED:"* ]]
  [[ "$output" == *"someone ALL=(ALL) NOPASSWD:ALL"* ]]
}

@test "status reports no grant when there is none" {
  with_paths "show_status"
  [[ "$output" == *"DISABLED"* ]]
}

@test "status reports the timer as armed when systemd says it is active" {
  with_paths "show_status"
  [[ "$output" == *"auto-revoke (this session): ARMED"* ]]
}

@test "status reports the timer as not armed when systemd says it is not" {
  stub_fails systemctl
  with_paths "show_status"
  [[ "$output" == *"auto-revoke (this session): not armed"* ]]
}

# Without the boot unit a reboot leaves the grant in place with nothing to remove it, so status has to say
# so rather than reporting only the timer.
@test "status warns when the boot-time revoke is missing" {
  stub_fails systemctl
  with_paths "show_status"
  [[ "$output" == *"boot-revoke: NOT installed"* ]]
  [[ "$output" == *"would not clear a stale grant"* ]]
}

@test "status confirms the boot-time revoke when it is enabled" {
  with_paths "show_status"
  [[ "$output" == *"boot-revoke: enabled"* ]]
}

# --- Argument shapes for `on` ------------------------------------------------------------------

@test "a bare number after on is the timeout, not a user name" {
  require_root_run
  SUDO_USER="$(real_user)" sudo_run on 90
  [ "$status" -eq 0 ]
  stub_called 'systemd-run .*--on-active=90min'
  run cat "$DROPIN_FILE"
  [[ "$output" == *"$(real_user) ALL"* ]]
}

@test "a user and a timeout are both honoured" {
  require_root_run
  sudo_run on "$(real_user)" 15
  [ "$status" -eq 0 ]
  stub_called 'systemd-run .*--on-active=15min'
  run cat "$DROPIN_FILE"
  [[ "$output" == *"$(real_user) ALL"* ]]
}

@test "a user with no timeout gets the default" {
  require_root_run
  sudo_run on "$(real_user)"
  stub_called 'systemd-run .*--on-active=30min'
}

@test "a user with an explicit zero timeout arms nothing" {
  require_root_run
  sudo_run on "$(real_user)" 0
  [ "$status" -eq 0 ]
  [ "$(stub_calls systemd-run)" -eq 0 ]
  [[ "$output" == *"auto-revoke DISABLED"* ]]
}

# --- Safety ------------------------------------------------------------------------------------

# The defaults are the machine's real sudoers and unit directories. If a test ever ran without the
# fixture paths it would grant passwordless sudo for real, so this asserts the override is what took
# effect rather than trusting it.
@test "the real system paths are never the ones written" {
  require_root_run
  sudo_run on "$(real_user)" 5
  [ -f "$DROPIN_FILE" ]
  [ -f "$UNIT_DIR/nopasswd-sudo-bootrevoke.service" ]
  [ ! -e /etc/sudoers.d/99-temp-nopasswd ]
  [ ! -e /etc/systemd/system/nopasswd-sudo-bootrevoke.service ]
}

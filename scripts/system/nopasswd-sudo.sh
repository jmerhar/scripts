#!/usr/bin/env bash
#
# nopasswd-sudo.sh — toggle temporary passwordless sudo for a user.
#
# Handy during migration/maintenance sessions that run many sudo commands
# non-interactively (e.g. driven over SSH). Turn it ON at the start, OFF when
# done. The drop-in is validated with `visudo` before being installed, so a
# typo can't lock you out of sudo.
#
# Enabling also arms an auto-revoke so you can never leave passwordless sudo on
# by accident: an in-session timer switches it OFF after the timeout (default
# 30 min; pass a different number of minutes, or 0 to disable), AND a persistent
# boot-time unit clears it on every reboot. The in-session timer is transient
# and does NOT survive a reboot, so the boot unit is the reboot safety net —
# without it, a reboot would strand the grant with nothing left to revoke it.
#
# Usage:
#   sudo ./nopasswd-sudo.sh on   [user] [minutes]   # default user: $SUDO_USER, default 30 min
#   sudo ./nopasswd-sudo.sh off
#   sudo ./nopasswd-sudo.sh status
#
set -o errexit
set -o nounset
set -o pipefail

readonly DROPIN="/etc/sudoers.d/99-temp-nopasswd"
readonly AUTO_UNIT="nopasswd-sudo-autorevoke"
readonly BOOT_UNIT="nopasswd-sudo-bootrevoke"
readonly DEFAULT_TIMEOUT_MIN=30

#######################################
# Log an informational message to stdout.
#######################################
log_info() { printf '%s\n' "$*"; }

#######################################
# Log an error message to stderr.
#######################################
log_error() { printf 'ERROR: %s\n' "$*" >&2; }

#######################################
# Print usage information.
#######################################
show_usage() {
  cat <<EOF
Usage: sudo $(basename "$0") {on|off|status} [user] [minutes]

  on [user] [minutes]   grant passwordless sudo (default user: \${SUDO_USER:-root})
                        and arm auto-revoke after [minutes] (default ${DEFAULT_TIMEOUT_MIN}; 0 = never)
  off                   revoke it now (removes ${DROPIN}, cancels the timer)
  status                show whether it is enabled and any armed auto-revoke

Examples:
  sudo $(basename "$0") on            # enable for \$SUDO_USER, auto-off in ${DEFAULT_TIMEOUT_MIN} min
  sudo $(basename "$0") on 90         # enable for \$SUDO_USER, auto-off in 90 min
  sudo $(basename "$0") on jure 0     # enable for jure, no auto-revoke
EOF
}

#######################################
# Abort unless running as root.
#######################################
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "must run as root (use sudo)."
    exit 1
  fi
}

#######################################
# Enable passwordless sudo for a user via a validated sudoers drop-in.
# Globals:
#   DROPIN
# Arguments:
#   Target user (defaults to ${SUDO_USER}).
#######################################
enable_nopasswd() {
  local user="${1:-${SUDO_USER:-}}"
  if [[ -z "${user}" ]]; then
    log_error "could not determine target user; pass one explicitly."
    exit 1
  fi
  if ! id -u "${user}" >/dev/null 2>&1; then
    log_error "no such user: ${user}"
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${user}" >"${tmp}"

  # Validate BEFORE installing — a bad sudoers file can lock you out of sudo.
  if ! visudo -cf "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    log_error "sudoers syntax check failed; not installing."
    exit 1
  fi

  install -m 0440 -o root -g root "${tmp}" "${DROPIN}"
  rm -f "${tmp}"
  log_info "passwordless sudo ENABLED for '${user}' (${DROPIN})."
}

#######################################
# Arm a one-shot systemd timer that runs `off` after the timeout.
# A transient timer is used so it survives this script (and the SSH session)
# exiting. Re-arming first cancels any existing timer, resetting the clock.
# Globals:
#   AUTO_UNIT
# Arguments:
#   Timeout in minutes (0 disables auto-revoke).
#######################################
schedule_revoke() {
  local minutes="${1}"
  cancel_revoke
  if [[ "${minutes}" -eq 0 ]]; then
    log_info "auto-revoke DISABLED (timeout 0) — remember to run 'off' yourself."
    return
  fi
  local self
  self="$(readlink -f "$0")"
  systemd-run --quiet --unit="${AUTO_UNIT}" --on-active="${minutes}min" \
    --description="Auto-revoke temporary passwordless sudo" \
    "${self}" off
  log_info "auto-revoke ARMED: passwordless sudo self-disables in ${minutes} min."
}

#######################################
# Cancel any pending auto-revoke timer (idempotent).
# Globals:
#   AUTO_UNIT
#######################################
cancel_revoke() {
  systemctl stop "${AUTO_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "${AUTO_UNIT}.service" "${AUTO_UNIT}.timer" >/dev/null 2>&1 || true
}

#######################################
# Install and enable a persistent boot-time unit that revokes passwordless
# sudo on every boot. The in-session auto-revoke timer is transient and does
# NOT survive a reboot, so without this a reboot could strand the grant with
# nothing left to remove it. Idempotent; safe to leave enabled permanently
# (its `off` is a no-op when no drop-in is present).
# Globals:
#   BOOT_UNIT
#######################################
ensure_boot_revoke() {
  local self unit="/etc/systemd/system/${BOOT_UNIT}.service"
  self="$(readlink -f "$0")"
  if [[ ! -f "${unit}" ]]; then
    cat >"${unit}" <<UNIT
[Unit]
Description=Revoke temporary passwordless sudo on boot
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${self} off

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi
  systemctl enable "${BOOT_UNIT}.service" >/dev/null 2>&1 || true
}

#######################################
# Remove the passwordless sudo drop-in and cancel the auto-revoke timer.
# Globals:
#   DROPIN
#######################################
disable_nopasswd() {
  if [[ -f "${DROPIN}" ]]; then
    rm -f "${DROPIN}"
    log_info "passwordless sudo DISABLED (removed ${DROPIN})."
  else
    log_info "already disabled (no ${DROPIN})."
  fi
  cancel_revoke
}

#######################################
# Report whether the drop-in is present and whether auto-revoke is armed.
# Globals:
#   DROPIN
#   AUTO_UNIT
#   BOOT_UNIT
#######################################
show_status() {
  if [[ -f "${DROPIN}" ]]; then
    log_info "ENABLED:"
    sed 's/^/  /' "${DROPIN}"
  else
    log_info "DISABLED (no ${DROPIN})."
  fi
  if systemctl is-active --quiet "${AUTO_UNIT}.timer" 2>/dev/null; then
    log_info "auto-revoke (this session): ARMED"
    systemctl list-timers "${AUTO_UNIT}.timer" --no-pager 2>/dev/null \
      | sed -n '2p' | sed 's/^/  /'
  else
    log_info "auto-revoke (this session): not armed"
  fi
  if systemctl is-enabled --quiet "${BOOT_UNIT}.service" 2>/dev/null; then
    log_info "boot-revoke: enabled (passwordless sudo is cleared on every reboot)"
  else
    log_info "boot-revoke: NOT installed (a reboot would not clear a stale grant)"
  fi
}

#######################################
# Entry point: dispatch on the requested action.
#######################################
main() {
  case "${1:-}" in
    -h | --help | "") show_usage; exit 0 ;;
  esac
  require_root
  case "${1}" in
    on)
      # on [user] [minutes]; a bare numeric first arg is treated as minutes.
      local user="" minutes="${DEFAULT_TIMEOUT_MIN}"
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        minutes="${2}"
      else
        user="${2:-}"
        [[ "${3:-}" =~ ^[0-9]+$ ]] && minutes="${3}"
      fi
      # Install the boot-time safety net BEFORE granting, so a reboot can never
      # strand the grant even if everything after this point fails.
      ensure_boot_revoke
      enable_nopasswd "${user}"
      schedule_revoke "${minutes}"
      ;;
    off)    disable_nopasswd ;;
    status) show_status ;;
    *)      log_error "unknown command: ${1}"; show_usage; exit 2 ;;
  esac
}

main "$@"

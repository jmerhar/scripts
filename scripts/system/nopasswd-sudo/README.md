# `nopasswd-sudo`

Toggles temporary passwordless `sudo` for a user during a maintenance session, with two independent safety nets so it can never be left enabled by accident. Handy when driving many non-interactive `sudo` commands over SSH.

### Features

* **Validated drop-in** — Writes `/etc/sudoers.d/99-temp-nopasswd` only after `visudo -c` passes, so a typo can't lock you out of `sudo`.
* **In-session auto-revoke** — Arms a transient `systemd` timer that switches the grant back off after a timeout (default 30 min; `0` disables), surviving the SSH session ending.
* **Boot-time safety net** — A persistent boot unit clears the grant on every reboot, covering the case where the in-session timer did not survive.
* **Idempotent status** — `status` reports whether the grant and each safety net are currently active.

### Requirements

* `bash` 4.0+
* `sudo` and `systemd` (Debian/Ubuntu)

### Usage

Must be run as root (via `sudo`).

```bash
sudo nopasswd-sudo on            # enable for $SUDO_USER, auto-off in 30 min
sudo nopasswd-sudo on 90         # enable for $SUDO_USER, auto-off in 90 min
sudo nopasswd-sudo on jure 0     # enable for jure, no auto-revoke
sudo nopasswd-sudo off           # revoke now
sudo nopasswd-sudo status        # show current state
```

### Options

| Argument | Description |
| --- | --- |
| `on [user] [minutes]` | Grant passwordless sudo (default user `$SUDO_USER`) and arm auto-revoke after `minutes` (default 30; `0` = never). |
| `off` | Revoke the grant now and cancel the auto-revoke timer. |
| `status` | Show whether the grant and safety nets are active. |
| `-h`, `--help` | Show the help message. |

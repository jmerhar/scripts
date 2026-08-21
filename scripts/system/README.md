# System Scripts

User-facing scripts for system administration tasks. For installation instructions, see the [main README](../../README.md#installation).

## Scripts

<!-- BEGIN INDEX -->
### [`local-backup`](local-backup/)

A generic script to create and automatically prune rsync-based system backups.

`bash 4.0+` · deps: `rsync`

### [`mdcheck-progress`](mdcheck-progress/)

Reports the progress of an MD RAID check (Debian's monthly mdcheck scrub), including while it is paused between nightly windows, with a schedule-aware estimate of when it will finish.

`bash 4.0+` · deps: `mdadm` _(Linux only)_

### [`memory-pressure-alert`](memory-pressure-alert/)

Warns while a Mac is filling up — swap growing and memory use climbing — rather than once it has already stalled, and names the heaviest applications by resident plus compressed memory.

_(macOS only)_

### [`nopasswd-sudo`](nopasswd-sudo/)

Toggles temporary passwordless sudo for a user, with an in-session auto-revoke timer and a boot-time safety net so it never stays enabled by accident.

deps: `sudo` _(Linux only)_

### [`prune-orphaned-torrents`](prune-orphaned-torrents/)

Finds orphaned media files left by *arr hard-linking and interactively removes the corresponding torrents from Deluge.

`bash 4.0+` · deps: `curl`, `jq`

### [`ufw-docker-expose`](ufw-docker-expose/)

Opens external access to Docker-published container ports using ufw route rules keyed on the port rather than the container's address, so a redeploy that renumbers the container cannot silently close the port from outside, and constrained to container address ranges so the rules do not swallow traffic the host routes for a VPN exit node or subnet router.

deps: `ufw` _(Linux only)_

<!-- END INDEX -->


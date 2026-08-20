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

Warns while a Mac is filling up — swap growing and free memory falling — rather than once it has already stalled, and names the heaviest applications by resident plus compressed memory.

_(macOS only)_

### [`nopasswd-sudo`](nopasswd-sudo/)

Toggles temporary passwordless sudo for a user, with an in-session auto-revoke timer and a boot-time safety net so it never stays enabled by accident.

deps: `sudo` _(Linux only)_

### [`prune-orphaned-torrents`](prune-orphaned-torrents/)

Finds orphaned media files left by *arr hard-linking and interactively removes the corresponding torrents from Deluge.

`bash 4.0+` · deps: `curl`, `jq`

<!-- END INDEX -->


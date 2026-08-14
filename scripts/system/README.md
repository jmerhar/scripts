# System Scripts

User-facing scripts for system administration tasks. For installation instructions, see the [main README](../../README.md#installation).

## Scripts

<!-- BEGIN TABLE -->
| Script | Description |
|---------|-------------|
| [`local-backup`](local-backup/) | Create incremental rsync backups, pruning old ones and waiting out RAID activity. |
| [`mdcheck-progress`](mdcheck-progress/) | Report MD RAID scrub (`check`) progress and estimated finish time, even while paused between nightly windows. _(Linux only)_ |
| [`nopasswd-sudo`](nopasswd-sudo/) | Toggle temporary passwordless sudo with auto-revoke and a boot-time safety net. _(Linux only)_ |
| [`prune-orphaned-torrents`](prune-orphaned-torrents/) | Find orphaned media left by \*arr hard-linking and interactively remove the matching Deluge torrents. |

<!-- END TABLE -->


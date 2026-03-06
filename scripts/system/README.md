# System Scripts

User-facing scripts for system administration tasks. For installation instructions, see the [main README](../../README.md#installation).

## `local-backup`

A script to create and automatically prune incremental rsync-based system backups. Designed to run unattended via `cron`.

### Features

* **Incremental Backups** — Uses `rsync --link-dest` to create space-efficient hard-linked snapshots.
* **Automatic Pruning** — Keeps a configurable number of recent backups and deletes the oldest.
* **RAID Awareness** — Detects active RAID operations (resync, check) via `/proc/mdstat` and waits for them to finish before starting the backup.
* **Low I/O Priority** — Optionally lowers the process I/O priority to idle (`ionice -c3`) so backups yield to other workloads.
* **Concurrent Run Protection** — Uses `flock` to prevent overlapping backup runs.
* **Centralized Configuration** — All settings are managed in a single config file (`/etc/local-backup.conf`).
* **Flexible Exclusions** — Exclusion patterns are defined as a Bash array in the config file.
* **Cron-Friendly** — Logs to a file and only sends errors to `stderr` (for cron email notifications).

### Requirements

* `bash` 4.0+
* `rsync`

### Usage

The script takes no arguments. All settings come from the configuration file.

**1. Configure** — Create `/etc/local-backup.conf` (a [template](../../conf/system/local-backup.conf) is included):

```bash
SOURCE_DIR="/"
BACKUP_DIR="/mnt/storage/backup"
KEEP_BACKUPS=12

EXCLUDES=(
  "/dev"
  "/proc"
  "/sys"
  "/tmp"
  "/run"
  "/lost+found"
  "/mnt/*"
)

LOG_FILE="/var/log/local-backup.log"
```

**2. Run:**

```bash
sudo local-backup
```

**3. Schedule** — Add to root's crontab (`sudo crontab -e`):

```
5 4 * * * /usr/local/bin/local-backup
```

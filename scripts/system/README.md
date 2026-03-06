# System Scripts

User-facing scripts for system administration tasks.

## Scripts

### `local-backup.sh`

A generic script to create and automatically prune rsync-based system backups. It is designed to be run non-interactively by a cron job.

#### Features
* **Incremental Backups**: Uses `rsync` with hard links (`--link-dest`) to create space-efficient incremental backups.
* **Automatic Pruning**: Automatically deletes the oldest backups, keeping a configurable number of recent copies.
* **Centralized Configuration**: All settings, including source/destination directories, retention policy, and exclusion patterns, are managed in `/etc/local-backup.conf`.
* **Cron-Friendly**: Operates silently, logging informational output to a file and only sending errors to `stderr` for email notifications.
* **Flexible Exclusions**: Supports a detailed list of files and directories to exclude from the backup, defined as a Bash array in the config file.

#### Requirements
* `bash` 4.0+
* `rsync`

#### Usage

The script is intended to be run without arguments, typically by a system scheduler like `cron`.

**1. Configuration:**

Create a configuration file at `/etc/local-backup.conf`.

```bash
# /etc/local-backup.conf

# The source directory to back up.
SOURCE_DIR="/"

# The main directory where all backups will be stored.
BACKUP_DIR="/mnt/storage/backup"

# Number of recent backups to keep.
KEEP_BACKUPS=12

# Bash array of rsync exclude patterns.
EXCLUDES=(
  "/dev"
  "/proc"
  "/sys"
  "/tmp"
  "/run"
  "/lost+found"
  "/mnt/*"
)

# (Optional) Path to the log file.
LOG_FILE="/var/log/local-backup.log"
```

**2. Execution:**

Run the script directly. It's recommended to run it as `root` to ensure it can read all system files.

```bash
sudo local-backup
```

**Example Cron Job:**

To run a backup every day at 4:05 AM, edit the root crontab (`sudo crontab -e`) and add the following line:

```bash
5 4 * * * /usr/local/bin/local-backup
```

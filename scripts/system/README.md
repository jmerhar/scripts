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

## `prune-orphaned-torrents`

Finds orphaned media files left behind by Sonarr/Radarr hard-linking and interactively removes the corresponding torrents from Deluge.

When the *arr apps hard-link a completed download from the torrent temp/seed folder into the organised library Plex reads from, deleting the media in Plex removes only the organised hard link. The temp copy is left behind with a link count of `1` — wasted space that keeps seeding forever. This script automates finding those files and removing the matching torrents.

### Features

* **Orphan Detection** — Scans the configured temp folders for files with a link count of `1` (no remaining hard link), the tell-tale sign that the organised copy was deleted.
* **Sidecar Exclusion** — Ignores non-media files that are never hard-linked (e.g. `*.nfo`, `*sample*`, artwork, subtitles, deleted scenes) via configurable glob patterns, so they are not mistaken for orphans.
* **Extra/Spam Filtering** — Ignores media files that are tiny relative to a torrent's main feature (configurable `MIN_MEDIA_RATIO`), so a leftover deleted-scenes clip or release-group advert can't flag a torrent whose real video is still in Plex.
* **Torrent Mapping** — Maps each orphaned file back to its torrent through the Deluge Web JSON-RPC API and prompts per torrent, removing the torrent and its data on confirmation.
* **Hard-Link Safe** — Offers to remove a torrent whenever *any* of its media files are orphaned, but warns and lists exactly which files would be freed vs kept when some are still hard-linked. Removing such a torrent frees only the orphaned copies; files still linked into Plex keep their other hard link and survive.
* **Stray File Cleanup** — Orphaned files that belong to no torrent at all (e.g. leftovers from a torrent that was already removed) are offered separately for direct deletion, and any folders left empty afterwards are pruned. Files that still belong to a live torrent are never deleted directly.
* **Interactive or Unattended** — Prompts `(y)es / (n)o / (a)ll / (q)uit` per torrent, with `--yes` to remove everything non-interactively and `--dry-run` to preview without changes.
* **Optional Path Translation** — Rewrites container-internal paths to local paths when Deluge runs in Docker and reports a different path prefix.
* **Centralized Configuration** — All settings live in a single config file (`/etc/prune-orphaned-torrents.conf`).

### Requirements

* `bash` 4.0+
* `curl`
* `jq`
* A reachable Deluge daemon with the **Web UI** enabled.

### Usage

All settings come from the configuration file.

**1. Configure** — Create `/etc/prune-orphaned-torrents.conf` (a [template](prune-orphaned-torrents.conf) is included). Because it stores the Deluge password, keep it private (`chmod 600`):

```bash
SCAN_DIRS=(
  /mnt/storage/temp/sonarr
  /mnt/storage/temp/radarr
)

EXCLUDE_PATTERNS=( "*sample*" "*.nfo" "*.srt" "*.sub" "*.idx" "*.md5" "*.sha" "*.sfv" "*.txt" "*.jpg" "*.jpeg" "*.png" "*.gif" "*.url" ".DS_Store" "._*" "Thumbs.db" "*deleted scenes*" "*deleted.scenes*" )

# Ignore media files smaller than this fraction of the torrent's largest media file:
MIN_MEDIA_RATIO=0.1

DELUGE_URL="http://127.0.0.1:8112/json"
DELUGE_PASSWORD="your-web-ui-password"
```

**2. Run:**

```bash
# Preview what would be removed:
prune-orphaned-torrents --dry-run

# Run interactively:
prune-orphaned-torrents
```

### Options

| Option | Description |
| --- | --- |
| `-n`, `--dry-run` | Show what would be removed without removing anything. |
| `-y`, `--yes` | Remove every matched torrent without prompting. |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging. |
| `-h`, `--help` | Show the help message. |

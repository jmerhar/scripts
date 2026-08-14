# `photo-backup`

Backs up photo collections from multiple storage devices to a remote server, safely merging content from all sources into one consolidated backup while preserving files unique to each.

### Features

* **Merge Overlapping Directories** — Safely syncs multiple source directories with similar structures (e.g., both containing `/Travel`) to a single destination.
* **Deletion Protection** — Uses rsync filter rules to ensure files present in any source are not accidentally deleted from the destination.
* **Highly Configurable** — All settings can come from a config file (`/etc/photo-backup.conf`) or command-line flags.
* **Detailed Logging** — Comprehensive logging with debug mode and optional log file output.
* **Dry-Run Mode** — Test the sync operation without making any changes.
* **macOS Cleanup** — Removes macOS-specific temporary files (`.DS_Store`, etc.) before backup.
* **Safety Checks** — Validates that source directories exist and are not empty.

### Upgrading to Version 2.0+

Version 2.0 introduced a breaking change to support multiple backup sources. If upgrading from an older version, update your configuration file (`/etc/photo-backup.conf`):

The old `SRC_1="..."` and `SRC_2="..."` variables are **deprecated**. Replace them with the new `SOURCES` array:

```bash
# Old format (deprecated):
SRC_1="/Volumes/PhotoStore"
SRC_2="/Volumes/MorePhotos"

# New format:
SOURCES=("/Volumes/PhotoStore" "/Volumes/MorePhotos")
```

The package upgrade attempts this migration automatically, saving a backup as `photo-backup.conf.bak`.

### Requirements

* `bash` 4.0+
* `rsync`
* SSH access to the backup server

### Usage

```bash
photo-backup \
  -s /Volumes/PhotoStore \
  -s /Volumes/MorePhotos \
  -s /Volumes/VacationPics \
  -H backup-server \
  -p /mnt/storage/photos
```

### Options

| Flag | Description |
|------|-------------|
| `-s PATH` | Source path (can be used multiple times). |
| `-H HOST` | Backup server hostname or IP. |
| `-p PATH` | Destination path on the server. |
| `-n` | Dry-run mode — show what would happen without making changes. |
| `-d` | Debug mode — enable verbose command logging. |
| `-l FILE` | Log all output to a file. |
| `-h` | Show help. |

### Example

```
[INFO]: Starting photo backup operation.
[INFO]: Found 3 source directories:
[INFO]:  -> /Volumes/PhotoStore
[INFO]:  -> /Volumes/MorePhotos
[INFO]:  -> /Volumes/VacationPics
[INFO]: Destination: aurora:/mnt/storage/photos
[INFO]: Cleaning temporary files in '/Volumes/PhotoStore'...
[INFO]: --- Starting backup for '/Volumes/PhotoStore' ---
[INFO]: Generating protection rules for '/Volumes/MorePhotos'
[INFO]: Generating protection rules for '/Volumes/VacationPics'
[INFO]: Backing up '/Volumes/PhotoStore' to 'aurora:/mnt/storage/photos'...
[INFO]: Backup operation completed successfully.
```

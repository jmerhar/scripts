# Photography Scripts

Utilities for managing photography workflows — intelligent backups and library cleanup. For installation instructions, see the [main README](../../README.md#installation).

## `photo-backup`

A robust backup solution for photographers managing multiple storage devices. It safely merges content from multiple sources into a consolidated backup on a remote server while preserving unique files from all sources.

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

| Flag | Description |
|------|-------------|
| `-s PATH` | Source path (can be used multiple times). |
| `-H HOST` | Backup server hostname or IP. |
| `-p PATH` | Destination path on the server. |
| `-n` | Dry-run mode — show what would happen without making changes. |
| `-d` | Debug mode — enable verbose command logging. |
| `-l FILE` | Log all output to a file. |
| `-h` | Show help. |

**Sample Output:**

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

---

## `remove-sidecars`

When shooting in RAW+JPEG mode, you get high-quality RAWs for editing and convenient JPEGs for quick previews. After a library grows to 100k+ photos, these sidecar JPEGs can consume hundreds of gigabytes for little long-term benefit. This script finds and deletes them.

### Features

* **Interactive** — Prompts for sidecar and RAW file extensions, with sensible defaults.
* **Safe** — Shows a summary of what will be deleted and asks for confirmation before proceeding.
* **Informative** — Reports how much disk space was recovered, broken down by RAW type.
* **Recursive** — Scans the specified directory and all subdirectories.

### Requirements

* `perl`
* `Term::ANSIColor` (Debian: `libterm-ansicolor-perl`)

### Usage

```bash
remove-sidecars [DIRECTORY]
```

If no directory is given, the current directory is used. Use `--help` for usage information.

```
$ remove-sidecars /path/to/my/photos

What extensions do your sidecars have? [JPG jpg JPEG jpeg] JPG jpg
What extensions do your raw photos have? [RW2 CR2 DNG dng] RW2 DNG
Scanning directory /path/to/my/photos
Scanning directory /path/to/my/photos/Travel
Scanning directory /path/to/my/photos/Events

Found sidecars of:
- 2 RW2 files
- 3 DNG files

Would you like to (d)elete them, (s)ee a list of directories, or (q)uit? [d/s/Q] d
Deleting /path/to/my/photos/Travel/IMG_174456.jpg (4.76 MB), a sidecar of RW2
Deleting /path/to/my/photos/Travel/IMG_171458.jpg (4.35 MB), a sidecar of RW2
Deleting /path/to/my/photos/Events/IMG_175816.jpg (3.75 MB), a sidecar of DNG
Deleting /path/to/my/photos/Events/IMG_165528.jpg (5.18 MB), a sidecar of DNG
Deleting /path/to/my/photos/Events/IMG_171956.jpg (4.33 MB), a sidecar of DNG

In total 22.37 MB of disk space was recovered:
- 9.11 MB of disk space was recovered from 2 RW2 sidecars (on average 4.56 MB per file).
- 13.26 MB of disk space was recovered from 3 DNG sidecars (on average 4.42 MB per file).
```

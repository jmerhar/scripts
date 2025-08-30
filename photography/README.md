# Photography Scripts

A collection of utilities for managing photography workflows. This directory includes scripts for intelligent backups and for cleaning up photo libraries.

## Scripts

### `photo-backup.sh`

A robust backup solution for photographers managing multiple storage devices. It safely merges content from two sources into a consolidated backup on a remote server while preserving unique files from both.

#### Features

* **Merge Overlapping Directories**: Safely syncs two source directories with similar structures (e.g., both containing `/Travel`) to a single destination.

* **Deletion Protection**: Uses an rsync filter to ensure that files present in either source are not accidentally deleted from the destination.

* **Highly Configurable**: All settings can be managed via a config file (`/etc/photo-backup.conf`) or command-line flags.

* **Detailed Logging**: Provides comprehensive logging with support for debug mode and optional log file output.

* **Dry-Run Mode**: Allows testing the sync operation without making any changes to files.

* **macOS Cleanup**: Intelligently cleans up macOS-specific temporary files (`.DS_Store`, etc.) before backup.

* **Safety Checks**: Includes validations to prevent running on empty source directories.

#### Requirements

* `bash` 4.0+

* `rsync`

* SSH access to the backup server

#### Dependencies

* `rsync`

#### Usage

The script can be configured entirely via command-line options.

**Basic Command:**

```bash
./photography/photo-backup.sh \
  -1 /Volumes/PhotoStore \
  -2 /Volumes/MorePhotos \
  -H backup-server \
  -p /mnt/storage/photos
```

**Common Options:**

| Flag | Description |
 | ----- | ----- |
| `-1 PATH` | Primary source path. |
| `-2 PATH` | Secondary source path. |
| `-H HOST` | Backup server hostname or IP. |
| `-p PATH` | Destination path on the server. |
| `-n` | **Dry-run mode**: show what would happen without making changes. |
| `-d` | **Debug mode**: enable verbose command logging. |
| `-l FILE` | Log all output to a custom log file. |

**Sample Output:**

```text
[INFO]: Starting photo backup operation.
[INFO]: Source 1: /Volumes/PhotoStore
[INFO]: Source 2: /Volumes/MorePhotos
[INFO]: Destination: aurora:/mnt/storage/photos
[INFO]: Cleaning temporary files in '/Volumes/PhotoStore'...
[DEBUG]: Running command: find /Volumes/PhotoStore -name .DS_Store -delete -print
[INFO]: Backing up '/Volumes/PhotoStore' to 'aurora:/mnt/storage/photos'...
sending incremental file list
...
sent 12.34G bytes  received 156.78k bytes  8.23M bytes/sec
total size is 250.11G  speedup is 20.26
[INFO]: Backup operation completed successfully.
```

---

### `remove-sidecars.pl`

When shooting in RAW+JPEG mode, you get high-quality RAWs for editing and convenient JPEGs for quick previews. Lightroom is smart enough to recognise these JPEGs as "sidecars" to the RAW files, which is great.

However, after a library grows to 100k+ photos, these sidecar files can take up a significant amount of disk space for little long-term benefit. This script was created to solve the problem of cleaning them up, freeing up hundreds of gigabytes of space.

#### Features

* **Interactive**: Prompts the user to define which file extensions are sidecars and which are RAW files, with sensible defaults.

* **Safe**: It shows a summary of what will be deleted and asks for confirmation before proceeding.

* **Informative**: Provides a detailed report at the end detailing how much disk space was recovered.

* **Recursive**: Scans the specified directory and all of its subdirectories.

#### Dependencies

* `perl`

* Debian/Ubuntu: `libterm-ansicolor-perl`

#### Usage

Run the script from your terminal, providing a path to the directory you want to scan. If no path is provided, it will scan the current directory.

You'll be prompted to provide a list of extensions for your sidecars and for your RAW photos. You can press Enter to accept the defaults or provide your own space-separated list. The script will then scan your photos, show a summary of the files it found, and ask you to confirm deletion.

```bash
# Run the script against a specific directory
$ ./photography/remove-sidecars.pl /path/to/my/photos

What extensions do your sidecars have? [JPG jpg JPEG jpeg] JPG jpg
What extensions do your raw photos have? [RW2 CR2 DNG dng] RW2 DNG
Scanning directory /path/to/my/photos
Scanning directory /path/to/my/photos/Travel
Scanning directory /path/to/my/photos/Events

Found sidecars of:
- 2 RW2 files
- 3 DNG files

Would you like to (d)elete them, (s)ee a list of directories, or (q)uit? [d/s/Q] y
Deleting /path/to/my/photos/Travel/IMG_174456.jpg (4.76 MB), a sidecar of RW2
Deleting /path/to/my/photos/Travel/IMG_171458.jpg (4.35 MB), a sidecar of RW2
Deleting /path/to/my/photos/Events/IMG_175816.jpg (3.75 MB), a sidecar of DNG
Deleting /path/to/my/photos/Events/IMG_165528.jpg (5.18 MB), a sidecar of DNG
Deleting /path/to/my/photos/Events/IMG_171956.jpg (4.33 MB), a sidecar of DNG

In total 22.37 MB of disk space was recovered:
- 9.11 MB of disk space was recovered from 2 RW2 sidecars (on average 4.56 MB per file).
- 13.26 MB of disk space was recovered from 3 DNG sidecars (on average 4.42 MB per file).
```

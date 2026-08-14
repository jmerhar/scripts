# `remove-sidecars`

When shooting in RAW+JPEG mode, you get high-quality RAWs for editing and convenient JPEGs for quick previews. After a library grows to 100k+ photos, these sidecar JPEGs can consume hundreds of gigabytes for little long-term benefit. This script finds and deletes them.

### Features

* **Interactive** — Prompts for sidecar and RAW file extensions, with sensible defaults.
* **Safe** — Shows a summary of what will be deleted and asks for confirmation before proceeding.
* **Informative** — Reports how much disk space was recovered, broken down by RAW type.
* **Recursive** — Scans the specified directory and all subdirectories.
* **Dry-Run Mode** — Preview what would be deleted without removing anything.

### Requirements

* `bash` 4.0+

### Usage

```bash
remove-sidecars [OPTIONS] [DIRECTORY]
```

If no directory is given, the current directory is used.

### Options

| Flag | Description |
|------|-------------|
| `-n`, `--dry-run` | Show what would be deleted without actually deleting. |
| `-C`, `--no-color` | Disable colored output. |
| `-h`, `--help` | Show help. |

### Example

```
$ remove-sidecars /path/to/my/photos

What extensions do your sidecars have? [JPG jpg JPEG jpeg] JPG jpg
What extensions do your raw photos have? [RW2 CR2 DNG dng] RW2 DNG
Scanning directory /path/to/my/photos
Scanning directory /path/to/my/photos/Travel
Scanning directory /path/to/my/photos/Events

Found sidecars for the following RAW types:
- 3 sidecars for DNG files
- 2 sidecars for RW2 files

Would you like to (d)elete them, (s)ee a list of directories, or (q)uit? [d/s/Q] d
Deleting /path/to/my/photos/Events/IMG_175816.jpg (3.75 MB), a sidecar for a DNG file
Deleting /path/to/my/photos/Events/IMG_165528.jpg (5.18 MB), a sidecar for a DNG file
Deleting /path/to/my/photos/Events/IMG_171956.jpg (4.33 MB), a sidecar for a DNG file
Deleting /path/to/my/photos/Travel/IMG_174456.jpg (4.76 MB), a sidecar for a RW2 file
Deleting /path/to/my/photos/Travel/IMG_171458.jpg (4.35 MB), a sidecar for a RW2 file

In total 22.37 MB of disk space was recovered:
- 13.26 MB by deleting 3 sidecars for DNG files (average 4.42 MB per file).
- 9.11 MB by deleting 2 sidecars for RW2 files (average 4.56 MB per file).
```

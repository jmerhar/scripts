# `compare-dirs`

Recursively compares two directories and reports differences in existence, size, timestamps, and checksums. Reports missing directories at the top level rather than enumerating all their contents.

### Features

* **Cross-platform** — Works on both macOS and Linux (auto-detects `stat`, `date`, and checksum tools).
* **Smart output** — Missing directories are reported once at the top level, not recursively enumerated.
* **Colored output** — Color-coded differences with directional markers; auto-disables when piped.
* **Selective comparison** — Size is always checked; timestamps and checksums are opt-in.
* **Symlink-aware** — Compares symlink targets rather than following them.
* **Type mismatch detection** — Reports when the same name is a file in one tree and a directory in the other.

### Requirements

* `bash` (macOS and Linux)
* `stat`, `date`, and a SHA-256 tool (`shasum` or `sha256sum`) — auto-detected per platform

### Usage

```bash
compare-dirs [OPTIONS] <dir1> <dir2>
```

### Options

| Flag | Description |
|------|-------------|
| `-t`, `--timestamps` | Also compare file modification times |
| `-c`, `--checksums` | Also compare file checksums (sha256) |
| `-i`, `--ignore-case` | Case-insensitive filename matching |
| `-d`, `--no-dotfiles` | Skip hidden (dot) files and directories |
| `-x`, `--exclude PAT` | Skip entries matching glob pattern (repeatable) |
| `--exclude-left PAT` | Suppress LEFT-only reports for matches (repeatable) |
| `--exclude-right PAT` | Suppress RIGHT-only reports for matches (repeatable) |
| `-n`, `--no-color` | Disable colored output |
| `-h`, `--help` | Show usage information |

### Example

```
$ compare-dirs -tc /srv/backup-old /srv/backup-new
Comparing:
  LEFT:  /srv/backup-old
  RIGHT: /srv/backup-new
─────────────────────────────────

← LEFT only:  archive/2023/
→ RIGHT only: logs/debug.log
≠ Size differs: data/users.db
    LEFT:  1,024 bytes
    RIGHT: 2,048 bytes
≠ Checksum differs: config/app.yaml

─────────────────────────────────
Summary: 1 only in LEFT, 1 only in RIGHT, 2 differences
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Directories are identical |
| `1` | Differences found |

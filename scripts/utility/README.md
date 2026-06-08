# Utility Scripts

General-purpose user-facing utilities. For installation instructions, see the [main README](../../README.md#installation).

## `compare-dirs`

Recursively compares two directories and reports differences in existence, size, timestamps, and checksums. Reports missing directories at the top level rather than enumerating all their contents.

### Features

* **Cross-platform** — Works on both macOS and Linux (auto-detects `stat`, `date`, and checksum tools).
* **Smart output** — Missing directories are reported once at the top level, not recursively enumerated.
* **Colored output** — Color-coded differences with directional markers; auto-disables when piped.
* **Selective comparison** — Size is always checked; timestamps and checksums are opt-in.
* **Symlink-aware** — Compares symlink targets rather than following them.
* **Type mismatch detection** — Reports when the same name is a file in one tree and a directory in the other.

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

---

## `unlock-pdf`

Decrypts a password-protected PDF file using [`qpdf`](https://github.com/qpdf/qpdf).

### Features

* **Simple** — Unlocks a PDF with a single command.
* **Safe Output** — Creates a new `*-unlocked.pdf` file, leaving the original untouched.
* **Input Validation** — Checks that the file exists and has a `.pdf` extension before processing.
* **Overwrite Protection** — Refuses to run if the output file already exists.
* **Secure** — Prompts for the password interactively (hidden input), keeping it out of shell history and the process list.
* **Dependency Detection** — Prints OS-specific installation instructions if `qpdf` is not found.

### Requirements

* [`qpdf`](https://github.com/qpdf/qpdf)

### Usage

```bash
unlock-pdf <input.pdf>
```

The script prompts for the password interactively:

```
$ unlock-pdf path/to/document.pdf
Password:
Writing path/to/document-unlocked.pdf...
Done.
```

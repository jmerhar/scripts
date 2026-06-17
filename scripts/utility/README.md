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

---

## `subtitle-sync`

Resynchronizes drifting subtitles to a video's actual speech. It transcribes the audio with [Whisper](https://github.com/openai/whisper) (via [`whisper-ctranslate2`](https://github.com/Softcatala/whisper-ctranslate2)) to build a speech-accurate reference, then aligns the drifted subtitle to it with [`alass`](https://github.com/kaegi/alass), which can apply a **different offset to each segment**. A final "anchor" pass cancels Whisper's small word-onset bias.

This handles the hard case that simple tools (ffsubsync, Bazarr) cannot: **segmented drift**, where broadcast rips have ad breaks cut out so subtitles fall progressively further behind in steps. It also handles the easy cases — a constant global offset, or a linear speed/framerate error.

### Features

* **Segment-aware** — Corrects accumulating ad-break drift, not just a single global shift.
* **Speech-referenced** — Uses a Whisper transcript as the alignment target, so it works even when the only available subtitle is itself out of sync (no second reference needed).
* **Self-protecting anchor** — Removes Whisper's ~0.5s onset bias, but stands down when the opening is genuinely offset, so global-offset subtitles are corrected rather than re-broken.
* **Sidecars and embedded** — Syncs external `.srt`/`.ass`/`.ssa`/`.vtt` sidecars in place (backing up the original); optionally extracts and syncs embedded tracks (`--embedded`), as a sidecar or remuxed into a container copy (`--remux`).
* **Language-aware** — Targets one language (English by default); only matching subtitles are synced.
* **Cached & idempotent** — Caches the (expensive) Whisper reference per video; skips already-synced files unless `--force`.
* **Timing stats** — Reports per-step (extract / transcribe / align), per-episode, and whole-batch durations, plus an average per episode — handy for estimating a large backlog.
* **Safe** — `--dry-run` previews the work; originals are backed up before being overwritten.

### Requirements

* [`ffmpeg`](https://ffmpeg.org/) / `ffprobe`
* [`alass`](https://github.com/kaegi/alass) — download a release binary onto your `PATH`.
* [`whisper-ctranslate2`](https://github.com/Softcatala/whisper-ctranslate2) — a faster-whisper CLI (needs Python ≥ 3.9):
  ```bash
  uv tool install whisper-ctranslate2     # or: pipx install whisper-ctranslate2
  ```

### Usage

```bash
subtitle-sync [OPTIONS] [PATH]
```

`PATH` may be a directory (processed recursively), a video file, or a subtitle file. Defaults to the current directory.

### Options

| Flag | Description |
|------|-------------|
| `--embedded` | Also sync embedded subtitle tracks (off by default) |
| `--remux` | With `--embedded`, mux the corrected track into a container copy instead of writing a sidecar |
| `-g`, `--lang LANG` | Target subtitle language (default `en`) |
| `-m`, `--model NAME` | Whisper model (default `base.en`); use a multilingual model for other languages |
| `-p`, `--split-penalty N` | alass split penalty; lower splits more aggressively (default `5`) |
| `--max-words N` | Reference cue granularity, words per line (default `8`) |
| `-t`, `--threads N` | CPU threads for Whisper/alass (default: detected) |
| `--no-anchor` | Disable the onset-bias anchor |
| `--anchor-max S` | Max opening shift (s) treated as bias before standing down (default `1.0`) |
| `--fps-guess` | Re-enable alass framerate guessing (for true speed/framerate drift) |
| `--backup-suffix S` | Suffix for the backed-up original (default `.bak`) |
| `-f`, `--force` | Reprocess even if already synced |
| `--video FILE` | The video to sync against (when `PATH` is a subtitle) |
| `--no-cache` | Do not use or refresh the Whisper reference cache |
| `-n`, `--dry-run` | Report what would be done; change nothing |
| `-C`, `--no-color` | Disable colored output |
| `-h`, `--help` | Show usage information |

### Drift types

| Drift type | Handling |
|------------|----------|
| Segmented / ad-break (accumulating steps) | Default |
| Constant global offset | Default (the anchor stands down for large opening shifts) |
| Wrong speed / framerate (linear drift) | Add `--fps-guess` (usually with `--no-anchor`) |

> **Note:** every sync runs a full Whisper transcription of the video's audio — accurate but CPU-intensive (roughly ⅓ of real-time per episode on a slow CPU). For a known, trivial global offset a one-line `ffmpeg`/`mkvmerge` shift is cheaper; this tool is the general solution.

### Example

```
$ subtitle-sync --dry-run "/media/tv/Taskmaster/Season 3"
[INFO]: Video: /media/tv/Taskmaster/Season 3/Taskmaster.S03E01...mkv
[INFO]: [dry-run] Would sync: .../Taskmaster.S03E01...en.srt (backup -> ....en.srt.bak)
...

$ subtitle-sync "/media/tv/Taskmaster/Season 3/Taskmaster.S03E01...mkv"
[INFO]: Video: .../Taskmaster.S03E01...mkv
[INFO]: Transcribing audio (base.en) — this is the slow step...
[INFO]: Transcribed in 15m 02s.
[INFO]: Synced: .../Taskmaster.S03E01...en.srt
[INFO]: Taskmaster.S03E01...mkv took 15m 09s (extract 6s, transcribe 15m 02s, align 1s)
[INFO]: Done: 1 synced, 0 skipped, 0 failed in 15m 09s. · avg 15m 09s/episode over 1
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All targeted subtitles synced (or skipped) |
| `1` | One or more subtitles failed, or invalid usage |

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

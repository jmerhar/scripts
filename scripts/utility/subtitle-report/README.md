# `subtitle-report`

Reports on subtitle coverage for a media library. For every media file it detects subtitles from two sources — embedded tracks inside the container (via `ffprobe`) and external sidecar files sharing the base name — and summarizes how many files have subtitles and in which languages, broken down by source.

### Features

* **Two sources** — Counts both embedded tracks and sidecar files, and can restrict to either.
* **Language breakdown** — Summarizes coverage by language, matched loosely (`en` = `eng` = `english`).
* **Coverage or gaps** — `--list` shows every file and its subtitles; `--missing` lists files lacking subtitles (or a specific language).
* **`und` handling** — `--und-as-english` folds undetermined tracks into English, for releases that ship an untagged English subtitle.
* **Configurable extensions** — Media and subtitle extensions can be overridden via a config file.
* **Colored output** — Auto-disables when piped.

### Requirements

* [`ffmpeg`](https://ffmpeg.org/) / `ffprobe`

### Usage

```bash
subtitle-report [OPTIONS] [DIRECTORY]
```

If no directory is given, the current directory is used. The summary is always printed; `--list` / `--missing` add a detailed section.

### Options

| Flag | Description |
|------|-------------|
| `-l`, `--list` | List every media file and the subtitles it has. |
| `-m`, `--missing` | List media files that have no subtitles at all. |
| `-g`, `--lang LANG` | Scope to one or more languages (repeatable and/or comma-separated, e.g. `en,und`). |
| `--no-embedded` | Skip embedded-track inspection (sidecars only; fast). |
| `--no-sidecars` | Skip sidecar files (embedded tracks only). |
| `--und-as-english` | Treat undetermined (`und`) subtitles as English. |
| `-C`, `--no-color` | Disable colored output. |
| `-h`, `--help` | Show usage information. |

> `--list` and `--missing` are mutually exclusive, as are `--no-embedded` and `--no-sidecars`.

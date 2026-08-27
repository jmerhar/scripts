# `subtitle-sync`

Resynchronizes drifting subtitles to a video's actual speech. It transcribes the audio with [Whisper](https://github.com/openai/whisper) (via [`whisper-ctranslate2`](https://github.com/Softcatala/whisper-ctranslate2)) to build a speech-accurate reference, then aligns the drifted subtitle to it with [`alass`](https://github.com/kaegi/alass), which can apply a **different offset to each segment**. Each subtitle is aligned both ways — as one global offset and in segments — and the two are scored against the transcript, so segments are only used when they measurably fit better.

This handles the hard case that simple tools (ffsubsync, Bazarr) cannot: **segmented drift**, where broadcast rips have ad breaks cut out so subtitles fall progressively further behind in steps. It also handles the easy cases — a constant global offset, or a linear speed/framerate error.

### Features

* **Segment-aware** — Corrects accumulating ad-break drift, not just a single global shift.
* **Speech-referenced** — Uses a Whisper transcript as the alignment target, so it works even when the only available subtitle is itself out of sync (no second reference needed).
* **Ad breaks detected, not assumed** — Segmented alignment can invent a break in a subtitle whose only fault is a constant offset, leaving an opening stretch further out than it started. Both alignments are scored against the speech and the segmented one is kept only when it wins; `--ad-breaks` overrides the verdict.
* **Leaves well alone** — A subtitle already matching the speech to within `--min-shift` is reported as such and not rewritten, rather than being nudged by Whisper's own ~0.3s lead.
* **Sidecars and embedded** — Syncs external `.srt`/`.ass`/`.ssa`/`.vtt` sidecars in place (backing up the original); optionally extracts and syncs embedded tracks (`--embedded`), as a sidecar or remuxed into a container copy (`--remux`).
* **Language-aware** — Targets one language (English by default); only matching subtitles are synced.
  A language may be given as a two- or three-letter ISO 639 code or by its English name — `vi`, `vie`
  and `vietnamese` all mean the same thing — and an untagged subtitle matches whichever language you
  asked for, since single-language releases are frequently untagged.
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
| `-g`, `--lang LANG` | Target subtitle language: ISO 639 code or English name (default `en`) |
| `-m`, `--model NAME` | Whisper model (default `base.en`); use a multilingual model for other languages |
| `-p`, `--split-penalty N` | alass split penalty; lower splits more aggressively (default `7`, alass's own). Not consulted by `--ad-breaks no` |
| `--max-words N` | Reference cue granularity, words per line (default `8`) |
| `-t`, `--threads N` | CPU threads for Whisper/alass (default: detected) |
| `--ad-breaks MODE` | `auto` scores both alignments and keeps the better, `yes` forces segments, `no` forces a single global offset (default `auto`) |
| `--min-shift S` | Smallest shift (s) worth rewriting a file for; below it the subtitle is reported as already in sync (default `0.5`, `0` to always rewrite) |
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
| Constant global offset | Default; add `--ad-breaks no` if a file is still wrongly split |
| Wrong speed / framerate (linear drift) | Add `--fps-guess` (which implies `--ad-breaks no`) |

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
[INFO]: Synced (4 segments, -7.4s to -0.7s): .../Taskmaster.S03E01...en.srt
[INFO]: Taskmaster.S03E01...mkv took 15m 11s (extract 6s, transcribe 15m 02s, align 2s)
[INFO]: Done: 1 synced, 0 already in sync, 0 skipped, 0 failed in 15m 11s. · avg 15m 11s/episode over 1
```

The success line says how the file was corrected, which is how a wrong verdict becomes visible: `single
offset` on a broadcast rip full of ad breaks, or several `segments` on a file that only ever needed one
shift, is the sign to re-run that title with `--ad-breaks`.

```
$ subtitle-sync "/media/tv/docu/Tofu"
[INFO]: Synced (single offset +4.1s): .../Tofu - S01E02 - Sex Talk (29 Jan 2015).en.srt
[INFO]: Already in sync (within 0.5s): .../Tofu - S01E04 - Coming Out (12 Feb 2015).en.srt
```

A subtitle reported as already in sync is left byte-for-byte alone and gets no `.bak`, so a later run
examines it again — cheap, since the Whisper reference is cached per video. `--dry-run` cannot say in
advance which files those will be: deciding needs the transcript, which is the step it skips.

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All targeted subtitles synced (or skipped) |
| `1` | One or more subtitles failed, or invalid usage |

# `transcode-audio`

A streaming rip usually carries its audio as Dolby Digital Plus, and a receiver fed over S/PDIF — or a TV app older than the codec — plays that as silence or as stereo. Re-encoding the audio to plain AC-3 fixes it, and nothing else about such a file needs changing.

So the whole job is one `ffmpeg` pass that copies every stream and re-encodes only the audio ones.

### Features

* **Keeps Everything Else** — Video, subtitles, chapters and attachments are copied, not re-encoded, and every track's language, title and default/forced flags come across untouched.
* **Every Audio Track** — Commentary and second-language tracks are converted too, rather than dropped. Each keeps its place in the track order.
* **Per-Track Bitrate** — Chosen from the channel count, since one figure cannot suit both a 5.1 feature track and a stereo commentary (defaults: 640k surround, 256k stereo).
* **Skips What Is Done** — A file whose audio is already entirely in the target codec is passed over, as is one this script has already converted.
* **Verified** — The result is probed before it takes its name: ffmpeg can exit `0` having copied the audio through when asked for an encoder it does not have, and a library of files labelled as converted but still unplayable is worse than a failure.
* **Seed-Safe** — Nothing is ever written through an existing file. The converted file is a new file, and `--replace` merely removes the original's name — so a torrent still seeding the original keeps it intact.
* **Asks Per File** — `(y)es / (N)o / (a)ll / (q)uit`, with `--yes` for a whole tree and `--dry-run` to preview.

### Requirements

* `bash` 4.0+
* `ffmpeg` (with `ffprobe`)
* `jq`

### Usage

```bash
transcode-audio [OPTIONS] [PATH]
```

`PATH` may be a single `.mkv` file or a directory, which is searched recursively. If omitted, the current directory is used.

```bash
# What in this season needs converting?
transcode-audio --dry-run "/mnt/storage/tv/uk/Show/Season 1"

# Convert it, keeping the originals:
transcode-audio "/mnt/storage/tv/uk/Show/Season 1"

# Convert and drop the originals, unattended:
transcode-audio --replace --yes "/mnt/storage/tv/uk/Show/Season 1"
```

### Options

| Option | Description |
| --- | --- |
| `-f`, `--format CODEC` | Target audio codec (default `ac3`); anything ffmpeg can encode. |
| `-b`, `--bitrate RATE` | Bitrate for surround tracks (default `640k`). |
| `--stereo RATE` | Bitrate for mono and stereo tracks (default `256k`). |
| `-r`, `--replace` | Delete the original once the converted file is verified. |
| `-y`, `--yes` | Do not ask; convert every file that needs it. |
| `-n`, `--dry-run` | Report what would be converted without encoding anything. |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging, including the ffmpeg command. |
| `-h`, `--help` | Show the help message. |

### Naming

The converted file is named after the original with a `<CODEC>.CC` marker: it replaces the source codec's own token where the release name carries one (`DDP5.1`, `DD+`, `EAC3`, `AAC2.0`, …), sits before the release group where it does not, and goes at the end otherwise. Only the file name is rewritten — a codec token in a parent directory's name is not this file's to correct.

```
Show.S01E01.1080p.WEB.DDP5.1.H264-GRP.mkv  ->  Show.S01E01.1080p.WEB.AC3.CC.H264-GRP.mkv
under.the.vines.s01e01.1080p.web.h264-ggez.mkv  ->  under.the.vines.s01e01.1080p.web.h264.AC3.CC-ggez.mkv
```

### Example

```
$ transcode-audio --dry-run "/mnt/storage/tv/uk/Show/Season 1"
Show.S01E01.1080p.WEB.DDP5.1.H264-GRP.mkv: eac3 6
  would write Show.S01E01.1080p.WEB.AC3.CC.H264-GRP.mkv
Show.S01E02.1080p.WEB.AC3.H264-GRP.mkv: already ac3 (ac3 6)

2 file(s) examined; 1 carry audio that is not ac3.
Would convert 1 file(s).
```

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | The scan completed; anything asked for was converted. |
| `1` | An encode failed, a required tool is missing, or the path or settings were unusable. |

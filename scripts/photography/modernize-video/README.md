# modernize-video

Converts video from old cameras into H.264/AAC MP4 while carrying the capture date across, so the
result lands in the right place in a photo timeline instead of at the moment it was uploaded.

A compact camera or an early phone wrote MJPEG, Indeo, MPEG-1 or H.263 into an AVI, MPG, 3GP or MOV.
Google Photos accepts none of those, and the capture date sits in a container field nothing downstream
reads. The footage is the part that cannot be re-shot and the date is the part that cannot be
reconstructed, so both are treated as the point of the exercise rather than as metadata.

### Features

- **Keeps the capture date, without shifting it.** An AVI records its date in `IDIT` as a naive local
  wall clock. ffmpeg reads that as host-local and writes UTC, so copying metadata across moves every
  date by whatever offset the converting machine happens to be at — a different answer in winter than
  in summer, and for a clip shot just after midnight a different day or even a different year. The date
  is resolved first and written explicitly, so the wall clock the source shows is the wall clock the
  result shows.
- **Distrusts an implausible date.** An MP4 header that was never filled in reads back as the epoch.
  A clip stamped 1970 sorts to the very start of a timeline, which is the failure being fixed, so a
  date outside a plausible range is treated as absent and the file's modification time is used instead.
- **Says where every date came from.** Each file is reported as `[embedded]`, `[mtime]` or `[given]`.
- **Decides from the codecs, not the file name.** Already-modern files are reported and left alone,
  files whose streams are fine but whose container is not are rewrapped losslessly, and everything else
  is re-encoded. A 3GPP file carrying an `.mp4` extension is therefore rewrapped rather than mistaken
  for a finished one.
- **Never skips anything silently.** Every file ends in a reported outcome: converted, rewrapped,
  already modern, undated, unreadable or failed, and the counts add up to the number examined.
- **Reports what it found before asking.** The directory searched and the number of candidates are
  printed before the first prompt, since that prompt offers `(a)ll`.
- **Checks the result before keeping it.** ffmpeg exiting zero is not proof: asked for an encoder it
  does not have, it can copy the stream through instead. The converted file's codec, duration and date
  are all read back before it takes its final name.

### Requirements

- `ffmpeg` and `ffprobe`
- `jq`
- Bash 4.0 or newer

### Usage

```bash
./modernize-video.sh [OPTIONS] PATH
```

`PATH` may be a single video file or a directory, which is searched recursively. It is required; pass
`.` for the current directory.

### Options

| Option | Description |
|---|---|
| `-q`, `--crf N` | Quality, lower is better (default `18`); 18 is visually transparent. |
| `--preset NAME` | x264 preset (default `slow`). |
| `-b`, `--audio-bitrate R` | Bitrate for stereo audio (default `192k`); mono gets half. |
| `--date WHEN` | Stamp every file with this date instead of reading one. Either `YYYY-MM-DD HH:MM:SS` or `YYYY-MM-DD`, which means midday. |
| `--no-mtime` | Do not fall back to a file's modification time; report it as undated instead. |
| `-r`, `--replace` | Delete the original once the converted file is verified. |
| `-y`, `--yes` | Do not ask; convert everything that needs it. |
| `-n`, `--dry-run` | Report what would be done without converting anything. |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging, including the ffmpeg command. |
| `-h`, `--help` | Show the help message. |

### How the date is chosen

In order, stopping at the first that works:

1. `--date`, when given.
2. The file's embedded `creation_time`, if it is a plausible capture date — a well-formed time between
   `MIN_YEAR` (1990 by default) and next year.
3. The file's modification time, unless `--no-mtime`.

A trailing `Z` or zone offset is **dropped, never applied**. Converting between zones would need the
zone the camera was in, which nothing records, and would move a clip shot near midnight onto the wrong
day. Keeping the wall clock is also the only rule that is stable, repeatable, and agrees with what every
other tool already shows for that file.

`--no-mtime` matters where modification times have been destroyed — a folder that has been through a
file-sync client, for instance, where every file was written yesterday. There, a modification time is
not a worse date than the embedded one; it is a wrong one, and being told the file is undated is more
useful than being given yesterday.

### What happens to a file

The plan comes from the streams ffprobe finds, and from the container's own brand rather than its
extension:

| Streams | Container | Outcome |
|---|---|---|
| H.264/HEVC with AAC, or no audio | MP4 | already modern — reported, left alone |
| H.264/HEVC with AAC, or no audio | anything else | rewrapped with a stream copy, losing nothing |
| anything else | any | re-encoded |

### Example

Look over a folder without changing anything:

```bash
./modernize-video.sh --dry-run ~/photos/2006
```

Convert a whole archive, keeping the originals:

```bash
./modernize-video.sh --yes ~/photos
```

Convert a folder whose modification times are meaningless and whose files carry no date of their own,
stamping them all with the day they were shot:

```bash
./modernize-video.sh --yes --date 2005-08-15 ~/photos/kanarski
```

### Notes

- Re-encoding is lossy and cannot be undone, so the original is kept unless `--replace` is given, and
  the replacement is only ever moved into place after it has been checked.
- The converted file is written beside the original with an `.mp4` extension. A source already called
  `.mp4` that still needs work gets a `.converted.mp4` name instead, because the plain one is the source
  itself — and on a case-insensitive filesystem `X.MP4` and `X.mp4` are one file.
- The frame rate is never forced. A stream can misreport it, and MPEG-1 from these cameras reports
  double its real rate, so reading that figure back would stretch the whole recording.
- The converted file's modification time is set to its capture date, which also repairs the timestamps
  a sync client flattened. Since the output is backdated, `find -newermt` will not list it.
- Only the video and audio are carried over; subtitle tracks and chapters are not. That is why
  Matroska and DVD VOB are absent from the default extensions — a run over a film library would rewrap
  its files and leave their subtitles behind.

### Exit Codes

| Code | Meaning |
|---|---|
| 0 | Every file that needed converting was converted, or there was nothing to do. |
| 1 | A conversion failed, or the configuration or command line was unusable. |

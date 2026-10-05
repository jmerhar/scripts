# `dovi-active-area`

A Dolby Vision file's L5 metadata block states where the picture sits inside the frame. A 2.39:1 film delivered in a 16:9 container legitimately declares the letterbox bars it contains — but some displays act on that by zooming, or by adding bars of their own, and the picture arrives cropped or twice-boxed. Zeroing the active area leaves the encoded frame untouched and tells the display to show all of it.

Whether a declared active area is wrong is a judgement about a particular file on particular hardware, so this script reports by default and rewrites only what it is told to.

### Features

* **Reports First** — Lists every Dolby Vision file, its profile, and the active area it declares. Files without Dolby Vision metadata are counted and passed over.
* **No Re-encoding** — The repair goes through the RPU: extract the video track, extract its RPU, zero the active area, inject it back, remux. The picture is never touched, so it costs no quality.
* **Verified Before Replacing** — The rewritten RPU is read back and must report a zeroed active area before the original is replaced. A failure at any step — a full disk, a killed run, a file `dovi_tool` cannot parse — costs the work but not the file.
* **Timing Preserved** — A raw HEVC bitstream carries no container timing, so the remux restates the video track's default duration, language and name from the source. Without that, mkvmerge guesses the frame rate and a wrong guess desynchronises every audio track in the file.
* **Hard-Link Aware** — Warns when the file has more than one name: the rewrite lands on a new inode, so the other names keep the file as it was, and the disk gains a second copy.
* **Asks Per File** — `(y)es / (N)o / (a)ll / (q)uit` per file, with `--yes` for a whole tree unattended and `--dry-run` to preview.

### Requirements

* `bash` 4.0+
* `mediainfo`, `jq`, `ffmpeg` — for the report
* `mkvtoolnix` (`mkvextract`, `mkvmerge`) — for the rewrite
* [`dovi_tool`](https://github.com/quietvoid/dovi_tool) — `brew install dovi_tool` on macOS. Debian has no package: download a release binary onto your `PATH`, or point `DOVI_TOOL_BIN` at it in the config file.

### Usage

```bash
dovi-active-area [OPTIONS] PATH
```

`PATH` may be a single `.mkv` file or a directory, which is searched recursively. It is required; pass `.` for the current directory.

```bash
# What does my film library declare?
dovi-active-area /mnt/storage/films

# Repair one title, keeping the original alongside:
dovi-active-area --fix --keep-original "Peaky Blinders.mkv"

# Repair a whole tree unattended:
dovi-active-area --fix --yes /mnt/storage/films
```

### Options

| Option | Description |
| --- | --- |
| `-f`, `--fix` | Zero the active area of files that declare one, asking first. |
| `-y`, `--yes` | With `--fix`, do not ask; act on every file that declares one. |
| `-k`, `--keep-original` | With `--fix`, keep the original alongside as `<name>.orig`. |
| `-n`, `--dry-run` | Report, and name what `--fix` would rewrite, without writing. |
| `-s`, `--sample SECONDS` | Seconds of video sampled when reading the metadata (default `10`). |
| `--frame N` | Frame within that sample to read (default `100`). |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging, including each tool invocation. |
| `-h`, `--help` | Show the help message. |

### Configuration

Optional; every setting has a default. A [template](dovi-active-area.conf) is included — `SAMPLE_SECONDS`, `PROBE_FRAME`, `WORK_DIR`, `DOVI_TOOL_BIN` and `LOG_FILE`.

`WORK_DIR` is worth knowing about: left unset, each file is rewritten in a hidden temporary directory beside itself, which keeps the intermediates on the same filesystem as the file — there is room for them there, and the finished remux replaces the original with a rename rather than a copy. Point it elsewhere only if you have a scratch disk with room for the video track twice over.

### Example

```
$ dovi-active-area /mnt/storage/films
Peaky.Blinders.The.Immortal.Man.2026.2160p.DV.HDR10.mkv: dvhe.08, active area 0 0 210 210 (left right top bottom)
Another.Film.2024.2160p.DV.mkv: dvhe.08, no active area declared

2 Dolby Vision file(s) of 37 examined; 1 declare an active area.
35 file(s) carried no Dolby Vision metadata.
Pass --fix to zero the active area of those files.
```

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | The scan completed; anything asked for was rewritten. |
| `1` | A rewrite failed, a required tool is missing, or the path or settings were unusable. |

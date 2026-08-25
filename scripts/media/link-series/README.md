# `link-series`

The *arr apps hard-link everything they import, so the library and the download folder share one copy of each episode. Anything acquired outside them — a manual download, a season pack no indexer announced, a file dropped in by hand — stays where it landed, and copying it into the library would double the space it takes. This links it instead.

The show and the season come from the destination directory rather than from arguments: run it inside a season folder and it looks for that season, or inside a show folder and it takes any season of that show.

### Features

* **Context-Aware** — Reads the show from the destination folder and the season from its name (`Season 15`, `Season.15`, or `Specials` for season 0), so a run needs no arguments.
* **Punctuation-Blind Matching** — A release is matched as the show's words followed by the season, case-insensitively, with the punctuation between the words uncompared: `Agatha Christie's Marple` matches `Agatha.Christies.Marple`, and `Alan Davies - As Yet Untitled` matches `Alan.Davies.As.Yet.Untitled`. A library folder's trailing disambiguating year (`Alice (2009)`) is optional in the release name.
* **No Bleed Between Similar Titles** — Because the season has to follow the title directly, a run in `QI` does not collect `QI.XL` releases, and one in `Alice` does not collect `Alice in Borderland`.
* **Season Spellings** — `S15`, `Season 15` and `15x07` all count, with any zero padding, so a `Season 1` folder takes both `S1E03` and `S01E04`.
* **Season Packs** — Matches each file's path below the download folder, not just its name, so episodes inside a release folder named after the show are found.
* **Quality Filter** — `--quality 1080p` links one quality when several were downloaded.
* **Space-Saving** — Hard links by default, with `--symlink` for when the download folder and the library are on different filesystems.
* **Repeatable** — A file already in the destination is left alone, so a second run links only what is new.
* **Dry-Run Mode** — Preview what would be linked without creating anything.

### Requirements

* `bash` 4.0+

### Usage

**1. Configure** — Create `/etc/link-series.conf` (a [template](link-series.conf) is included) naming the folder to search:

```bash
TEMP_DIR="/mnt/storage/temp/sonarr"
```

**2. Run** from the folder the episodes should end up in:

```bash
cd "/mnt/storage/tv/uk/Taskmaster/Season 15"
link-series --dry-run          # see what would be linked
link-series                    # link it
```

Or point it at the folder instead:

```bash
link-series -q 1080p "/mnt/storage/tv/uk/Taskmaster/Season 15"
```

### Options

| Option | Description |
| --- | --- |
| `-t`, `--temp-dir DIR` | Search `DIR` for episodes instead of the configured `TEMP_DIR`. |
| `-q`, `--quality Q` | Only link releases whose name contains `Q` (e.g. `1080p`, `720p`). |
| `-s`, `--symlink` | Create symbolic links instead of hard links. |
| `-n`, `--dry-run` | Show what would be linked without linking anything. |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging, including the search pattern. |
| `-h`, `--help` | Show the help message. |

### Example

```
$ cd "/mnt/storage/tv/uk/Taskmaster/Season 16"
$ link-series --temp-dir /mnt/storage/temp -q 720p
Linked Taskmaster.S16E01.720p.ALL4.WEB-DL.AAC2.0.H.264-RNG.mkv
Linked Taskmaster.S16E02.720p.ALL4.WEB-DL.AAC2.0.H.264-RNG.mkv
Skipping Taskmaster.S16E03.720p.ALL4.WEB-DL.AAC2.0.H.264-RNG.mkv (already in the destination)
Linked 2 file(s) for Taskmaster season 16, skipped 1 already present.
```

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Everything that matched was linked, or nothing matched. |
| `1` | A link failed, or the destination or download folder was unusable. |

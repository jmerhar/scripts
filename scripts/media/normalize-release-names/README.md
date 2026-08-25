# `normalize-release-names`

A folder of episodes acquired from different places is spelled several ways: spaces in one release, underscores in the next, mixed case in a third, and a season-episode number written as `1x02` where the rest of the library uses `S01E02`. Nothing is wrong with any of them until something has to match them — a subtitle sidecar pairing by base name, a link into a season folder, a media server's episode parser — and then the odd one out is the file that goes missing.

### Features

* **One Spelling** — Spaces and underscores become dots, runs of separators collapse to one, and the case is folded to lower with the `S01E02` marker left upper, which is how every parser looks for it.
* **Episode Numbers** — `1x02` and `S1E02` both become `S01E02`.
* **Sidecars Included** — Subtitles and `.nfo` files are renamed alongside the video, because a sidecar that stops matching its video's base name stops being found.
* **Dashes Left Alone** — A release group is written after a dash, and joining that up would lose the boundary.
* **Never Guesses** — Only separators, case and the episode marker change. A rename that reorganised a name would be a rename nobody could review.
* **Refuses Collisions** — A rename that would land on an existing name is reported and skipped: the two files are different releases of the same episode as often as they are duplicates, and choosing between them is not this script's decision.
* **Asks Per File** — `(y)es / (N)o / (a)ll / (q)uit`, with `--yes` and `--dry-run`.

### Requirements

* `bash` 4.0+

### Usage

```bash
normalize-release-names [OPTIONS] [PATH]
```

Only the given directory's own files are renamed unless `--recursive` is passed. If no directory is given, the current directory is used.

```bash
# See what it would do:
cd "/mnt/storage/tv/uk/Taskmaster/Season 15"
normalize-release-names --dry-run

# Do it:
normalize-release-names --yes
```

### Options

| Option | Description |
| --- | --- |
| `-r`, `--recursive` | Descend into subdirectories. |
| `-k`, `--keep-case` | Leave the case alone; only separators and the episode number change. |
| `-y`, `--yes` | Rename without asking. |
| `-n`, `--dry-run` | Show the renames without performing them. |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging. |
| `-h`, `--help` | Show the help message. |

### Example

```
$ normalize-release-names --dry-run
Some Show 1x02 The Episode.mkv -> some.show.S01E02.the.episode.mkv
Some_Show_1x03_Another.mkv -> some.show.S01E03.another.mkv
Some.Show.S01E04.Fine.Already-GRP.mkv is left alone

3 file(s) examined; would rename 2.
```

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Every rename asked for was performed, or there was nothing to do. |
| `1` | A rename was refused because the name was taken, or a rename failed. |

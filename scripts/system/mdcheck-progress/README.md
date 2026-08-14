# `mdcheck-progress`

Reports the progress of a Linux MD RAID `check` (the monthly `mdcheck` scrub on Debian/Ubuntu), **including while it is paused** between nightly windows — which `/proc/mdstat` and `mdadm --detail` cannot show — and estimates when it will finish.

Debian's scrub runs via `mdcheck_start.timer` (first Sunday of the month) and `mdcheck_continue.timer` (a fixed window every night), pausing the check when each window closes. While paused, the only record of progress is the sector offset `mdcheck` saves under `/var/lib/mdcheck/`; this tool reads it and turns it back into a percentage.

### Features

* **Works while paused** — Reads the saved checkpoint offset, so it reports a percentage during the day when no window is running.
* **Schedule-aware ETA** — Estimates the finish time from the average speed achieved *while checking* (progress ÷ active time spent inside past windows), projected across future nightly windows. The window length and start time are read from the `mdcheck` `systemd` units, so the estimate lands inside a real window rather than mid-day.
* **Stateless** — Keeps no history file; every run recomputes from current on-disk state, so it follows the schedule if it changes.
* **Live when active** — During a running window it shows the current speed from `/proc/mdstat`.
* **No root required** — Reads `sysfs`, the world-readable checkpoint, and `systemctl show`.

### Requirements

* `bash` 4.0+
* `mdadm`, with the `mdcheck` `systemd` timers (Debian/Ubuntu)

### Usage

```bash
mdcheck-progress [OPTIONS] [ARRAY...]
```

`ARRAY` may be given as `md0` or `/dev/md0`. With no `ARRAY`, every array is reported.

### Options

| Flag | Description |
| --- | --- |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging. |
| `-h`, `--help` | Show the help message. |

### Example

```
$ mdcheck-progress
md0 (raid5) — monthly check
  progress     86.6%  (6.30 TiB / 7.28 TiB per device)
  state        paused (idle between nightly windows)
  rate         161 MB/s while checking
  schedule     6 h nightly, next window Tue 00:22
  est. finish  Tue 2026-08-04 02:13 CEST  (1 more window)
```

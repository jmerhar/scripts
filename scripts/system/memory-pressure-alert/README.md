# `memory-pressure-alert`

Warns while a Mac is filling up — swap growing, free memory falling — rather than once it has already stalled, and names the applications responsible.

macOS does not run out of memory so much as slide into it: pages compress, swap grows, and the machine stays usable for days. Then free swap reaches zero and everything stalls at once, with a load average in the hundreds and every process blocked. This tool watches the numbers that move beforehand.

### Features

* **Watches the readings that actually predict the stall** — swap in use (the leading indicator, near zero on a healthy machine and accruing over days of uptime), the kernel's own free-memory percentage, and compressed memory. "Memory used" is deliberately ignored: it sits near the installed total at all times and cannot warn about anything.
* **Names the cause, measured correctly** — reports the heaviest applications by resident **plus compressed** memory. Resident size alone is actively misleading: a browser holding tens of gigabytes across dozens of helpers reports a few hundred megabytes each, so the real cause looks innocent while an idle background process looks guilty.
* **Blames the application, not the process** — totals are aggregated per command name, turning 56 renderers into one line.
* **Quiet by default** — raises nothing and exits 0 while healthy, so it suits a `launchd` agent running every few minutes. (One `[INFO]` line naming the config file it read is logged per run, from the shared config loader.)
* **Fails safe** — an unreadable reading counts as healthy. Running unattended, a false alarm every few minutes trains you to ignore the real one.

### Requirements

* `bash` (baseline; no version-specific features)
* macOS — reads `vm.swapusage`, `kern.memorystatus_level`, `vm_stat` and `top`, and notifies through `osascript`

### Usage

```bash
memory-pressure-alert [OPTIONS]
```

### Options

| Flag | Description |
| --- | --- |
| `-s`, `--swap-mb MB` | Warn at this much swap in use (default: `2048`). |
| `-p`, `--pressure PERCENT` | Warn when free memory falls to this percentage or below (default: `25`). |
| `-c`, `--compressor MB` | Warn at this much compressed memory (default: `8192`). |
| `-r`, `--report` | Print the current readings and the heaviest applications, then exit 0 whatever the values. |
| `-n`, `--no-notify` | Print the alert to stdout instead of sending a notification. |
| `--no-color` | Disable coloured output. |
| `-d`, `--debug` | Enable verbose debug logging. |
| `-h`, `--help` | Show the help message. |

### Example

Check the current state without waiting for a threshold:

```
$ memory-pressure-alert --report
swap 0 MB · free 77% · compressed 4731 MB
   22292 MB   56 proc  Google
    7908 MB    5 proc  idea
    5362 MB    1 proc  sublime_text
```

Run it from a `launchd` agent every five minutes, at `~/Library/LaunchAgents/si.merhar.memory-pressure-alert.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>si.merhar.memory-pressure-alert</string>
  <key>ProgramArguments</key> <array><string>/opt/homebrew/bin/memory-pressure-alert</string></array>
  <key>StartInterval</key>    <integer>300</integer>
  <key>RunAtLoad</key>        <true/>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/si.merhar.memory-pressure-alert.plist
```

A swap-based alarm goes quiet for a while after a reboot and creeps back as uptime grows. That is the point: it is telling you the machine is filling up again, and the usual answer is a restart rather than hunting a culprit.

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Healthy, or a report was printed. |
| `1` | Usage error. |
| `2` | A threshold was crossed and an alert was raised. |

# `memory-pressure-alert`

Warns while a Mac is filling up — swap growing, memory use climbing — rather than once it has already stalled, and names the applications responsible.

macOS does not run out of memory so much as slide into it: pages compress, swap grows, and the machine stays usable for days. Then free swap reaches zero and everything stalls at once, with a load average in the hundreds and every process blocked. This tool watches the numbers that move beforehand.

### Features

* **Watches the readings that actually predict the stall** — swap in use (the leading indicator, near zero on a healthy machine and accruing over days of uptime), memory used, and compressed memory. Free memory is deliberately ignored: macOS lends almost all of it to the file cache and reclaims it on demand, so it sits near zero on a perfectly healthy machine.
* **Counts used memory the way Activity Monitor and Stats do** — anonymous, wired and compressed pages, with the file cache and purgeable pages excluded because the kernel takes those back at will. A naive total-minus-free reads about 99% on any Mac and says nothing; this figure agrees with what the menu bar shows.
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
| `-u`, `--used PERCENT` | Warn at this much of RAM in use (default: `85`). |
| `-c`, `--compressor MB` | Warn at this much compressed memory (default: `8192`). |
| `-r`, `--report` | Print the current readings and the heaviest applications, then exit 0 whatever the values. |
| `-n`, `--no-notify` | Print the alert to stdout instead of sending a notification. |
| `--install` | Install a `launchd` agent that runs the check periodically, and load it. |
| `--uninstall` | Unload the `launchd` agent and remove it. |
| `-i`, `--interval SECONDS` | How often the agent runs, with `--install` (default: `300`). |
| `--no-color` | Disable coloured output. |
| `-d`, `--debug` | Enable verbose debug logging. |
| `-h`, `--help` | Show the help message. |

### Example

Check the current state without waiting for a threshold:

```
$ memory-pressure-alert --report
swap 0 MB · used 71% · compressed 6959 MB
   13341 MB   52 proc  Google
    3432 MB    1 proc  idea
     796 MB    6 proc  Signal
```

Install it as a `launchd` agent so it keeps watch on its own:

```
$ memory-pressure-alert --install
[INFO]: Installed — runs /opt/homebrew/bin/memory-pressure-alert every 300s.
[INFO]: Agent: ~/Library/LaunchAgents/si.merhar.memory-pressure-alert.plist
[INFO]: Log:   ~/Library/Logs/si.merhar.memory-pressure-alert.log
```

The agent runs every five minutes by default; `--interval` changes that, and installing again is how
an existing agent is retimed — the old one is unloaded first, so rewriting the file alone would leave
the previous schedule in force.

Thresholds are not baked into the agent. It reads the config file at every run like any other
invocation, so tuning one is a matter of editing `$(brew --prefix)/etc/memory-pressure-alert.conf`
and nothing else.

`USED_WARN_PERCENT` replaces the earlier `PRESSURE_WARN_PERCENT`. The reading it governs changed from
free memory to used memory, so the threshold's meaning inverted and an old setting cannot be carried
over — the script refuses the old key and says so rather than applying a number that would now mean
the opposite.

Both streams are redirected to a log file, because a `launchd` agent's output is otherwise discarded
and there would be no way to find out why an alert never arrived.

`--uninstall` unloads the agent and removes its plist, and says so rather than failing when there is
nothing installed.

A swap-based alarm goes quiet for a while after a reboot and creeps back as uptime grows. That is the point: it is telling you the machine is filling up again, and the usual answer is a restart rather than hunting a culprit.

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Healthy, a report was printed, or the agent was installed or removed. |
| `1` | Usage error, or the agent could not be loaded. |
| `2` | A threshold was crossed and an alert was raised. |

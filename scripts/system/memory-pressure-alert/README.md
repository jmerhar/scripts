# `memory-pressure-alert`

Warns while a Mac is filling up — swap growing, memory use climbing — rather than once it has already stalled, and names the applications responsible.

macOS does not run out of memory so much as slide into it: pages compress, swap grows, and the machine stays usable for days. Then free swap reaches zero and everything stalls at once, with a load average in the hundreds and every process blocked. This tool watches the numbers that move beforehand.

### What the readings mean

Three figures are reported together — an alert carries all of them and marks the one that crossed its threshold with ⚠ — because none of them can be acted on alone.

| Reading | What it is |
| --- | --- |
| **used** | How much of RAM is in use, counted the way Activity Monitor and Stats count it: anonymous, wired and compressed pages, less the file cache and purgeable pages the kernel reclaims on demand. A healthy Mac runs high here — 70% is unremarkable — because macOS lends every spare page to the cache rather than leaving it idle. |
| **swap** | How much has been written out to disk, in GB. The one reading that is near zero on a healthy Mac, and it accrues over days of uptime, so it gives the earliest warning. Once free swap reaches zero the machine stalls outright. The percentage `--report` shows beside it is that size as a share of installed RAM — the same denominator the other two readings use, so it says how much of *this* machine has been pushed to disk. |
| **compressed** | How much of RAM the kernel is holding squeezed in place instead of paging it out, since RAM is faster than disk. It is **already part of `used`**, so it is not memory consumed on top of that figure, and a third of RAM is ordinary. Read it as how hard the machine is working to stay out of swap: high with empty swap means the compressor is coping; high alongside growing swap means it has run out of room to squeeze. |

So "62% compressed" on its own is not a verdict. Beside `swap 0 MB` it says the compressor is absorbing a heavy but survivable load; beside `swap 6000 MB` it says the machine is nearly out of ways to postpone the stall.

### Why shares rather than sizes

Memory, the compressor and the applications are reported as shares of installed RAM. Two reasons, and they are the same reason: a size only means something to a reader who remembers how much memory the machine has, and a threshold written as a size only fits the machine it was chosen on. What a healthy Mac holds compressed grows with the RAM it has, so `8192 MB` is deafening on an 8 GB laptop and silent on a 64 GB one, while `50%` fits both.

Swap stays a size. What makes swap dangerous does not scale with RAM: a healthy machine of any size sits near zero, so a modest absolute figure is already a signal everywhere, and each page written costs the same disk round trip whatever the total. A share of RAM would only make the threshold late on large machines; a share of the swap file itself would say nothing at all, since macOS grows that file on demand and the used-to-total ratio therefore stays roughly constant however bad things get.

Every size is shown in gigabytes to one decimal place, because these figures run to five digits in megabytes and only the leading two carry meaning — `24.9 GB` is read at a glance where `25450 MB` is not. The swap threshold is nevertheless set in whole megabytes (`SWAP_WARN_MB`, `--swap-mb`), which tunes it more finely than the display shows and keeps the comparison exact integer arithmetic.

`--report` prints both forms of every figure, since it is read deliberately and has the room. An alert gives one — the form its threshold is written in, so it speaks the same units as the config file it is tuned by, and the space left over goes to the application names that say what to close.

The per-application shares can add up to more than 100%, and a single application with dozens of helper processes can exceed it alone: memory shared between processes is counted once for each of them. They rank the applications against each other and against the machine's capacity; they are not a partition of it.

### Features

* **Watches the readings that actually predict the stall** — swap in use (the leading indicator, near zero on a healthy machine and accruing over days of uptime), memory used, and compressed memory. Free memory is deliberately ignored: macOS lends almost all of it to the file cache and reclaims it on demand, so it sits near zero on a perfectly healthy machine.
* **Counts used memory the way Activity Monitor and Stats do** — anonymous, wired and compressed pages, with the file cache and purgeable pages excluded because the kernel takes those back at will. A naive total-minus-free reads about 99% on any Mac and says nothing; this figure agrees with what the menu bar shows.
* **Names the cause, measured correctly** — reports the heaviest applications by resident **plus compressed** memory. Resident size alone is actively misleading: a browser holding tens of gigabytes across dozens of helpers reports a few hundred megabytes each, so the real cause looks innocent while an idle background process looks guilty.
* **Blames the application, not the process** — totals are aggregated per command name, turning 56 renderers into one line.
* **Reports the whole picture, not just the trigger** — every alert names all three readings in a fixed order and marks the one that crossed, so a figure that means nothing in isolation arrives beside the two that give it meaning.
* **Thresholds that fit any machine** — memory and the compressor are shares of installed RAM, so the shipped defaults suit an 8 GB laptop and a 64 GB desktop without tuning.
* **Says it as a warning** — the alert is logged at `WARN`, because a filling machine is a finding rather than a failure of the tool. A red `[ERROR]` line for a script doing its job teaches its reader to ignore the next one.
* **Quiet by default** — raises nothing and exits 0 while healthy, so it suits a `launchd` agent running every few minutes. (One `[INFO]` line naming the config file it read is logged per run, from the shared config loader.)
* **Fails safe** — an unreadable reading counts as healthy. Running unattended, a false alarm every few minutes trains you to ignore the real one.

### Requirements

* `bash` (baseline; no version-specific features)
* macOS — reads `vm.swapusage`, `hw.memsize`, `vm_stat` and `top`, and notifies through `osascript`

### Usage

```bash
memory-pressure-alert [OPTIONS]
```

### Options

| Flag | Description |
| --- | --- |
| `-s`, `--swap-mb MB` | Warn at this much swap in use (default: `2048`). |
| `-u`, `--used PERCENT` | Warn at this much of RAM in use (default: `85`). Refused above 100, which no reading can reach. |
| `-c`, `--compressor PCT` | Warn at this much of RAM held compressed (default: `50`). |
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
used 79% (25.3 GB) · swap 0.0 GB (0%) · compressed 29% (9.4 GB)
    11.9 GB   37%   49 proc  Google
     5.9 GB   18%    1 proc  studio
     4.7 GB   14%    1 proc  idea
```

The alert carries the same readings in the form each threshold is judged on, with the heaviest applications appended:

```
$ memory-pressure-alert --no-notify
[WARN]: used 92% · ⚠ swap 4.1 GB · ⚠ compressed 61%. Heaviest: Google 41%; studio 17%; idea 16%
```

A warning, not an error: nothing has gone wrong with the tool when a machine fills up — reporting it is the job. `ERROR` is kept for the script's own failures, so a red line stays worth reading.

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

Two config keys are refused rather than honoured, because the value a config file already holds would
mean something else under the new name and a threshold that never fires is indistinguishable from a
quiet machine:

| Retired | Replaced by | Why the value cannot carry over |
| --- | --- | --- |
| `PRESSURE_WARN_PERCENT` | `USED_WARN_PERCENT` | It governed memory *free* where the reading is memory *used*, so its sense is inverted: `25` would read as "warn above 25% used", which is always. |
| `COMPRESSOR_WARN_MB` | `COMPRESSOR_WARN_PERCENT` | The threshold is a share of installed RAM, so `8192` reads as a percentage nothing can reach — silently disabling the reading. |

For the same reason, a percentage threshold above 100 is a usage error wherever it was set, rather than
a setting that quietly never applies.

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

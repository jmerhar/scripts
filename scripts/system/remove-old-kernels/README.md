# `remove-old-kernels`

Each kernel a Debian or Ubuntu system installs keeps an image, its modules and usually its headers, and nothing removes the old ones on a machine that is not short of space in `/boot`. They accumulate quietly, and an OS upgrade later has more to think about than it needs to.

### Features

* **Keeps What Must Boot** — The running kernel is kept whether or not it is the newest: a machine that has updated but not yet rebooted is running the older of two, and either being removed would leave it unbootable or unable to boot what it just installed. `--keep N` holds further recent ones as fallbacks.
* **Names Every Package** — Image, unsigned image, modules, modules-extra and headers, per version, purged by name. Nothing else is removed alongside them.
* **Nothing Auto-Removed** — `apt autoremove --purge` would find most of these too, and would also take whatever else it currently considers unneeded. On a machine with hand-installed packages that is not a list anyone has reviewed, so this never uses it.
* **Only What dpkg Can Purge** — A version dpkg holds nothing for is skipped, so apt is never handed a package that is not installed.
* **Refuses To Break The Boot** — Before purging anything, the package list is checked against the running kernel's version, and the run stops rather than proceed if the arithmetic above it went wrong.
* **Asks First** — `[y/N]`, with `--yes` for unattended use and `--dry-run` to see the list.

### Requirements

* `bash`
* Debian or Ubuntu (`dpkg-query`, `apt-get`)
* Root, or `sudo` — listing needs neither; purging does

### Usage

```bash
remove-old-kernels [OPTIONS]
```

```bash
# What would go?
remove-old-kernels --dry-run

# Purge, keeping the running kernel and the newest installed:
remove-old-kernels

# Keep two fallbacks besides the running kernel, unattended:
remove-old-kernels --keep 2 --yes
```

### Options

| Option | Description |
| --- | --- |
| `-k`, `--keep N` | Keep the `N` most recent kernels besides the running one (default `1`). |
| `-y`, `--yes` | Purge without asking. |
| `-n`, `--dry-run` | List what would be purged without purging anything. |
| `-C`, `--no-color` | Disable colored output. |
| `-d`, `--debug` | Enable verbose debug logging. |
| `-h`, `--help` | Show the help message. |

### Example

```
$ remove-old-kernels --dry-run
Keeping:
  6.8.0-136-generic (running)
  6.8.0-138-generic

Purging 12 package(s) for 3 kernel(s):
  linux-headers-6.8.0-124-generic
  linux-image-6.8.0-124-generic
  linux-modules-6.8.0-124-generic
  ...

Dry run: nothing was purged.
```

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Nothing needed removing, the purge succeeded, or it was declined. |
| `1` | `apt-get` failed, the settings were unusable, or the package list touched the running kernel. |

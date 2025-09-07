# System Scripts

This directory contains scripts that handle system-level tasks, such as package installation and environment configuration. These scripts are typically designed to be called by other, higher-level scripts and may not be intended for direct user interaction.

## Scripts

### `install-dependency.sh`

A cross-platform script to install a given package on macOS or Debian-based Linux.

#### Features
* **OS Detection**: Automatically detects if the OS is macOS or Linux.
* **Package Manager Support**: Uses Homebrew on macOS and `apt-get` on Debian/Ubuntu.
* **User Confirmation**: Prompts the user for confirmation before proceeding with any installation.
* **Error Handling**: Exits with a non-zero status code on failure, allowing calling scripts to handle errors.

#### Usage

This script is intended to be called from another script. It takes a single argument: the name of the package to install.

```bash
# Example: Called from another script to ensure 'qpdf' is installed
./install-dependency.sh qpdf
```

### `package-script.sh`

A generic package-file generator designed to be run from a CI/CD workflow. It takes the path to a script as an argument, parses metadata from a corresponding `README.md` file (expected in the same directory), and generates the necessary package files (`.rb` for Homebrew and `.deb` for Debian).

The script is configured entirely through environment variables and places its output into local directories, decoupling it from any specific repository structure.

#### Requirements
* `bash` 4.0+
* `awk`
* `dpkg-deb` (for Debian package creation)

#### Usage

This script is not intended for direct use on the command line. Instead, it is designed to be called by a CI/CD workflow, which provides it with the necessary environment variables. The workflow must be configured to set the following variables for the script to function correctly:

* `HOMEPAGE_URL`: The URL for the project's homepage (e.g., `https://github.com/jmerhar/scripts`).
* `HOMEBREW_FORMULA_DIR`: The local output directory for the generated Homebrew formula files.
* `DEB_PACKAGE_DIR`: The local output directory for the generated Debian package files.
* `CONFIG_DIR`: The directory where source config files are located.
* `MAINTAINER_INFO`: The maintainer's name and email for the Debian packages.
* `TARBALL_URL`: The URL to the tarball of the new release.
* `VERSION`: The version string (e.g., `v1.0.1`).
* `SHA256_CHECKSUM`: The pre-calculated checksum of the release tarball.

**Example of a Workflow Call:**

```bash
./system/package-script.sh "utility/unlock-pdf.sh"
```

### `local-backup.sh`

A generic script to create and automatically prune rsync-based system backups. It is designed to be run non-interactively by a cron job.

#### Features
* **Incremental Backups**: Uses `rsync` with hard links (`--link-dest`) to create space-efficient incremental backups.
* **Automatic Pruning**: Automatically deletes the oldest backups, keeping a configurable number of recent copies.
* **Centralized Configuration**: All settings, including source/destination directories, retention policy, and exclusion patterns, are managed in `/etc/local-backup.conf`.
* **Cron-Friendly**: Operates silently, logging informational output to a file and only sending errors to `stderr` for email notifications.
* **Flexible Exclusions**: Supports a detailed list of files and directories to exclude from the backup, defined as a Bash array in the config file.

#### Requirements
* `bash` 4.0+
* `rsync`

#### Usage

The script is intended to be run without arguments, typically by a system scheduler like `cron`.

**1. Configuration:**

Create a configuration file at `/etc/local-backup.conf`.

```bash
# /etc/local-backup.conf

# The source directory to back up.
SOURCE_DIR="/"

# The main directory where all backups will be stored.
BACKUP_DIR="/mnt/storage/backup"

# Number of recent backups to keep.
KEEP_BACKUPS=12

# Bash array of rsync exclude patterns.
EXCLUDES=(
  "/dev"
  "/proc"
  "/sys"
  "/tmp"
  "/run"
  "/lost+found"
  "/mnt/*"
)

# (Optional) Path to the log file.
LOG_FILE="/var/log/local-backup.log"
```

**2. Execution:**

Run the script directly. It's recommended to run it as `root` to ensure it can read all system files.

```bash
sudo local-backup
```

**Example Cron Job:**

To run a backup every day at 4:05 AM, edit the root crontab (`sudo crontab -e`) and add the following line:

```bash
5 4 * * * /usr/local/bin/local-backup
```

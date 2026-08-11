# Shell Scripts Collection

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A collection of packaged shell scripts for macOS and Linux, distributed via [Homebrew](https://brew.sh/) and [APT](https://jmerhar.github.io/apt-scripts/).

## Available Scripts

| Script | Description | Directory |
|--------|-------------|-----------|
| [`compare-dirs`](scripts/utility/README.md#compare-dirs) | Recursively compare two directories, reporting differences in existence, size, timestamps, and checksums. | `scripts/utility/` |
| [`dmarc-report`](scripts/utility/README.md#dmarc-report) | Aggregate a folder of DMARC reports into one summary, flagging unenforced domains, unaligned senders, and spoofing. | `scripts/utility/` |
| [`local-backup`](scripts/system/README.md#local-backup) | Incremental rsync backups with automatic pruning and RAID awareness. | `scripts/system/` |
| [`mdcheck-progress`](scripts/system/README.md#mdcheck-progress) | Report MD RAID scrub (`check`) progress and estimated finish time, even while paused between nightly windows. _(Linux only)_ | `scripts/system/` |
| [`nopasswd-sudo`](scripts/system/README.md#nopasswd-sudo) | Toggle temporary passwordless sudo with auto-revoke and a boot-time safety net. _(Linux only)_ | `scripts/system/` |
| [`photo-backup`](scripts/photography/README.md#photo-backup) | Multi-source photo backup to a remote server with deletion protection. | `scripts/photography/` |
| [`prune-orphaned-torrents`](scripts/system/README.md#prune-orphaned-torrents) | Find orphaned media left by \*arr hard-linking and interactively remove the matching Deluge torrents. | `scripts/system/` |
| [`remove-sidecars`](scripts/photography/README.md#remove-sidecars) | Clean up sidecar JPEG files from RAW+JPEG photo libraries. | `scripts/photography/` |
| [`subtitle-report`](scripts/utility/README.md#subtitle-report) | Report subtitle coverage for a media library, by language and source (embedded tracks + sidecars). | `scripts/utility/` |
| [`subtitle-sync`](scripts/utility/README.md#subtitle-sync) | Resynchronize drifting subtitles to a video's speech using Whisper and `alass`. | `scripts/utility/` |
| [`unlock-pdf`](scripts/utility/README.md#unlock-pdf) | Decrypt a password-protected PDF file. | `scripts/utility/` |

## Repository Structure

```
scripts.yaml      Central manifest — all publishable scripts and their metadata
scripts/          User-facing scripts, organized by topic
  system/           System administration tools; config files live here too
  utility/          General-purpose utilities
  photography/      Photography workflow automation
  lib/              Shared library (sourced at dev time, inlined at build time)
bin/              Internal CI/CD tooling (not published as packages)
test/             bats test suites, command stubs and the shared test helper
```

## Code Style

Bash scripts follow the
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
All code is checked with [ShellCheck](https://www.shellcheck.net/) in CI.

## Tests

[bats-core](https://github.com/bats-core/bats-core) suites in `test/`, run against
Linux and macOS in CI:

```bash
make install    # brew install bats-core yq
make test       # run the suite
make check      # ShellCheck + tests
make coverage   # the suite under kcov, then the coverage gate
```

Line coverage is published per commit at
[jmerhar.github.io/coverage/scripts](https://jmerhar.github.io/coverage/scripts/).

See [`test/README.md`](test/README.md) for how the suites are structured and how to
add one.

## Installation

The recommended approach is to use a package manager, which handles dependencies and updates automatically.

Most of these scripts need **bash 4.0 or newer** (one needs 4.3). Both package managers install a
suitable bash and point the script at it, so there is nothing extra to do — this matters mainly on
macOS, which still ships bash 3.2 as `/bin/bash`. A script installed from a plain tarball checks the
version itself and says so rather than failing obscurely.

### macOS (Homebrew)

```bash
brew tap jmerhar/scripts
brew install unlock-pdf        # or any script name from the table above
```

### Debian / Ubuntu (APT)

```bash
# Add the GPG key
wget -qO- https://jmerhar.github.io/apt-scripts/public.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/jmerhar-scripts.gpg

# Add the repository source
echo "deb [arch=all signed-by=/etc/apt/keyrings/jmerhar-scripts.gpg] https://jmerhar.github.io/apt-scripts/ stable main" \
  | sudo tee /etc/apt/sources.list.d/jmerhar-scripts.list

# Install
sudo apt-get update
sudo apt-get install unlock-pdf   # or any script name from the table above
```

### Direct Download

Each [GitHub Release](https://github.com/jmerhar/scripts/releases) includes a self-contained tarball with just the script (and its config template, if any). Download, extract, and run:

```bash
# Example: download the latest local-backup release
curl -fsSL https://github.com/jmerhar/scripts/releases/download/local-backup-v1.3.0/scripts-local-backup-v1.3.0.tar.gz \
  | tar xz
cd scripts-local-backup-v1.3.0
chmod +x local-backup.sh
./local-backup.sh -h
```

Scripts that ship with a config file will include it in the same directory, so they work out of the box.

## Contributing

Contributions are welcome. Open an issue to discuss changes or submit a pull request.
Please run `make check` first, and register any new script in `scripts.yaml`.

## License

Distributed under the [MIT License](LICENSE).

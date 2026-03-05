# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of packaged shell/Perl scripts for macOS and Debian/Ubuntu, distributed via Homebrew and APT. Each script is independently versioned and released.

## Architecture

### Directory Layout

- `system/` — Infrastructure scripts (packaging, dependency installation, backup)
- `utility/` — User-facing utility scripts
- `photography/` — Photography workflow automation
- `conf/` — Configuration file templates shipped with packages

### Packaging System

`system/package-script.sh` reads structured metadata from script headers and generates both Homebrew formulas (`.rb`) and Debian packages (`.deb`). It is driven entirely by environment variables (see `test_env.sh` for local testing).

Every script must include a metadata block:
```bash
# --- SCRIPT INFO START ---
# Name: script-name
# Description: One-line description.
# Author: Jure Merhar <dev@merhar.si>
# Homepage: https://github.com/jmerhar/scripts
# Dependencies: common-deps
# Homebrew-Dependencies: macos-only-deps
# Debian-Dependencies: debian-only-deps
# ConfigFile: optional-config.conf
# Publish: false
# License: MIT
# --- SCRIPT INFO END ---
```

### Release & CI/CD

- **Per-script versioning**: tags follow `script-name-vX.Y.Z` (e.g., `unlock-pdf-v1.5.0`)
- `.github/workflows/publish.yml` packages on release or manual dispatch, then pushes formulas to `jmerhar/homebrew-scripts` and signed `.deb` packages to `jmerhar/apt-scripts`

### Testing Locally

Source the test environment, then run the packager:
```bash
. test_env.sh
./system/package-script.sh <path-to-script>
```
Output lands in `./dist/homebrew/` and `./dist/debian/`.

## Shell Script Conventions

- Shebang: `#!/usr/bin/env bash`
- Strict mode: `set -o errexit`, `set -o nounset`, `set -o pipefail`
- Function docs follow Google Shell Style (`#######` block with Globals/Arguments/Outputs)
- Standard functions in every script: `log_error()`, `show_usage()`, and optionally `log_info()`
- Timestamped logging: ISO 8601 format `[YYYY-MM-DDTHH:MM:SS+TZ]`
- Scripts detect their install prefix to locate config files under `<prefix>/etc/`

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of packaged shell/Perl scripts for macOS and Debian/Ubuntu, distributed via Homebrew and APT. Each script is independently versioned and released.

## Architecture

### Directory Layout

- `scripts/` — User-facing scripts, organized by topic:
  - `scripts/system/` — System administration tools (e.g., backups)
  - `scripts/utility/` — General-purpose utilities
  - `scripts/photography/` — Photography workflow automation
  - `scripts/lib/` — Shared library sourced by other scripts (not published as a package)
- `bin/` — Internal CI/CD tooling (packaging, dependency installation). Not published as packages.
- `scripts.yaml` — Central manifest defining all publishable scripts, their metadata, and dependencies.

Config files (`.conf`) live next to their scripts (e.g., `scripts/system/local-backup.conf`). They are discovered by convention — no metadata field needed.

### Manifest (`scripts.yaml`)

All publishable scripts are registered in `scripts.yaml`. The manifest contains repo-level defaults (author, homepage, license) and per-script entries with path, description, and dependencies.

```yaml
defaults:
  author: "Jure Merhar <dev@merhar.si>"
  homepage: "https://github.com/jmerhar/scripts"
  license: "MIT"

scripts:
  script-name:
    path: scripts/topic/script-name.sh
    description: "One-line description."
    dependencies:
      common: [dep1, dep2]       # All platforms
      homebrew: [macos-only-dep] # Homebrew only
      debian: [debian-only-dep]  # Debian only
```

### Shared Library (`@include`)

Scripts can share code via `scripts/lib/common.sh`. In development, scripts `source` the library directly. For publishing, `bin/compile-includes.sh` inlines the library contents at build time so published scripts are fully self-contained.

The convention uses a two-line pattern in scripts:
```bash
# shellcheck source=../lib/common.sh
# @include ../lib/common.sh
```

The `# shellcheck source=` line lets ShellCheck resolve the dependency during linting. The `# @include` line is the directive that `compile-includes.sh` replaces with the file contents. The `shellcheck source=` line is stripped during compilation since it's no longer needed.

### Packaging System

`bin/package-script.sh` reads metadata from `scripts.yaml` (via `yq`) and generates Homebrew formulas (`.rb`), Debian packages (`.deb`), and release tarballs (`.tar.gz`).

Only scripts registered in `scripts.yaml` are publishable. Scripts under `bin/` are internal tooling.

### Release & CI/CD

- **Per-script versioning**: tags follow `script-name-vX.Y.Z` (e.g., `unlock-pdf-v1.5.0`)
- `.github/workflows/publish.yml` packages on release or manual dispatch, then pushes formulas to `jmerhar/homebrew-scripts` and signed `.deb` packages to `jmerhar/apt-scripts`
- `bin/update-readme-table.sh` regenerates README tables in downstream repos from the manifest
- **Release notes**: every GitHub Release should include a summary of user-facing changes (new features, fixes, breaking changes). Use markdown headers (`### New features`, `### Fixes`, etc.) for multi-item releases, or a plain bullet list for single-item releases.

### Testing Locally

Run the packager directly:
```bash
./bin/package-script.sh unlock-pdf v1.0.0
```
Output lands in `./dist/tarballs/`, `./dist/homebrew/`, and `./dist/debian/`.

Requires [yq](https://github.com/mikefarah/yq) to be installed.

## Shell Script Conventions

All Bash code follows the
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
Key conventions enforced in this repo:

- Shebang: `#!/usr/bin/env bash`
- Strict mode: `set -o errexit`, `set -o nounset`, `set -o pipefail`
- Function doc-blocks: `########################################` delimiter (40 `#`)
  with Globals, Arguments, Outputs, and Returns fields (include only those that apply)
- Standard functions in every script: `log_error()`, `show_usage()`, and optionally `log_info()`
- Timestamped logging: ISO 8601 format `[YYYY-MM-DDTHH:MM:SS+TZ]`
- Scripts detect their install prefix to locate config files under `<prefix>/etc/`

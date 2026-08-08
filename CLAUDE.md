# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of packaged shell scripts for macOS and Debian/Ubuntu, distributed via Homebrew and APT. Each script is independently versioned and released.

## Architecture

### Directory Layout

- `scripts/` — User-facing scripts, organized by topic:
  - `scripts/system/` — System administration tools (e.g., backups)
  - `scripts/utility/` — General-purpose utilities
  - `scripts/photography/` — Photography workflow automation
  - `scripts/lib/` — Shared library sourced by other scripts (not published as a package)
- `bin/` — Internal CI/CD tooling (packaging, dependency installation). Not published as packages.
- `test/` — bats suites, the shared test helper, and the command stubs. Not published as packages.
- `scripts.yaml` — Central manifest defining all publishable scripts, their metadata, and dependencies.

Config files (`.conf`) live next to their scripts (e.g., `scripts/system/local-backup.conf`). They are discovered by convention — no metadata field needed.

### Documentation (READMEs)

- The root `README.md` has an **Available Scripts** table — one row per script, kept alphabetical, with a short description and a link into that script's section (`scripts/<topic>/README.md#<script-name>` — link to the README file, not the directory, or GitHub's directory redirect drops the fragment).
- Each `scripts/<topic>/README.md` documents its scripts in detail, one `##` section per script, in this order (include only the parts that apply): description → `### Features` → `### Requirements` → `### Usage` → `### Options` → `### Example` → `### Exit Codes`, with `---` between sections.

**Keep the docs in sync with the code.** Whenever you add a script, or change one in a way that affects its description, options, requirements, or behaviour, update `scripts.yaml`, the root README table row, and the script's per-topic README section in the same change.

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
    min_bash: "4.3"              # Optional; omit when only baseline features are used
    platforms: [debian]          # Optional; omit to publish to both (see below)
    dependencies:
      common: [dep1, dep2]       # All platforms
      homebrew: [macos-only-dep] # Homebrew only
      debian: [debian-only-dep]  # Debian only
```

The optional `platforms:` list restricts which package targets are built; valid values are `homebrew` and `debian`. Omit it to publish to both (the default). Set `[debian]` for a Linux-only tool (skips the Homebrew formula) or `[homebrew]` for a macOS-only one (skips the `.deb`).

### Minimum bash version (`min_bash`)

macOS ships bash 3.2 as `/bin/bash`, so any script using a later feature — `${var,,}`, `declare -A`,
`mapfile`, `local -n` — must say so. `min_bash` is stated once and drives three things:

- a version guard compiled into the **published** script, right after the shebang, written in bash 3.x
  syntax so it runs on the versions it rejects. The development copy in `scripts/` has no guard.
- `Depends: bash (>= X)` in the `.deb`. A versioned dependency is required here: `bash` is Essential,
  so naming it without a version is a Lintian warning.
- `depends_on "bash"` in the formula, plus an `inreplace` repointing the shebang at the brewed bash.
  Homebrew has no version constraints and no versioned bash formula, so the guard is what asserts the
  version; the shebang rewrite is what makes the dependency effective under cron and launchd, where
  `env bash` would otherwise find `/bin/bash`.

`bin/check-bash-version.sh` re-derives the requirement from each script's source and fails if the
declaration is missing or too low. It runs in `make lint` and in CI, so the field cannot drift — **add
a pattern there when adopting a newer construct**, since an undetected feature means an under-declared
minimum and a package that installs but cannot run.

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
- **Always `git fetch --tags` before creating a new release** to avoid version collisions with existing remote tags.
- `.github/workflows/publish.yml` packages on release or manual dispatch, then pushes formulas to `jmerhar/homebrew-scripts` and signed `.deb` packages to `jmerhar/apt-scripts`
- `bin/update-readme-table.sh` regenerates README tables in downstream repos from the manifest
- **Release notes**: every GitHub Release should include a summary of user-facing changes (new features, fixes, breaking changes). Use markdown headers (`### New features`, `### Fixes`, etc.) for multi-item releases, or a plain bullet list for single-item releases.

### Automated Tests

[bats-core](https://github.com/bats-core/bats-core) suites live in `test/`, one per area, and run on
Linux and macOS via `.github/workflows/ci.yml`. See [`test/README.md`](test/README.md) before writing
one — it covers the three ways a test reaches the code, the safety rules, and how the stubs work.

```bash
make test     # the suite
make lint     # ShellCheck, including the helper and stubs
make check    # both; gate a commit on this
```

Two rules matter most:

- **Code under test is reached only through `run_script`, `run_func` or `run_snippet`.** All three run
  it in a subprocess with `$0` set to the script's own path, because every script derives its library
  include, `SCRIPT_NAME`, install prefix, config search path and usage text from `$0`.
- **`test/stubs` must stay first on `PATH`** — `setup_common` fails the test otherwise. `load_config`
  resolves its config path from `$0` and honours no override, so the scripts read the repo's own
  committed `.conf` files, which on a real machine can name real volumes. Assert on stub call logs,
  never on side effects, and write nothing outside `$BATS_TEST_TMPDIR`.

Coverage measurement is not wired up yet; it arrives once the shared
[jmerhar/coverage](https://github.com/jmerhar/coverage) setup is reworked.

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

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of packaged shell scripts for macOS and Debian/Ubuntu, distributed via Homebrew and APT. Each script is independently versioned and released.

## Architecture

### Directory Layout

Each publishable script lives in its own directory, alongside everything that belongs to it: its config
template, its README, and any `awk` or `jq` program it runs. The script keeps its own filename inside that directory because `SCRIPT_NAME`
derives from `basename "$0" .sh`, and that name drives config discovery, the usage text and the log
prefix — a tidier `main.sh` would silently become `SCRIPT_NAME=main` and break all three. The published
artefact is a single file named after the script, so the repetition is invisible outside the repo.

- `scripts/` — User-facing scripts, one directory per script, grouped by topic:
  - `scripts/system/` — System administration tools (e.g., backups)
  - `scripts/utility/` — General-purpose utilities
  - `scripts/photography/` — Photography workflow automation
  - `scripts/lib/` — Shared libraries, sourced by the scripts and inlined when published

```
scripts/system/
  README.md                       # generated index: intro + one row per script
  local-backup/
    local-backup.sh
    local-backup.conf
    README.md                     # this script's documentation
  prune-orphaned-torrents/
    prune-orphaned-torrents.sh
    prune-orphaned-torrents.conf
    candidates.jq                 # programs the script runs, inlined when published
    strays.jq
    README.md
```

- `bin/` — Internal CI/CD tooling (packaging, dependency installation). Not published as packages.
- `test/` — bats suites, the shared test helper, and the command stubs. Not published as packages.
- `scripts.yaml` — Central manifest defining all publishable scripts, their metadata, and dependencies.

Config files (`.conf`) live next to their scripts (e.g., `scripts/system/local-backup/local-backup.conf`). They are discovered by convention — no metadata field needed.

`load_config` searches, in order: `$CONFIG_FILE`, the script's own directory, `<install-prefix>/etc/`, then `/etc/`. Setting `CONFIG_FILE` names a file outright, so an unreadable one is an error rather than a fall back to the search — naming a file excludes the alternatives, and quietly loading a different config could mean different backup targets or credentials.

`default_log_file` is the same idea for logs: under an install prefix it names
`<prefix>/var/log/<script>.log`, and from a checkout it names nothing, so a working tree does not collect
log files. `log_command` runs a command with its output copied into `LOG_FILE`, which is what puts a failing
`rsync`'s own explanation in the log beside the script's "exit code 23".

### Documentation (READMEs)

- **Each script documents itself** in `scripts/<topic>/<script>/README.md`. It opens with a level-1 heading naming the script, then (include only the parts that apply): description → `### Features` → `### Requirements` → `### Usage` → `### Options` → `### Example` → `### Exit Codes`. This is the file to edit when a script's behaviour, options or requirements change.
- **The index tables are generated, not written.** The root `README.md` and each `scripts/<topic>/README.md` hold a `<!-- BEGIN TABLE -->` block filled in from `scripts.yaml` by `bin/update-all-tables.sh`, which knows the set of indexes and derives the topic list from the manifest. Run `make docs` after touching the manifest; `make lint` and the lint workflow run it with `--check` and fail when an index is stale.
- Index links point at the **directory** (`scripts/<topic>/<script>/`), never at the README inside it. GitHub renders a directory's README when the directory is visited, so the shorter target works and shows the script's other files beside its docs. Do not add `README.md#<anchor>` targets: an anchor is the one thing a directory link cannot carry, and with one README per script there is nothing to anchor to.

**Keep the docs in sync with the code.** A script's own README is hand-written, so a change to its options or behaviour means editing it in the same commit. Its one-line index entry comes from the manifest's `summary`, so that is where a changed summary goes — never into a table by hand.

### Manifest (`scripts.yaml`)

All publishable scripts are registered in `scripts.yaml`. The manifest contains repo-level defaults (author, homepage, license) and per-script entries with path, summary, description, and dependencies.

Two texts, because the audiences differ: `description` is package metadata — what someone inspecting a `.deb` or a formula reads — and may run long. `summary` is the one-line form the generated documentation indexes use. Omit `summary` and the index falls back to `description`, which usually reads as too wordy in a table.

```yaml
defaults:
  author: "Jure Merhar <dev@merhar.si>"
  homepage: "https://github.com/jmerhar/scripts"
  license: "MIT"

scripts:
  script-name:
    path: scripts/topic/script-name/script-name.sh
    summary: "Short line for the README index."
    description: "Longer description, used as package metadata."
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

### Shared Libraries (`@include`)

Shared code lives in `scripts/lib/`, one file per concern. In development a script `source`s what it needs;
for publishing, `bin/compile-includes.sh` inlines it at build time so published scripts are self-contained.

| Library | Holds |
|---|---|
| `core.sh` | `SCRIPT_NAME`, the install prefix, `log_info`/`log_error`/`log_debug`, `enable_debug_mode`, `default_log_file`, `log_command` |
| `config.sh` | `load_config`, `load_optional_config`, `validate_config` — needs `core.sh` |
| `program.sh` | `load_program` — needs `core.sh` |

**A script lists only the libraries it uses directly.** A library declares its own dependencies and the
compiler follows them, so nobody has to know that a config needs a logger. Each library carries a
double-source guard, which is what makes that safe at development time — and why the compiler inlines each
file exactly once: a guard inlined twice puts a `return` at the top level of the published script, where it
is an error, and the script would exit 2 before doing anything.

`bin/check-includes.sh` is the backstop, in `make lint` and the lint workflow. It computes the same closure
the compiler does and fails when a script calls a library function nothing it includes provides — which
otherwise works only for as long as some other include happens to pull that library in. It also checks that
the `# shellcheck source=` hint, the `source` line and the `# @include` directive in a loader pair all name
one file, since only the directive is acted on.

**There is one compile path, and it writes to `dist/compiled/`.** `bin/compile-all-includes.sh` compiles
every publishable script there — a script with no directives is copied, so the directory is the complete
set — and never touches the sources. That is what lets the same command run in a working tree
(`make compile`), in the lint workflow and in a release, instead of one arrangement for CI and none for a
developer.

`bin/package-script.sh` compiles the script it is packaging into that directory before packaging it, so an
artefact can never be built from the development form and there is no freshness rule to get wrong.
`bin/check-published-form.sh` compiles into a throwaway directory and asserts the result is self-contained.
Neither workflow has a separate compile step.

The convention uses a two-line pattern in scripts:
```bash
# shellcheck source=../../lib/common.sh
# @include ../../lib/common.sh
```

Both lines are relative to the script, which sits one directory deeper than the topic — so from
`scripts/<topic>/<name>/` the library is `../../lib/common.sh`. They must name the same path: the
compiler drops the `source` line and inlines whatever the directive names, so a mismatch publishes a
script that sources a path which does not exist.

The `# shellcheck source=` line lets ShellCheck resolve the dependency during linting. The `# @include` line is the directive that `compile-includes.sh` replaces with the file contents. The `shellcheck source=` line is stripped during compilation since it's no longer needed.

### Embedded programs (`@embed`)

An `awk` or `jq` program of more than a line or two lives in its own file beside the script, and is read
through `load_program` on a single self-contained line:

```bash
prog=$(load_program candidates.jq)  # @embed candidates.jq
jq "${args[@]}" "${prog}" <<<"${status}"
```

`compile-includes.sh` replaces that whole line with `prog='<file contents>'`, so a published script is
still one file. A single line rather than the loader/directive pair `@include` uses: the compiler can
buffer a `source` line and drop it, but buffering every assignment to spot a following directive would be
far too broad. A shared program goes in `scripts/lib/` and is named by a relative path
(`# @embed ../../lib/format-size.awk`) — `format-size.awk` is shared by two scripts that report recovered
space.

Four properties are enforced, each because the alternative fails somewhere expensive:

- **The name in the directive must match the name passed to `load_program`.** The compiler acts on the
  directive, so a drift publishes a program the development form never ran.
- **A program under `scripts/` must contain no single quote** — an apostrophe in a comment is the likely
  way in. It is embedded as a single-quoted literal, which such a quote would end early.
  `bin/check-programs.sh` says so during `make lint`; the compiler refuses it too, but only at packaging
  time. Programs under `bin/` are exempt: those tools run theirs with `awk -f` and are never published as
  one file.
- **Trailing newlines are stripped when embedding**, because `$(...)` strips them. Otherwise the published
  variable holds a different string from the one the development form loads.
- **`load_program` fails loudly** when a program is missing. `awk` and `jq` both accept an empty program
  and print nothing, so returning "" would turn a packaging mistake into a script that silently reports
  no results.

`bin/check-programs.sh` syntax-checks every program before it can run — the main reason for extracting
them, since a typo in a pruning filter otherwise surfaces mid-run, on the server. Two details there are
established by testing rather than by reading manuals: `awk -f prog /dev/null` *runs* BEGIN and END rather
than only parsing, and `jq` exits 3 for a syntax error **and** for a variable it never received, so a
filter using `--arg` values declares them in a `# lint-args:` header. A jq runtime error against the
checker's `null` input exits 5 and is ignored, since it says nothing about whether the filter compiles.

`bin/check-published-form.sh` compiles a throwaway copy of the tree and asserts that no published script
still sources the library or reads a program, that each parses, and that every inlined program matches its
file byte for byte. It must run on an **uncompiled** tree — compiling removes the directives it reads, so
afterwards it would pass having checked nothing, which is why it refuses a tree that has none.

### Packaging System

`bin/package-script.sh` reads metadata from `scripts.yaml` (via `yq`) and generates Homebrew formulas (`.rb`), Debian packages (`.deb`), and release tarballs (`.tar.gz`).

Only scripts registered in `scripts.yaml` are publishable. Scripts under `bin/` are internal tooling.

`bin/smoke-package-all.sh` packages every manifest entry at a throwaway version. That is what catches a
manifest and a packager that have stopped agreeing — a new entry missing a field, or metadata that no
longer matches the tree — before a release does. It runs in CI and from `make smoke`.

### Release & CI/CD

- **Per-script versioning**: tags follow `script-name-vX.Y.Z` (e.g., `unlock-pdf-v1.5.0`)
- **Always `git fetch --tags` before creating a new release** to avoid version collisions with existing remote tags.
- `.github/workflows/publish.yml` packages on release or manual dispatch, then pushes formulas to `jmerhar/homebrew-scripts` and signed `.deb` packages to `jmerhar/apt-scripts`. **The workflow holds no logic**: every step is a one-line call into `bin/`, so the release path is ShellCheck-clean, covered by tests, and runnable by hand.
  - `bin/release-package.sh <event> [tag]` — takes `github.event_name` straight through, so the choice between publishing one script from a tag and republishing the latest of every script is made in tested code. It validates the `script-name-vX.Y.Z` tag, packages, uploads the tarball, and prints the commit message the downstream repositories carry.
  - `bin/publish-downstream.sh <homebrew|apt> <checkout> <message>` — the fetch-reset-regenerate-push cycle both downstream repositories share, including the APT index rebuild and signing. It retries against a moving remote, which is what parallel releases produce; a failed fetch is another attempt rather than the end of the run.
- `bin/update-readme-table.sh` regenerates README tables in downstream repos from the manifest
- **Release notes**: every GitHub Release should include a summary of user-facing changes (new features, fixes, breaking changes). Use markdown headers (`### New features`, `### Fixes`, etc.) for multi-item releases, or a plain bullet list for single-item releases.

### Automated Tests

[bats-core](https://github.com/bats-core/bats-core) suites live in `test/`, grouped to mirror the tree
they cover — `test/scripts/` per publishable script, `test/bin/` per internal tool, `test/shared/` for
what spans them — and run on Linux and macOS via `.github/workflows/ci.yml`. See
[`test/README.md`](test/README.md) before writing one: it covers the three ways a test reaches the code,
the safety rules, and how the stubs work.

Two consequences of the grouping. `bats` does not recurse by default, so every runner passes
`--recursive`; and a suite loads the helper as `load ../test_helper`. `setup_common` derives the
repository root and the stub directory from the **helper's** location, exported as `TEST_DIR` — assert
against that rather than `BATS_TEST_DIRNAME`, which is the suite's own directory and a level deeper.

```bash
make test      # the suite
make lint      # ShellCheck, the manifest, bash versions, the awk/jq programs, the includes
make check     # all three; gate a commit on this
make smoke     # package every manifest entry at v0.0.0, catching manifest/packager drift
make docs      # regenerate the README index tables from the manifest
make compile   # compile every script into dist/compiled/, the form that gets published
make published # compile a throwaway copy and check every published script is self-contained
make coverage  # the suite under kcov, then the shared gate
```

Two rules matter most:

- **Code under test is reached only through `run_script`, `run_func` or `run_snippet`.** All three run
  it in a subprocess with `$0` set to the script's own path, because every script derives its library
  include, `SCRIPT_NAME`, install prefix, config search path and usage text from `$0`.
- **`test/stubs` must stay first on `PATH`** — `setup_common` fails the test otherwise, and the stubs
  are shared by every suite regardless of which subdirectory it sits in. A test that does
  not name its own `CONFIG_FILE` reads the repo's own committed `.conf` files, which on a real machine
  can name real volumes, so pass one wherever a config value decides what gets written. Assert on stub
  call logs, never on side effects, and write nothing outside `$BATS_TEST_TMPDIR`.

### Environment seams

Several scripts read paths that only exist on a particular machine in a particular state — a mounted
array mid-scrub, a sudoers directory, a RAID status file. Those are written as

```bash
: "${MDSTAT:=/proc/mdstat}"
readonly MDSTAT
```

so the default is the real path and a test can point them elsewhere. **Do not "simplify" these back to
literals**: as literals the surrounding logic is unreachable, and for two of them a test would act on the
real system. The full set:

| Script | Seams | Why it matters |
|---|---|---|
| all config readers | `CONFIG_FILE` | Named ahead of the search; unreadable is an error, not a fall back |
| `local-backup` | `MDSTAT`, `MDSTAT_CHECK_INTERVAL` | The RAID wait is otherwise unreachable and polls for five minutes |
| `mdcheck-progress` | `MDSTAT`, `SYS_BLOCK`, `MDCHECK_STATE_DIR`, `MDADM_CONF` | Nearly the whole tool reads machine state |
| `nopasswd-sudo` | `DROPIN`, `SYSTEMD_UNIT_DIR` | Defaults are `/etc/sudoers.d` and `/etc/systemd/system`; the coverage job runs as root |
| `subtitle-sync` | `CACHE_DIR` (via config) | Defaults under `$XDG_CACHE_HOME`, so a test would write to the real cache |

### Coverage

Line coverage is measured by kcov through `bin/run-coverage.sh` and published to
[the shared site](https://jmerhar.github.io/coverage/scripts/); `coverage.toml` declares the suite and
its gate, and the reporting is the shared actions from
[jmerhar/coverage](https://github.com/jmerhar/coverage). Four things about it are not obvious:

- **The kcov seam lives in `test/test_helper.bash` and nowhere else.** `run_script`, `run_func` and
  `run_snippet` notice `COVERAGE_DIR`; no `.bats` file knows coverage exists. Keep it that way.
- **`bash -c` cannot be traced.** kcov's prologue reads `BASH_SOURCE`, unset inside a `-c` string, so a
  script under `set -o nounset` dies before its function runs, and `--bash-method=DEBUG` measures
  nothing. Function-level calls therefore go through a harness kcov executes directly, written beside
  the script, so the library path it derives from `$(dirname "$0")` still resolves.
  `bin/run-coverage.sh` removes them.
- **bats is installed from source in the container, not from apt.** Debian ships 1.8, which predates
  `BATS_TEST_TIMEOUT`; a suite that bounds a test to turn a runaway loop into a failure would silently
  have no bound. `BATS_VERSION` in `bin/run-coverage.sh` pins the same version a local run and the macOS
  job use, so all three behave alike.
- **Coverage is Linux-only, and that is deliberate.** kcov's macOS build ignores the shebang and execs
  `/bin/bash` — 3.2 there — so most of these scripts fail under it. The runner detects that and uses the
  pinned container instead, which is also what CI does, so `make coverage` needs Docker rather than a
  local kcov.

The gate sits just under the measured figure. What keeps it short of the whole file is defensive code the
tests cannot drive rather than logic they miss: branches for a tool that is absent (stubbed here, so the
"not found" path never runs), colour setup behind `[[ -t 1 ]]`, and guards that exist precisely because
they should never fire. Set the gate to what is reachable and say why; never lower it to make a build
pass.

No publishable script has a `\` continuation left, and no multi-line `awk` or `jq` program is quoted
inside one. Both mattered for the figure, for the same reason: bash attributes a multi-line command to its
final line, so the first line reads as never executed and the lines between are not instrumented at all —
and for a program those lines are not bash in the first place, they run as awk or jq. Programs now live in
their own files, which are not measured. Keep new code single-statement-per-line, and a program longer than
a line or two in a file; `bin/run-coverage.sh` is the exception, since it is excluded from the report.

`--exclude-pattern` keeps `.conf` files and the per-script READMEs out of the measurement entirely, because
kcov's bash parser reads an ordinary prose line as code. Do not reach for `--exclude-line` or
`--exclude-region` instead: in this build they also disable `--include-path`, and the figure stops meaning
anything.

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

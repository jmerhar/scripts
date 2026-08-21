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

- `bin/` — Internal CI/CD tooling, subdivided by concern into `lint/`, `compile/`, `package/`, `docs/`, `coverage/`, with a shared `_lib/` (path resolution and logging) sourced by each tool. Not published as packages. See [`bin/README.md`](bin/README.md).
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
- **The index sections are generated, not written.** The root `README.md` and each `scripts/<topic>/README.md` hold a `<!-- BEGIN INDEX -->` block filled in from `scripts.yaml` by `bin/docs/update-all-indexes.sh`, which knows the set of indexes and derives the topic list from the manifest. Each script becomes a level-3 heading (linking to its directory), the manifest `description` as a paragraph, and a compact tagline of minimum bash version and dependencies. Run `make docs` after touching the manifest; `make lint` and the lint workflow run it with `--check` and fail when an index is stale.
- Index links point at the **directory** (`scripts/<topic>/<script>/`), never at the README inside it. GitHub renders a directory's README when the directory is visited, so the shorter target works and shows the script's other files beside its docs. Do not add `README.md#<anchor>` targets: an anchor is the one thing a directory link cannot carry, and with one README per script there is nothing to anchor to.

**Keep the docs in sync with the code.** A script's own README is hand-written, so a change to its options or behaviour means editing it in the same commit. Its index entry — the description paragraph and the dependency/min-bash tagline — comes from the manifest, so that is where a changed entry goes — never into the generated section by hand. `bin/lint/check-manifest.sh` is what makes the manifest agree with the tree in `make lint`: every registered script must exist, be executable, start with a shebang and have a README beside it, neither shared library (`scripts/lib/` or `bin/_lib/`) must be executable, and scripts under `scripts/` that nobody registered are reported.

### Manifest (`scripts.yaml`)

All publishable scripts are registered in `scripts.yaml`. The manifest contains repo-level defaults (author, homepage, license) and per-script entries with path, description, and dependencies.

`description` is the single text field: the packager reads it as package metadata, and the README index shows it in full as the paragraph under each script's heading. The tagline beneath it — the minimum bash version and the dependency list — is derived from `min_bash` and `dependencies`, so those are what a changed tagline edits.

```yaml
defaults:
  author: "Jure Merhar <dev@merhar.si>"
  homepage: "https://github.com/jmerhar/scripts"
  license: "MIT"

scripts:
  script-name:
    path: scripts/topic/script-name/script-name.sh
    description: "Longer description, used as package metadata and shown in the README index."
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

`bin/lint/check-bash-version.sh` re-derives the requirement from each script's source and fails if the
declaration is missing or too low. It runs in `make lint` and in CI, so the field cannot drift — **add
a pattern there when adopting a newer construct**, since an undetected feature means an under-declared
minimum and a package that installs but cannot run.

### Shared Libraries (`@include`)

Shared code lives in `scripts/lib/`, one file per concern. In development a script `source`s what it needs;
for publishing, `bin/compile/compile-includes.sh` inlines it at build time so published scripts are self-contained.

The `bin/` tools have their own separate library, `bin/_lib/` (`paths.sh` for repo-root
resolution and `log.sh` for logging), sourced at run time — never compiled or published.
It is distinct from `scripts/lib/`: the publishable scripts' library is inlined by the
compiler, while the bin tools source theirs directly. Both of its files follow the same
conventions as `scripts/lib/` — no shebang, a `# shellcheck shell=bash` first line, and a
double-source guard, which is what makes `paths.sh`'s `readonly` variables safe to source
twice; `paths.sh` also refuses an unset `SCRIPT_DIR` by name rather than letting `nounset`
blame a library the caller did not write. `test/shared/bin-lib.bats` covers both files
directly, as each `scripts/lib/` file has its own suite, and
`bin/lint/check-bin-library.sh` is the backstop that keeps every tool sourcing what it uses
and using what it sources. See [`bin/README.md`](bin/README.md).

| Library | Holds |
|---|---|
| `core.sh` | `SCRIPT_NAME`, the install prefix, `log_info`/`log_error`/`log_debug` (and their writer `log_message`), `disable_log_colors`, `enable_debug_mode`, `default_log_file`, `log_command` |
| `config.sh` | `load_config`, `load_optional_config`, `validate_config` — needs `core.sh` |
| `program.sh` | `load_program` — needs `core.sh` |
| `colors.sh` | the `_C_*` palette and `setup_colors <wanted>` |
| `platform.sh` | `stat_size`, `stat_mtime`, `file_checksum`, `has_checksum_tool` — the GNU/BSD differences |
| `prompt.sh` | `prompt_line` and `prompt_key` — needs `colors.sh` |
| `lang.sh` | the ISO 639 table, `normalize_lang`, `lang_from_tokens` |
| `cli.sh` | `die_usage`, `require_option_value`, `reject_positionals` — needs `core.sh` |

**A script lists only the libraries it uses directly.** A library declares its own dependencies and the
compiler follows them, so nobody has to know that a config needs a logger. Each library carries a
double-source guard, which is what makes that safe at development time — and why the compiler inlines each
file exactly once: a guard inlined twice puts a `return` at the top level of the published script, where it
is an error, and the script would exit 2 before doing anything.

Three of those exist to keep one answer to a question several scripts ask. `colors.sh` takes the
"colour wanted" flag as an **argument**, not as a global it reads by name, so each script may spell its own
option however it likes. `platform.sh` hides the GNU/BSD `stat` split, which is the one difference that would
otherwise break every script on one of the two platforms this repository publishes to. `prompt.sh` offers two
prompts under names that say which is which: `prompt_line` treats end-of-input as an empty answer, so a
caller's default applies; `prompt_key` passes it back, because a script looping over candidates with nothing
on stdin must be able to stop.

`lang.sh` matters more than the others: two scripts read the same media libraries, so they have to agree
about what a language is called, or a report showing Vietnamese subtitles is no use to a tool that cannot
match `vietnamese` to `vi`. `test/shared/lib-lang.bats` asks both scripts to normalise the same inputs and
requires the same answer — which is what would catch a second copy of that table appearing.

**Option parsing is conventional, not generated.** Every script parses its own options with a `case` loop
over `"$1"`, supports both the short and long form of each, and reports the three kinds of mistake through
`cli.sh` — so "Unknown option", "requires an argument" and "Unexpected arguments" read the same everywhere.
Each script keeps its own option table and writes its own usage text: a generated usage reads worse than a
written one, and a generic parser would have to reproduce every script's diagnostics to avoid changing them.
`cli.sh` calls `show_usage`, which the script defines — the one inversion, and the alternative is repeating
`log_error` + `show_usage` + `exit` at every error site.

`bin/lint/check-includes.sh` is the backstop, in `make lint` and the lint workflow. It computes the same closure
the compiler does and fails when a script calls a library function nothing it includes provides — which
otherwise works only for as long as some other include happens to pull that library in. It also checks that
the `# shellcheck source=` hint, the `source` line and the `# @include` directive in a loader pair all name
one file, since only the directive is acted on.

`bin/lint/check-bin-library.sh` is the same backstop for the `bin/` tools, which load `bin/_lib/` with a
plain `source` at run time. There is no closure to compute there — the two library files depend on nothing
— so the rule is simply that a tool sources the file providing each symbol it uses, uses every file it
sources, and pairs each shellcheck hint with the `source` line beneath it. It is a separate tool because
the two loading mechanisms share no implementation, and it counts the library's uppercase globals as
provided symbols alongside its functions: `paths.sh` provides only variables, so a check that looked at
functions alone would pass a tool reading `MANIFEST` without sourcing it.

**There is one compile path, and it writes to `dist/compiled/`.** `bin/compile/compile-all-includes.sh` compiles
every publishable script there — a script with no directives is copied, so the directory is the complete
set — and never touches the sources. That is what lets the same command run in a working tree
(`make compile`), in the lint workflow and in a release, instead of one arrangement for CI and none for a
developer.

`bin/package/package-script.sh` compiles the script it is packaging into that directory before packaging it, so an
artefact can never be built from the development form and there is no freshness rule to get wrong.
`bin/lint/check-published-form.sh` compiles into a throwaway directory and asserts the result is self-contained.
Neither workflow has a separate compile step.

The convention uses a three-line pattern in scripts:
```bash
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
```

The `# shellcheck source=` line lets ShellCheck resolve the dependency during linting. The `source` line
loads the library in development, so a checkout runs without a compile step. The `# @include` line is the
directive that `compile-includes.sh` replaces with the file contents. Both relative paths name the same
file, which sits one directory deeper than the topic — so from `scripts/<topic>/<name>/` the library is
`../../lib/core.sh`. They must name the same path: the compiler drops the `source` line and inlines
whatever the directive names, so a mismatch publishes a script that sources a path which does not exist.
The `# shellcheck source=` line is stripped during compilation since it is no longer needed.

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
  `bin/lint/check-programs.sh` says so during `make lint`; the compiler refuses it too, but only at packaging
  time. Programs under `bin/` are exempt: those tools run theirs with `awk -f` and are never published as
  one file.
- **Trailing newlines are stripped when embedding**, because `$(...)` strips them. Otherwise the published
  variable holds a different string from the one the development form loads.
- **`load_program` fails loudly** when a program is missing. `awk` and `jq` both accept an empty program
  and print nothing, so returning "" would turn a packaging mistake into a script that silently reports
  no results.

`bin/lint/check-programs.sh` syntax-checks every program before it can run — the main reason for extracting
them, since a typo in a pruning filter otherwise surfaces mid-run, on the server. Two details there are
established by testing rather than by reading manuals: `awk -f prog /dev/null` *runs* BEGIN and END rather
than only parsing, and `jq` exits 3 for a syntax error **and** for a variable it never received, so a
filter using `--arg` values declares them in a `# lint-args:` header. A jq runtime error against the
checker's `null` input exits 5 and is ignored, since it says nothing about whether the filter compiles.

`bin/lint/check-published-form.sh` compiles a throwaway copy of the tree and asserts that no published script
still sources the library or reads a program, that each parses, and that every inlined program matches its
file byte for byte. It must run on an **uncompiled** tree — compiling removes the directives it reads, so
afterwards it would pass having checked nothing, which is why it refuses a tree that has none.

### Packaging System

`bin/package/package-script.sh` reads metadata from `scripts.yaml` (via `yq`) and generates Homebrew formulas (`.rb`), Debian packages (`.deb`), and release tarballs (`.tar.gz`).

Only scripts registered in `scripts.yaml` are publishable. Scripts under `bin/` are internal tooling.

`bin/package/smoke-package-all.sh` packages every manifest entry at a throwaway version. That is what catches a
manifest and a packager that have stopped agreeing — a new entry missing a field, or metadata that no
longer matches the tree — before a release does. It runs in CI and from `make smoke`.

### Release & CI/CD

- **Per-script versioning**: tags follow `script-name-vX.Y.Z` (e.g., `unlock-pdf-v1.5.0`)
- **Always `git fetch --tags` before creating a new release** to avoid version collisions with existing remote tags.
- `.github/workflows/publish.yml` packages on release or manual dispatch, then pushes formulas to `jmerhar/homebrew-scripts` and signed `.deb` packages to `jmerhar/apt-scripts`. **The workflow holds no logic**: every step is a one-line call into `bin/`, so the release path is ShellCheck-clean, covered by tests, and runnable by hand.
  - `bin/package/release-package.sh <event> [tag]` — takes `github.event_name` straight through, so the choice between publishing one script from a tag and republishing the latest of every script is made in tested code. It validates the `script-name-vX.Y.Z` tag, packages, uploads the tarball, and prints the commit message the downstream repositories carry.
  - `bin/package/publish-downstream.sh <homebrew|apt> <checkout> <message>` — the fetch-reset-regenerate-push cycle both downstream repositories share, including the APT index rebuild and signing. It retries against a moving remote, which is what parallel releases produce; a failed fetch is another attempt rather than the end of the run.
- `bin/docs/update-readme-index.sh` regenerates the README script indexes in downstream repos from the manifest
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
make test-ci   # the suite with the environment the runners have
make lint      # ShellCheck, the manifest, bash versions, the awk/jq programs, both libraries' use
make check     # lint + test-ci + published form; gate a commit on this
make smoke     # package every manifest entry at v0.0.0, catching manifest/packager drift
make docs      # regenerate the README index sections from the manifest
make compile   # compile every script into dist/compiled/, the form that gets published
make published # compile a throwaway copy and check every published script is self-contained
make coverage  # the suite under kcov, then the shared gate
```

**`make check` gates on `test-ci`, not `test`.** Two environment differences have each already made a
green local suite fail in CI: `GITHUB_ACTIONS` is set for the whole job, which makes every `log_error`
emit an Actions annotation on stdout as well as its timestamped line, so a test counting occurrences of
a message sees each one twice; and git's default branch is `master` on the runners, which several tests
driving a bare fixture repository read. The Linux job hides the first of those — it runs the suite inside
the kcov container, which does not inherit `GITHUB_ACTIONS` — so such a failure appears on macOS alone.
`make test` stays for fast iteration; the gate uses the faithful environment.

Three rules matter most:

- **Code under test is reached only through `run_script`, `run_func` or `run_snippet`.** All three run
  it in a subprocess with `$0` set to the script's own path, because every script derives its library
  include, `SCRIPT_NAME`, install prefix, config search path and usage text from `$0`.
- **`test/stubs` must stay first on `PATH`** — `setup_common` fails the test otherwise, and the stubs
  are shared by every suite regardless of which subdirectory it sits in. A test that does
  not name its own `CONFIG_FILE` reads the repo's own committed `.conf` files, which on a real machine
  can name real volumes, so pass one wherever a config value decides what gets written. Assert on stub
  call logs, never on side effects, and write nothing outside `$BATS_TEST_TMPDIR`.
- **Never assert on a count of a `log_error` message.** The bin tools log through `bin/_lib/log.sh`,
  which prints the message twice under `GITHUB_ACTIONS` — once as the Actions annotation, once as the
  timestamped line. Count the `[ERROR]:` line, so the assertion means "one per reported item" in both
  environments.

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
| `ufw-docker-expose` | `DOCKER_BIN` | The double cannot simply be called `docker`: `bin/coverage/run-coverage.sh` and the bash-3.2 guard test run the real CLI for pinned images, and a stub of that name on `PATH` would be handed to them |

### Coverage

Line coverage is measured by kcov through `bin/coverage/run-coverage.sh` and published to
[the shared site](https://jmerhar.github.io/coverage/scripts/); `coverage.toml` declares the suite and
its gate, and the reporting is the shared actions from
[jmerhar/coverage](https://github.com/jmerhar/coverage). Four things about it are not obvious:

- **The kcov seam lives in `test/test_helper.bash` and nowhere else.** `run_script`, `run_func` and
  `run_snippet` notice `COVERAGE_DIR`; no `.bats` file knows coverage exists. Keep it that way.
- **`bash -c` cannot be traced.** kcov's prologue reads `BASH_SOURCE`, unset inside a `-c` string, so a
  script under `set -o nounset` dies before its function runs, and `--bash-method=DEBUG` measures
  nothing. Function-level calls therefore go through a harness kcov executes directly, written beside
  the script, so the library path it derives from `$(dirname "$0")` still resolves.
  `bin/coverage/run-coverage.sh` removes them.
- **bats is installed from source in the container, not from apt.** Debian ships 1.8, which predates
  `BATS_TEST_TIMEOUT`; a suite that bounds a test to turn a runaway loop into a failure would silently
  have no bound. `BATS_VERSION` in `bin/coverage/run-coverage.sh` pins the same version a local run and the macOS
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
a line or two in a file; `bin/coverage/run-coverage.sh` is the exception, since it is excluded from the report.

`--exclude-pattern` keeps `.conf` files and every README out of the measurement entirely, because
kcov's bash parser reads an ordinary prose line as code. Do not reach for `--exclude-line` or
`--exclude-region` instead: in this build they also disable `--include-path`, and the figure stops meaning
anything.

### Testing Locally

Run the packager directly:
```bash
./bin/package/package-script.sh unlock-pdf v1.0.0
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

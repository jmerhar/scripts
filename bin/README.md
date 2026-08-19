# `bin/` — internal CI/CD tooling

Scripts in `bin/` are not published as packages. They are the build, lint, test and
release machinery: packaging, the `@include`/`@embed` compiler, the manifest checks,
the README index generator, and the coverage runner. The Makefile and the GitHub Actions
workflows are thin wrappers that call into these scripts so the same logic runs locally
before a push and in CI.

## Layout

The tools are grouped by concern, one subdirectory each:

| Directory | Holds |
|---|---|
| [`lint/`](lint/) | The six `check-*` scripts run by the lint workflow, and locally by `make lint` and `make published` |
| [`compile/`](compile/) | The `@include` compiler (one file and the whole tree) |
| [`package/`](package/) | Packaging, the release smoke test, the release orchestrator, and the downstream push |
| [`docs/`](docs/) | The README index generator (one file and every file) |
| [`coverage/`](coverage/) | The kcov coverage runner |
| [`_lib/`](_lib/) | Shared path resolution and logging, sourced (not run) by the tools above |

Each group directory has its own README describing the scripts it holds; `_lib/` is
described below.

## The shared library (`_lib/`)

`_lib/paths.sh` derives the repository root, the manifest path and the `scripts/` directory
from the caller's own location; `_lib/log.sh` holds the logging. A tool lists what it needs —
most take both, `compile-includes.sh` needs only the logging, and the three that report
through a bare `echo` take only the paths. The preamble is otherwise identical everywhere:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
```

The subdirectory depth — `bin/<group>/<tool>.sh`, so the root is `../..` from the tool —
is stated once in `paths.sh` rather than reproduced in each tool. Both files carry a
double-source guard, as `scripts/lib/` does: `paths.sh` marks its variables `readonly`, so
without one a second source would abort the tool. `paths.sh` also refuses an unset
`SCRIPT_DIR` by name, since the fix for that belongs in the caller's preamble rather than in
a library the caller did not write.

`lint/check-bin-library.sh` holds the tools to the rule above: source what you use, use what
you source. Without it a tool calling `log_error` while sourcing only `paths.sh` loads
perfectly and fails at the call, which for an error path can mean mid-release.

`log.sh` adds the GitHub Actions `::error::`/`::warning::` annotation under CI so a failure
shows as an annotation on the failing step rather than buried in the log. The annotation goes
to stdout, where the runner reads workflow commands, so under CI a tool's error is two lines
rather than one — which is why a tool whose stdout carries data redirects a child's stdout to
stderr, and why a test counting reported items counts the timestamped line, not the message.

This is a separate, runtime-sourced library, distinct from `scripts/lib/` (which the
publishable scripts `@include` and the compiler inlines at build time). The bin tools are
never compiled or published, so they source `_lib/` directly at run time.

`test/shared/bin-lib.bats` covers both files directly, as every `scripts/lib/` file has its
own suite: the depth `paths.sh` states, that an inherited `REPO_ROOT` is overridden rather
than honoured, and which stream each annotation goes to.

## The awk programs

Two `.awk` programs live beside the single tool that invokes each, rather than in a shared
directory: `package/class-name.awk` (run by `package-script.sh` via `awk -f`) turns a
script name into the CamelCase class name a Homebrew formula requires, and
`docs/splice-index.awk` (run by `update-readme-index.sh`) splices the generated index
between the README markers. They are not standalone tools.

## The load-bearing subdirectory depth

Each tool resolves its siblings and the repository root relative to its own `SCRIPT_DIR`,
so the subdirectory layout is not cosmetic. Moving a tool without updating its `../_lib/`
source path and any cross-group sibling reference (e.g. `package-script` →
`../compile/compile-includes`) breaks the build. The test helper `fake_repo_tool` mirrors
this layout into fixture trees, so a tool under test finds its library and siblings just as
it does in the real tree.

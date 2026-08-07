# Testing & coverage

How to add a test suite and a coverage gate to this repository, matching the setup used across the
other projects (tests → line-coverage gate → Codecov → the shared
[jmerhar/coverage](https://github.com/jmerhar/coverage) site).

**Reference implementation: [`jmerhar/gh-maintenance`](https://github.com/jmerhar/gh-maintenance).**
It is a small bash repo with the whole chain working — copy from it rather than reinventing. The files
worth lifting almost verbatim are `test/test_helper.bash`, `scripts/run-coverage.sh`,
`scripts/coverage-report.py`, `scripts/collect-coverage.sh`, `codecov.yml`, the `Makefile`, and the
`test` job in `.github/workflows/ci.yml`.

## Toolchain

```bash
brew install bats-core kcov     # tests + coverage
```

- **[bats-core](https://github.com/bats-core/bats-core)** runs the tests.
- **[kcov](https://github.com/SimonKagstrom/kcov)** measures line coverage and emits everything the
  chain needs in one run: `coverage.json` (gating + metrics), `cobertura.xml` (Codecov) and
  `index.html` (the coverage site). It is line-only — there is no branch coverage for shell.

kcov is the right tool here: ShellSpec's coverage is kcov under the hood, and bashcov needs Ruby ≥ 3.

## kcov: four traps, all of which produce silent wrong answers

These cost hours to rediscover. All four are handled in the reference implementation.

1. **Give kcov the script, not `bash script`.**
   `kcov out ./script.sh` ✅ — `kcov out bash ./script.sh` ❌ reports **0/0 lines**, because kcov then
   instruments the `bash` binary rather than the script.
2. **Use the default PS4 collection method.** `--bash-method=DEBUG` fails outright on macOS
   (`Can't start/attach`). This is the single reason kcov looks "broken on macOS" — it isn't.
3. **Never run kcov *over* bats.** `kcov out bats test/` collects nothing: bats executes scripts in
   grandchild processes, and the combination is unreliable (kcov issue #462). Instead collect **per
   script invocation** from the test helper — kcov accumulates into one output directory across
   invocations unless `--clean` is passed. The merged result lands in `<out>/kcov-merged/`.
4. **The bash flags are hidden.** `kcov --help` shows none of them; use
   `kcov --uncommon-options --help`.

Two behaviours you can rely on: kcov **passes the script's exit status through** (so `$status`
assertions are unaffected) and leaves **stdout clean** (so `$output` assertions are unaffected).

### Publishing the HTML report

Publish the **whole** kcov output tree, but strip two kinds of file kcov leaves in its root:

- **absolute symlinks into the directory kcov ran from** — they dangle once copied anywhere else, and
  `upload-pages-artifact` cannot tar a dangling symlink, so they break the deployment of the *shared*
  coverage site for every project at once;
- **`.so` runtime helpers**, which have no business on a static site.

Do not reduce the upload to `kcov-merged/` alone, tempting as it looks: its per-file pages reference
`../data/bcov.css` — one level *above* themselves — so dropping the parent `data/` silently costs the
covered/uncovered line highlighting. Assert in `collect-coverage.sh` that the upload has no symlinks,
no `.so` files, and that `data/bcov.css` exists, so any future kcov change fails locally instead of in
the shared repository.

### CI has no kcov package

kcov is **not in Ubuntu 24.04's repositories** — its Debian package was dropped over an FTBFS with
GCC 15 (since fixed, so it may return). Upstream is active; this is a packaging gap, not a dying tool.
Options, best first:

| Route | Version | Notes |
|-------|---------|-------|
| **Pinned `kcov/kcov` image** | v44-pre | What the reference implementation uses. Least wiring, and identical figures to Homebrew's v43 (verified). Pin **by digest** so the number cannot drift. |
| `runs-on: ubuntu-22.04` + apt | v38 (2020) | Simple but old; may not match local figures. |
| Build from source, cached | any | Exact version control, but reintroduces the compiler-fragility that removed the package in the first place. |

`scripts/run-coverage.sh` in the reference implementation uses a locally installed kcov when present
and falls back to the pinned image otherwise, so CI needs **no toolchain install at all**.

## Testing strategy for *this* repository

### `scripts/lib/common.sh` — source it and unit-test the functions

This is the highest-value target: it is shared by most scripts. It is safe to `source` in a test —
it has an include guard (`_COMMON_SH_LOADED`) and only defines functions plus a few globals.

Two gotchas:

- `SCRIPT_NAME` is **`readonly`**. Set it *before* sourcing if a test needs a particular value; it
  cannot be reassigned afterwards, and sourcing in a shell that already has it set differently will
  fail.
- Colour output depends on `[[ -t 1 ]]`, so it is disabled under bats. Assert on message text, not
  escape codes.

Worth covering: `load_config` (missing file, malformed file, precedence), `validate_config` (required
keys present/absent), `get_script_prefix` (install-prefix detection), and the `log_*` family
(timestamp format, quiet mode, debug gating).

### The scripts themselves — run them as subprocesses with stubbed commands

Every script ends with an unguarded `main "$@"`, so **sourcing one executes it**. Test them as
subprocesses instead:

```bash
run bash "$REPO_ROOT/scripts/utility/unlock-pdf.sh" --help
[ "$status" -eq 0 ]
[[ "$output" == *"Usage"* ]]
```

Stub external commands by putting a directory first on `PATH` (exactly how `test/stubs/gh` works in
the reference implementation). This is **mandatory** for the destructive scripts — `local-backup.sh`,
`photo-backup.sh`, `prune-orphaned-torrents.sh`, `remove-sidecars.sh` — where a real `rsync`, `rm`,
`exiftool` or `transmission-remote` must never run. Have each stub log its arguments to a file and
assert on that log; it is a better test than checking side effects, and it is safe.

Point every script at `BATS_TEST_TMPDIR` for paths and config, and never let a test read or write
anything outside it.

The `source .../lib/common.sh` line resolves relative to the script's own directory, so tests work
against the **development** form — no need to run `bin/compile-includes.sh` first.

### Optional: add an execution guard to unlock finer tests

Changing the last line of each script from `main "$@"` to:

```bash
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

lets tests source a script and exercise its individual functions directly, which is much cheaper than
driving everything through the CLI. It is a one-line, behaviour-preserving change per script (the
compiled/published form is unaffected). Recommended, but do it as its own commit, separate from
adding tests.

### Also worth testing

`bin/compile-includes.sh` (the `@include` expansion — nested includes, a missing target, the
`shellcheck source=` line being stripped) and `bin/package-script.sh` (manifest parsing, the
`platforms:` filter). These are internal tooling, but a bug there breaks every release.

## Coverage setup

Use **one suite** covering both `scripts/` and `bin/`:

```bash
kcov --include-path="$root/scripts,$root/bin" "$COVERAGE_DIR" "$script" "$@"
```

`--include-path` also makes kcov count files that were **never executed**, so a completely untested
script cannot hide behind a high percentage — it drags the number down, which is what you want.

Set the gate in `scripts/coverage-report.py`:

- Start with `GATES = {"scripts": None}` (informational) and run `make coverage` to learn the real
  figure.
- Then pin the gate at, or just under, that figure — same convention as the other repos: a real
  regression fails CI, the odd defensive line is tolerated. Raise it as coverage climbs; never lower
  it to make a red build pass.

With ~15 scripts, expect the first honest number to be low. That is fine and useful: land the gate
informational, then raise it as suites are added, rather than blocking on 100% up front.

## Wiring checklist

1. `brew install bats-core kcov`.
2. Copy `test/test_helper.bash`, `scripts/run-coverage.sh`, `scripts/coverage-report.py`,
   `scripts/collect-coverage.sh`, `codecov.yml` and the `Makefile` from `gh-maintenance`; adjust
   paths, the suite key, and the `--include-path` list.
3. Write `test/lib-common.bats` first (highest value, easiest), then one `.bats` file per script.
4. Add `coverage/` and `coverage-upload/` to `.gitignore`.
5. Add a `test` job to `.github/workflows/lint.yml` (or a new `ci.yml`) running
   `scripts/run-coverage.sh`, then the coverage summary, Codecov upload, gate, and the coverage-site
   publish — copy the job from `gh-maintenance`'s `ci.yml`.
6. **Add the two missing secrets** — this repo currently has only `GPG_PASSPHRASE`, `GPG_PRIVATE_KEY`
   and `PAT`:
   - `CODECOV_TOKEN` — from Codecov for this repo.
   - `COVERAGE_PAGES_TOKEN` — a fine-grained PAT with **Contents: read/write** on `jmerhar/coverage`
     (see that repo's README; the same token is reused across projects).
7. Keep the existing ShellCheck/manifest/packaging jobs — the new suite complements them.

## Pitfalls hit while building the reference implementation

- `[ -f "$x" ] && exit 1` as the **last** line of a function or `case` branch leaves exit status 1
  when the file is absent, so callers see a spurious failure. Use `if … then exit 1; fi` and an
  explicit `exit 0`.
- `shift 2>/dev/null` shifts by **one** — the `2` is a redirection, not a count.
- ShellCheck **SC2195**: a `case` pattern that can never match (e.g. a bare `"api"` alternative when
  the matched word always contains a space). Keep `shellcheck` in the gate; it caught a real dead
  branch.
- Write test helpers to run under **bash**, not zsh: zsh does not word-split unquoted `$vars`, so
  `for x in $list` iterates once over the whole string. Run helper scripts as `bash script.sh`.
- Assert on **stubbed-command logs** rather than real side effects; it is both safer and a sharper
  assertion about what the script actually tried to do.

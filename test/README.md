# Tests

[bats-core](https://github.com/bats-core/bats-core) suites for the scripts in this repository.

```bash
make test                              # everything
bats test/lib-common.bats              # one suite
bats --filter 'format_size' test/      # one concern, across suites
bats --print-output-on-failure test/   # show a failing test's output
```

`make install` installs the toolchain (`brew install bats-core`).

---

## How a test reaches the code

Never directly. Everything goes through one of three helpers from `test_helper.bash`, each of which
runs the code in a subprocess:

| Helper | Use for |
|---|---|
| `run_script <script> [args…]` | Driving a script end to end through its command line. |
| `run_func <script> <func> [args…]` | Calling one function in isolation. |
| `run_snippet <script> '<bash>'` | Anything a single call cannot express — inspecting a global the script set, sequencing two calls, checking state after a failure. |

All three set `$0` to the script's own path. That is not incidental: every script here derives its
library include, `SCRIPT_NAME`, install prefix, config search path and usage text from `$0`, so a
harness that got `$0` wrong would exercise different code than production does.

They are subprocess-based even where sourcing in-process would be faster, because the scripts declare
`readonly` globals that a second in-process source could not re-assign, and because keeping the launch
in one place means line coverage can be added later by editing these three functions and nothing else.

`run_func` needs the script's trailing `main "$@"` to be guarded:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

An unguarded script runs to completion the moment it is sourced.

---

## Safety

`setup_common` puts `test/stubs` first on `PATH` and **fails the test if it is not first**.

That guard earns its place. These scripts delete files, drive `rsync`, and talk to a torrent daemon,
and they read their settings from the repo's own committed `.conf` files — `load_config` resolves that
path from `$0` and honours no override, so it cannot be pointed somewhere harmless. On a machine where
those settings name real, populated volumes, a test that reached the real `rsync` would act on them.

Two rules follow:

- Write nothing outside `$BATS_TEST_TMPDIR`.
- Assert on **stub call logs**, not on side effects. `stub_called 'rsync .*--delete'` is both safer
  than checking whether files vanished and a sharper claim about what the script actually tried to do.

A test that depends on specific config values should write a fixture file and name it with
`CONFIG_FILE`, which `load_config` honours ahead of its search. That keeps the test hermetic and is the
only way to be sure the repo's own committed `.conf` is not what the script read. `run_func` with the
config globals passed as environment works too, and skips `load_config` entirely.

Passing `CONFIG_FILE` is a **requirement**, not a preference, wherever a config value decides what gets
written — `subtitle-sync`'s `CACHE_DIR` defaults under `$XDG_CACHE_HOME`, so a test that let it default
would write into the developer's real cache and read from it on the next run.

---

## Stubs

Every stubbed command in `test/stubs/` is a symlink to `_stub`, which decides what to do from `$0` —
one implementation to audit instead of a dozen near-identical files. It appends `<command> <argv…>`
to `$STUB_CALLS` and exits 0.

Steer it from a test with the `test_helper.bash` helpers:

```bash
stub_fails rsync 23              # next call exits 23
stub_outputs exiftool <<< 'X100' # canned stdout
stub_called 'rsync .*--delete'   # assert on recorded argv
stub_calls rsync                 # how many times it ran
```

`stub_called` takes a **basic** regular expression, so `(` and `)` match themselves and escaping them
turns them into a group that matches nothing you meant — write `'movie (2024)\.mkv'`, not
`'movie \(2024\)\.mkv'`.

To stub a new command, symlink it: `ln -s _stub test/stubs/<name>`. Add a `case` branch in `_stub`
only if the script under test requires more than an exit status — `qpdf` and `dpkg-deb` must leave an
output file behind because their callers check for one, and `ffmpeg`, the transcriber and `alass` must
because their callers *parse* what comes back. Those three write a two-cue SRT by default, or the
contents of a `<command>.artifact` fixture when a test supplies one:

```bash
printf '1\n00:00:09,500 --> 00:00:13,000\nx\n' > "$STUB_FIXTURES/alass.artifact"
```

The transcriber and `alass` branches match their command name on a *substring*, because `WHISPER_BIN`
and `ALASS_BIN` are configurable: a test that checks the setting is honoured points the script at a
double under another name and still needs it to behave like one.

Those branches take the output path to be the **last argument**, which is a guess — `ffmpeg -i in.mkv`
ends in an input. So a write only happens when the destination lands under a temp root: the test's own
directory, or the scratch directory a script made with `mktemp`. Anywhere else, including a relative path
resolved against the repository, is skipped rather than written.

`dpkg-deb` is stubbed rather than delegated to the real tool for a specific reason: it does not exist
on macOS, and `package-script.sh` silently skips `.deb` generation when it cannot find it. Without the
stub the packaging suite would quietly test nothing on a Mac and everything on Linux.

Commands that only read (`yq`, `xmllint`, `shasum`, `find`, `stat`) are deliberately **not** stubbed —
the real ones are harmless and give better fidelity. `yq` therefore has to be installed for the
packaging suite, as it already is for the packager itself.

---

## Determinism

`setup_common` pins `TZ=UTC` and `LC_ALL=C`, and unsets `LOG_FILE`, `IS_DEBUG_MODE`, `_LOG_QUIET` and
`SCRIPT_NAME` so a value inherited from the developer's shell cannot change a result. Assertions
about dates or durations should still use fixed epochs rather than `date`-now, so a test cannot pass
only today.

Colour output is suppressed whenever stdout is not a terminal, which it never is under bats, so assert
on message text and never on escape codes.

---

## Adding a suite

```bash
#!/usr/bin/env bats
# One line on what makes this script worth testing.

load test_helper

setup() { setup_common; }

@test "rejects an unknown option" {
  run_script "$REPO_ROOT/scripts/utility/compare-dirs.sh" --nonsense
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option"* ]]
}
```

Name tests as the behaviour being asserted, not the function being called — `refuses a negative
timeout` rather than `test parse_options 3`.

`harness.bats` covers the helper itself — the three seams, `$0` fidelity, the `PATH` guarantee and
every stub control. Change `test_helper.bash` or `_stub` and that suite is what tells you whether the
guarantees the other suites rely on still hold.

---

## Coverage

```bash
make coverage        # the suite under kcov, then the shared gate
make test-coverage   # the same without gating
```

Needs Docker rather than a local kcov: kcov's macOS build ignores the shebang and execs `/bin/bash`,
which is 3.2 there, and most of these scripts need 4.0 or newer — so `bin/run-coverage.sh` probes what a
local kcov would run and falls back to the pinned container, which is what CI uses too.

Everything coverage-specific is in `test_helper.bash`: the three seams notice `COVERAGE_DIR` and trace
through kcov. **No `.bats` file should ever mention coverage.**

`run_func` and `run_snippet` cannot be traced the way they normally run. `bash -c 'source …'` sets `$0`
exactly, but kcov's prologue reads `BASH_SOURCE`, which is unset inside a `-c` string, so a script under
`set -o nounset` dies before its function is reached. Under coverage those calls instead go through a
harness kcov executes directly, written beside the script — where `$(dirname "$0")/../lib/common.sh`
still resolves — and handed the script's own `SCRIPT_NAME`. It defaults rather than forces that name, so
a test pinning `SCRIPT_NAME` keeps its value. `bin/run-coverage.sh` deletes any harness a run leaves
behind, and `.gitignore` covers one that a killed run strands.

The consequence for tests: assert what the scripts need from `$0` — its directory, and their own name —
rather than `$0` itself, since under coverage `$0` is the harness. `harness.bats` does exactly that.

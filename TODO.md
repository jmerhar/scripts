# TODO

## 1. remove-sidecars: Camera-based exclusion filtering

Add an optional prompt after defining extensions that lets the user exclude
certain cameras from sidecar deletion. Implementation:

1. Read EXIF data (Camera Model) from all files found during traversal.
2. Present the unique list of cameras and let the user pick which to exclude.
3. Store the file-to-camera mapping in memory so EXIF isn't read twice.

Once camera-based filtering is in place, extension matching can be made
case-insensitive (e.g., treating `.dng` and `.DNG` the same) since the camera
distinction (Android vs Lightroom) would be handled by the exclusion list
rather than relying on extension casing.

## 2. Extend the test suite to the data-touching scripts

`test/` covers the shared library, the pure helpers, every script's command-line
contract and the `bin/` release tooling. What is left is the behaviour of the
scripts that move or delete data: `local-backup`, `photo-backup`,
`remove-sidecars`, `prune-orphaned-torrents`, `subtitle-sync`, `subtitle-report`,
`compare-dirs`, `dmarc-report` and `mdcheck-progress`.

Those need stubs driven from fixtures rather than the log-and-succeed defaults —
an `exiftool` that reports a camera model, a `curl` that answers as a Deluge
daemon, an `ffmpeg` that yields a subtitle track. Best split one pull request per
topic directory. See [`test/README.md`](test/README.md).

Coverage measurement is deliberately absent until the shared
[jmerhar/coverage](https://github.com/jmerhar/coverage) setup is reworked.
Findings from measuring kcov against this repo, worth keeping for then:

- `.conf` files get instrumented, because `load_config` sources them, and need
  excluding or they land in the report.
- `--include-path` only discovers unexecuted files in directories kcov has
  already seen, so the denominator is only complete once the suite touches every
  one of them.
- Publishing is narrow: `kcov-merged/` alone loses the line highlighting, whose
  per-file pages reference `../data/bcov.css`, while the whole output tree
  carries dangling symlinks and `.so` helpers that break the shared site's Pages
  deploy. Publish the tree and strip those two.
- Bash attributes a multi-line command to its final line, so the first line of
  each `\` continuation reads as never executed and the continuation lines are
  not instrumented at all; the closing brace of a redirected group
  (`} >> "$file"`) is never reported either. Reshape those statements rather than
  trying to test them — argument arrays and named variables for the long
  invocations, a function for the redirected group. This repo has 114
  continuations, concentrated in `dmarc-report`, `subtitle-sync` and
  `prune-orphaned-torrents`, and one redirected group in `bin/package-script.sh`.
  The suite asserts behaviour rather than layout, so it stays valid across that
  reshaping and protects it.

## 3. Declare the bash 4+ dependency for the scripts that need it

Eight scripts use features that do not exist in bash 3.2, which is what macOS
ships as `/bin/bash`. None of them declares a `bash` dependency in
`scripts.yaml`, so `brew install` on a stock Mac produces a script whose
`#!/usr/bin/env bash` resolves to 3.2 and fails at run time.

| Script | Feature | Needs |
|---|---|---|
| `compare-dirs` | `${var,,}`, `declare -A` | 4.0 |
| `dmarc-report` | `declare -A` | 4.0 |
| `local-backup` | `mapfile` | 4.0 |
| `prune-orphaned-torrents` | `${var,,}`, `mapfile` | 4.0 |
| `remove-sidecars` | `${var,,}`, `declare -A` | 4.0 |
| `subtitle-report` | `${var,,}`, `declare -A` | 4.0 |
| `subtitle-sync` | `local -n` | 4.3 |
| `mdcheck-progress` | `mapfile` | 4.0 |

Seven of those are published to Homebrew and so are exposed; `mdcheck-progress`
is Debian-only, and every supported Debian release ships bash 5, so it is
unaffected in practice.

Adding `homebrew: [bash]` to each affected entry is the fix. Note that this
changes the shebang problem only if the formula's `bash` precedes `/bin/bash` on
the user's `PATH`, which is what Homebrew's own setup does; the alternative is
rewriting the affected constructs to work under 3.2, which is considerably more
work and would lose the associative arrays entirely.

CI installs bash explicitly on the macOS runner for this reason, so the suite
does not silently depend on whichever version the image happens to carry.

## 4. subtitle-report: normalize_lang never matches a multi-word language name

`normalize_lang` strips all whitespace from its input before looking it up:

```bash
raw="${raw//[[:space:]]/}"
```

but `init_lang_map` registers the multi-word names with their spaces intact
(`modern greek`, `church slavonic`, `haitian creole`, `northern sami`, …). Those
keys are therefore unreachable: `Modern Greek` becomes `moderngreek`, misses the
map, and is passed through as a language code. Seventeen of the table's names are
affected, among them `modern greek`, `haitian creole`, `northern sami`,
`western frisian` and `south ndebele`.

Either strip the spaces from the keys as they are registered, or collapse runs of
whitespace to a single space instead of removing it. `test/helpers-format.bats`
covers the single-word cases already, so the fix wants a case asserting
`normalize_lang "Modern Greek"` yields `el`.

## 5. validate_config's array check accepts a plain string

```bash
if ! declare -p "${var_name}" &>/dev/null || eval "(( \${#${var_name}[@]} == 0 ))"
```

For a scalar, `${#var[@]}` is 1, so `array:NAME` passes for any non-empty string
and only catches an unset or genuinely empty variable. A config that set
`EXCLUDES="*.tmp"` instead of `EXCLUDES=(*.tmp)` would validate and then behave
as a one-element array, which is not what the caller asked to check.

`declare -p` output can be tested for the `-a`/`-A` attribute to distinguish the
two. `test/lib-common.bats` covers the array cases that do work; the fix wants
one asserting a scalar is rejected.


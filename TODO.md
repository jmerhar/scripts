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

## 3. Release the bash-version declarations

`min_bash` in `scripts.yaml` now states the version each script needs, and
`bin/package-script.sh` turns it into a guard compiled into the published script,
a versioned `Depends: bash (>= X)` for the `.deb`, and `depends_on "bash"` plus a
shebang rewrite for the formula. `bin/check-bash-version.sh` re-derives the
requirement from the source so the field cannot drift.

What remains is shipping it: the declarations only reach users on the next
release of each affected script.

| Script | Feature | `min_bash` |
|---|---|---|
| `compare-dirs` | `${var,,}`, `declare -A` | 4.0 |
| `dmarc-report` | `declare -A` | 4.0 |
| `local-backup` | `mapfile` | 4.0 |
| `mdcheck-progress` | `mapfile` | 4.0 |
| `prune-orphaned-torrents` | `${var,,}`, `mapfile` | 4.0 |
| `remove-sidecars` | `${var,,}`, `declare -A` | 4.0 |
| `subtitle-report` | `${var,,}`, `declare -A` | 4.0 |
| `subtitle-sync` | `local -n` | 4.3 |

Seven are published to Homebrew and so were exposed to macOS's bash 3.2;
`mdcheck-progress` is Debian-only and every supported Debian release ships bash 5,
so its declaration is documentation rather than a fix.

Note that until a script is re-released, its currently published version still
carries no guard. The failure there is at least loud — under `errexit` a missing
`mapfile` exits 127 and a nameref exits 2 — but the message names the construct,
not the cause.

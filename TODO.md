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


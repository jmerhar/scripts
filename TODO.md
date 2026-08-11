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

These scripts are also the bulk of the uncovered lines, so this is what will move
the published coverage figure more than anything else.

## 3. Reshape the statements coverage cannot credit

Bash attributes a multi-line command to its final line, so the first line of each
`\` continuation reads as never executed and the continuation lines are not
instrumented at all; the closing brace of a redirected group (`} >> "$file"`) is
never reported either. Roughly 115 lines here can therefore never be credited
however thorough the tests are, which is part of why the gate in `coverage.toml`
sits where it does.

The fix is to reshape those statements rather than try to test them: argument
arrays with named variables for the long invocations, a function for the
redirected group. There are 114 continuations — 46 in `dmarc-report`, 21 in
`subtitle-sync`, 15 in `prune-orphaned-torrents` — and one redirected group at
`bin/package-script.sh:307`.

Worth doing as its own change, raising the gate afterwards so the effect is
visible. The suite asserts behaviour rather than layout, so it stays valid across
the reshaping and protects it.

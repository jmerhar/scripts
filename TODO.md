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

## 2. Unit testing for shell scripts

Investigate whether unit testing is practical for this repo's scripts.

Bash has frameworks like [bats-core](https://github.com/bats-core/bats-core)
(Bash Automated Testing System) that allow writing `.bats` test files with
`setup`/`teardown` lifecycle hooks and TAP-compliant output. With every script
now in Bash, `bats-core` covers the whole repo.

Areas to explore:

- **What to test**: pure functions in `scripts/lib/common.sh` are the best
  starting point (`validate_config`, `load_config`, `get_script_prefix`).
  `bin/compile-includes.sh` is also a good candidate since its `process_file`
  function has well-defined input/output behavior.
- **CI integration**: bats-core can run in GitHub Actions (`setup-bats-action`
  or a plain `npm install -g bats`). Tests could gate merges without slowing
  down the release workflow.
- **Scope**: keep tests focused on logic, not on external tools like `rsync` or
  `dpkg-deb`. Mock or stub those at the boundary.


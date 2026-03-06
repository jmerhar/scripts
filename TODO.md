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

## 2. Unit testing for shell and Perl scripts

Investigate whether unit testing is practical for this repo's scripts.

Bash has frameworks like [bats-core](https://github.com/bats-core/bats-core)
(Bash Automated Testing System) that allow writing `.bats` test files with
`setup`/`teardown` lifecycle hooks and TAP-compliant output. For Perl,
`Test::More` is part of core and would work out of the box for
`remove-sidecars.pl`.

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

## 3. Rewrite remove-sidecars in Bash

`scripts/photography/remove-sidecars.pl` is the only Perl script in the repo.
Rewriting it in Bash would bring it in line with every other script and let it
use `common.sh` for colored output, logging, config loading, and the `@include`
build pipeline.

Feasibility considerations:

- **File traversal and grouping**: the core logic groups files by base name and
  checks for RAW/sidecar pairs. Bash can do this with `find` and associative
  arrays (`declare -A`), though it will be more verbose than Perl's hashes.
- **Interactive prompts**: already done in other scripts (`read -p`). Color
  output would come from `common.sh` instead of `Term::ANSIColor`.
- **Human-readable sizes**: a small `format_size()` helper with `bc` or pure
  arithmetic is straightforward.
- **Edge cases**: filenames with spaces/special chars need careful quoting.
  Perl's `File::Spec` handles this automatically; in Bash it requires
  discipline but is doable.
- **Dry-run mode and reporting**: already patterned in other scripts.
- **Risk**: the Perl version is well-tested in practice. A rewrite should be
  verified against the same directory trees before replacing it.

## 4. Google Shell Style audit

Do a full-repo review to ensure all Bash scripts follow the
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
Then codify it as an explicit project standard:

- **Audit scope**: all files under `scripts/` and `bin/`. Check function naming
  (lowercase with underscores), variable quoting, `local` usage, doc-block
  format, error handling patterns, and shebang lines.
- **README update**: add a "Code style" or "Contributing" section that
  references the Google Shell Style Guide as the project's standard.
- **CLAUDE.md update**: add an explicit line stating that all Bash code must
  follow Google Shell Style, so Claude Code enforces it in future sessions.
- **Tooling**: consider adding a `shellcheck` CI step if not already present,
  and potentially `shfmt` for automated formatting.

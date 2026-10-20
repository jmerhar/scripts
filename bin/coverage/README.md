# `bin/coverage/` — coverage hooks

The runner itself is shared: jmerhar/coverage's `run-kcov.sh` (fetched into `.coverage-tooling/` by
`make coverage-tooling`, and the `kcov` action in CI) reads the suite in `coverage.toml` and calls these.

| Script | Role |
|---|---|
| `measure.sh` | The suite's `command`: runs the bats suite with `COVERAGE_DIR` set, from the repository root, and removes the per-script harness files the test helper leaves behind. Writes bats's JUnit report when `JUNIT_DIR` is set. |
| `setup.sh` | The suite's `setup`, run in the kcov container only: installs bats from source and mikefarah's yq at their pinned versions, so a local run, the macOS job and the Linux container all behave alike. |

The kcov seam that makes the tools traceable lives in `test/test_helper.bash`, not here.

# `bin/coverage/` — coverage runner

| Script | Role |
|---|---|
| `run-coverage.sh` | Runs the bats suite under kcov and leaves a merged report in `coverage/`. It does not gate: `make coverage` applies the shared gate from `coverage.toml` afterwards, and `make test-coverage` skips it. Pinned to a kcov image by digest and a bats version, so a local run, the macOS job and the Linux container all behave alike. On macOS it detects kcov exec'ing `/bin/bash` 3.2 and falls back to the pinned container, so `make coverage` needs Docker rather than a local kcov. |

The kcov seam that makes the tools traceable lives in `test/test_helper.bash`, not here;
this script only runs the suite under the instrumented binary and removes the per-script
harness files a run leaves behind.

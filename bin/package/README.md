# `bin/package/` — packaging and release

Build, smoke-test, release and publish the scripts.

| Script | Role |
|---|---|
| `package-script.sh` | Generates the Homebrew formula, `.deb` package and release tarball for one script, reading metadata from `scripts.yaml`. Compiles the script through `../compile/compile-includes.sh` before packaging, so an artefact is never built from the development form. |
| `smoke-package-all.sh` | Packages every manifest entry at `v0.0.0` as a smoke test, catching manifest/packager drift before a release. Driven by `make smoke` and the lint workflow. |
| `release-package.sh` | Packages a release from a tag (one script) or a manual dispatch (the latest of every script), uploads the tarball, and prints the commit message the downstream repositories carry. Called by the publish workflow. |
| `publish-downstream.sh` | The fetch-reset-regenerate-push cycle both downstream repositories (the Homebrew tap and the APT repo) share, including the APT index rebuild and signing. Retries against a moving remote. |

`class-name.awk` lives here beside `package-script.sh`, which runs it via `awk -f` to turn
a script name into the CamelCase class name a Homebrew formula requires.

`release-package.sh` and `smoke-package-all.sh` call `package-script.sh` as same-directory
siblings; `package-script.sh` calls `../compile/compile-includes.sh` (cross-group) and
`publish-downstream.sh` calls `../docs/update-readme-index.sh` (cross-group).

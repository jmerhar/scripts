# `bin/docs/` — README index generation

The two scripts that regenerate the script index sections in the README files from
`scripts.yaml`.

| Script | Role |
|---|---|
| `update-readme-index.sh` | Regenerates the index section in one README: a level-3 heading per script (linking to its directory), the manifest `description` as a paragraph, and a tagline of minimum bash version and dependencies. Supports `--link` (none/repo/sibling), `--topic`, `--sort`, `--platform-note` and `--check`. Called directly by `publish-downstream.sh` (in `bin/package/`) to refresh each downstream repo's index. |
| `update-all-indexes.sh` | Calls the generator for the root README (`--link repo`) and each `scripts/<topic>/README.md` (`--link sibling --topic`), deriving the topic list from the manifest. Driven by `make docs` / `make docs-check`. |

`update-readme-index.sh` runs `splice-index.awk` (beside it in this directory) via `awk -f`
to splice the generated index between the `<!-- BEGIN INDEX -->` / `<!-- END INDEX -->`
markers. `update-all-indexes.sh` calls `update-readme-index.sh` as a same-directory sibling.

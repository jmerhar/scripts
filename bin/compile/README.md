# `bin/compile/` — the `@include` compiler

The two scripts that inline the shared library and embedded programs into a publishable
single-file script.

| Script | Role |
|---|---|
| `compile-includes.sh` | Processes one file: replaces each `# @include <path>` with the file's contents, inlines `# @embed` programs, drops `source`/shellcheck lines, and refuses a cycle. Used by `package-script.sh` (in `bin/package/`) to compile each script it packages. |
| `compile-all-includes.sh` | Walks `scripts/` and compiles every publishable script into `dist/compiled/`. A script with no directives is copied, so the directory is the complete set. Driven by `make compile`, and by `check-published-form.sh` (in `bin/lint/`) into a throwaway directory. |

`compile-all-includes.sh` calls `compile-includes.sh` as a same-directory sibling.

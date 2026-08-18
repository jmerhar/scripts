# `bin/lint/` — static checks

The five `check-*` scripts that validate the manifest, the bash-version declarations, the
awk/jq programs, the `@include` graph, and the published form. Each fails the build on its
concern. All five run in the lint workflow; locally the first four run from `make lint`,
while `check-published-form.sh` runs from `make published` — it compiles a throwaway tree,
which is slower than the rest of `make lint` put together. `make check` runs both.

| Script | Checks |
|---|---|
| `check-manifest.sh` | Every registered script exists, is executable, starts with a shebang and has a README; the shared library is not executable; unregistered scripts under `scripts/` are reported. |
| `check-bash-version.sh` | Re-derives the bash requirement from each script's source and fails if `min_bash` is missing or too low for the features used. |
| `check-programs.sh` | Syntax-checks every `.awk` and `.jq` program beside a script, and rejects a single quote in a program under `scripts/` (which would break embedding). |
| `check-includes.sh` | Computes the `@include` closure and fails when a script calls a library function no included library provides, or a loader pair disagrees. |
| `check-published-form.sh` | Compiles a throwaway copy and asserts every published script is self-contained: no surviving directive, no sourced library, every embedded program matching its file. |

`check-published-form.sh` shells out to `../compile/compile-all-includes.sh` to compile the
throwaway tree, the one cross-group call in this directory.

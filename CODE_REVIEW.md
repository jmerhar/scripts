# Code Review — Scripts Ecosystem

Comprehensive review of the entire three-repository ecosystem:

- **jmerhar/scripts** — source repository (all scripts, packaging system, CI/CD)
- **jmerhar/homebrew-scripts** — Homebrew tap (generated formulas)
- **jmerhar/apt-scripts** — APT repository (generated .deb packages, signed metadata)

**Reviewed:** 2026-03-04

---

## Table of Contents

1. [Repository-Wide Issues](#1-repository-wide-issues)
2. [system/package-script.sh](#2-systempackage-scriptsh)
3. [system/install-dependency.sh](#3-systeminstall-dependencysh)
4. [system/local-backup.sh](#4-systemlocal-backupsh)
5. [utility/unlock-pdf.sh](#5-utilityunlock-pdfsh)
6. [photography/photo-backup.sh](#6-photographyphoto-backupsh)
7. [photography/remove-sidecars.pl](#7-photographyremove-sidecarspl)
8. [CI/CD Pipeline (.github/workflows/publish.yml)](#8-cicd-pipeline)
9. [Configuration Files (conf/)](#9-configuration-files)
10. [Documentation](#10-documentation)
11. [Homebrew Tap (jmerhar/homebrew-scripts)](#11-homebrew-tap)
12. [APT Repository (jmerhar/apt-scripts)](#12-apt-repository)

Severity labels: **[bug]** likely incorrect behavior, **[security]** security concern,
**[robustness]** could fail under realistic conditions, **[improvement]** quality or
maintainability suggestion, **[style]** cosmetic / convention.

---

## 1. Repository-Wide Issues

### ✅ 1.1 [improvement] No automated testing or linting

There are no tests, no ShellCheck CI step, and no linting for the Perl script.
For a packaging system that generates artifacts distributed to users, at minimum:

- Run `shellcheck` on every `.sh` file in CI.
- Add a basic smoke test for `package-script.sh` (source `test_env.sh`, run it
  against each script, verify the outputs exist and contain expected content).
- Run `perl -c` on the Perl script.
- Consider [bats-core](https://github.com/bats-core/bats-core) for shell testing.

### ✅ 1.2 [improvement] Inconsistent shebang lines

`install-dependency.sh` uses `#!/bin/bash` while every other shell script uses
`#!/usr/bin/env bash`. The `env` form is the portable convention and should be
used consistently.

### ✅ 1.3 [improvement] Inconsistent strict-mode flags

| Script            | errexit | nounset | pipefail | xtrace |
|-------------------|---------|---------|----------|--------|
| package-script.sh | yes     | yes     | no       | yes    |
| install-dependency.sh | yes | yes     | no       | no     |
| unlock-pdf.sh     | yes     | yes     | no       | no     |
| local-backup.sh   | yes     | yes     | yes      | no     |
| photo-backup.sh   | yes     | yes     | yes      | no     |

`pipefail` should be enabled in all scripts — without it, errors in the left side
of a pipe are silently swallowed. The two scripts that omit it
(`install-dependency.sh`, `unlock-pdf.sh`) should add it.

### 1.4 [improvement] Duplicated helper code

`log_error()`, `show_usage()`, `get_script_prefix()`, `load_config()` and the
validation pattern are copy-pasted across scripts with minor variations. As the
collection grows, this will cause drift. Consider extracting a shared library
(e.g., `system/lib-common.sh`) that scripts source at runtime, or accept the
duplication and enforce consistency with a linter/template.

### ✅ 1.5 [improvement] No `set -o pipefail` in `package-script.sh`

This is the build tool — silent pipe failures here could produce bad packages.
Add `set -o pipefail`.

### 1.6 [style] Inconsistent log format

`local-backup.sh` uses `[YYYY-MM-DDTHH:MM:SS+TZ] [LEVEL]:` while other scripts
use `[YYYY-MM-DDTHH:MM:SS+TZ]: Error:`. The two-bracket format with an explicit
level field is more structured and greppable. Standardize on one.

---

## 2. system/package-script.sh

### ✅ 2.1 [bug] Homebrew formula embeds the repo-relative source path

Line 272:

```ruby
bin.install "utility/unlock-pdf.sh" => "unlock-pdf"
```

The `bin.install` path is taken from `${source_script_path}`, which is the
repo-relative path like `./utility/unlock-pdf.sh`. In a Homebrew build from a
tarball, the actual path inside the extracted archive includes a directory prefix
(`scripts-<tag>/utility/unlock-pdf.sh`). A Homebrew formula using this path
literally will fail at install time unless Homebrew strips the prefix.

Verify that this path resolves correctly within the Homebrew build sandbox. If
not, strip the leading `./` and compute the path relative to the tarball root.

### ✅ 2.2 [bug] Homebrew formula has a blank line when there is no config file

Line 273-275: When `config_file_path` is empty, the `$(if ...)` substitution
produces a blank line inside the `def install` block. While Ruby tolerates this,
it is untidy and could confuse formula auditing tools (`brew audit`).

### 2.3 [robustness] Associative array iteration order is nondeterministic

Lines 249 and 333: Iterating `${!metadata[@]}` produces keys in hash order, which
varies between Bash versions and runs. For the Homebrew formula this means the
output order of extra fields (like `license`) is unpredictable. For the Debian
control file, field ordering matters less, but deterministic output is still
valuable for reproducible builds. Sort the keys explicitly.

### 2.4 [robustness] Metadata regex is too permissive on value whitespace

Line 187: The regex `^#\ ([[:alnum:]-]+):[[:space:]]*(.*)$` trims leading
whitespace from the value but includes trailing whitespace. This could silently
embed trailing spaces in the Debian control file or Homebrew formula. Strip
trailing whitespace from `${value}`.

### 2.5 [robustness] Debian control file field-name matching is fragile

Line 335:

```bash
if [[ "${REQUIRED_FIELDS[*]}" =~ ${key} || ... ]]; then
```

This is a substring match against the space-joined array. A metadata key like
`NameLong` would match `Name` and be incorrectly skipped. Use a word-boundary
pattern or iterate the array for exact matches.

### 2.6 [improvement] `xtrace` is always on

`set -o xtrace` (line 35) is useful for CI debugging but produces extremely noisy
output. Consider making it conditional on an environment variable
(e.g., `PKGSCR_DEBUG`).

### 2.7 [improvement] `generate_deb_package` returns 1 on missing `dpkg-deb` but `main` doesn't handle it

Line 294: If `dpkg-deb` is missing, `generate_deb_package` returns 1. Under
`set -o errexit` this would cause the script to exit immediately — which is the
correct behavior, but the `return 1` + log message saying "Skipping" is misleading.
Either truly skip it (suppress errexit for that call) or exit explicitly with a
clear message.

### 2.8 [improvement] Homebrew formula's `class_name` conversion doesn't handle underscores

Line 231-236: The `awk` splits on `-` but not `_`. A script named `my_script`
would generate class `My_script` instead of `MyScript`. Since one delimiter is
already in use (`-`), this is low risk today, but the conversion should handle
both.

### ✅ 2.9 [improvement] Debian packages install to `/usr/local` — non-standard for `.deb`

Lines 314-315: Debian packages conventionally install to `/usr` (binaries in
`/usr/bin`, config in `/etc`). Installing to `/usr/local/bin` and `/usr/local/etc`
is unusual for managed packages and may confuse users or policy tools like
`lintian`. If `/usr/local` is intentional (to avoid conflicts with system
packages), document the reasoning. Otherwise, consider `/usr/bin` and `/etc`.

---

## 3. system/install-dependency.sh

### ✅ 3.1 [bug] Shebang is `#!/bin/bash`, not `#!/usr/bin/env bash`

See [1.2]. On NixOS or Guix systems, `/bin/bash` may not exist.

### 3.2 [robustness] `read -p` without `-r` on some paths

Line 64 and 92: `read -p` is used with `-n 1 -r`. Good — `-r` prevents backslash
interpretation. No issue here, just confirming.

### 3.3 [improvement] No validation of the package name argument

The package name is passed straight to `brew install` or `apt-get install`.
While this script is meant to be called from other scripts (not user-facing), a
basic sanitization check (e.g., reject names with spaces, slashes, or
shell metacharacters) would be defensive.

### 3.4 [improvement] `apt-get update` runs on every install

Line 96: Running `apt-get update` before every single package install is slow.
Consider checking if the package is already available first, or making the update
optional.

### 3.5 [improvement] Script is not referenced by any other script

The `utility/README.md` mentions that `unlock-pdf.sh` "automatically calls the
`install-dependency.sh` script to install it" — but the actual `unlock-pdf.sh`
code does not reference `install-dependency.sh` at all. It just prints a manual
install message and exits. The README is inaccurate, or the integration was
removed. See [10.3].

---

## 4. system/local-backup.sh

### ✅ 4.1 [bug] `EXCLUDES` validation fails if array is unset

Line 168:

```bash
if (( ${#EXCLUDES[@]} == 0 )); then
```

Under `set -o nounset`, if the config file doesn't define `EXCLUDES` at all, this
line will throw `unbound variable` before the check runs. Use `${#EXCLUDES[@]:-0}`
pattern or check with `declare -p EXCLUDES` first.

Note: `load_config` temporarily disables nounset for sourcing, but `EXCLUDES` is
checked *after* nounset is re-enabled in `validate_config`. If the sourced config
doesn't set `EXCLUDES`, this will error.

### ✅ 4.2 [security] Config file is sourced without validation

Line 144: `source "${CONFIG_FILE_LOADED}"` executes arbitrary shell code. If the
config file is writable by an unprivileged user but the script runs as root (the
recommended usage for system backup), this is a privilege escalation vector.

Mitigations: ensure the config file is owned by root and not world-writable, or
parse the config values without `source` (e.g., using `grep` + `eval` on specific
known variables only).

This concern applies equally to `photo-backup.sh` (line 223).

### 4.3 [robustness] Backup pruning relies on `sort` of directory names

Line 236:

```bash
mapfile -t backups < <(find "${BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d | sort)
```

The directories are named `YYYY-MM-DD_HH:MM:SS`, so lexicographic sort happens to
match chronological order — but only because the date format is fixed-width and
zero-padded. If any non-backup directory exists in `BACKUP_DIR` (e.g., `lost+found`
on ext4), it will be included in the sort and may be pruned. Filter to match the
date pattern:

```bash
find "${BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d -name '[0-9][0-9][0-9][0-9]-*' | sort
```

### 4.4 [robustness] `latest` symlink is not excluded from prune

The `find` on line 236 uses `-type d`, so the `latest` symlink (which is `-type l`)
is correctly excluded. Good. But if someone creates a stale `latest` directory
(rather than symlink), it could be counted and pruned. Minor risk.

### ✅ 4.5 [robustness] The `latest` symlink update is not atomic

Lines 222-223:

```bash
rm -f "${latest_link}"
ln -s "${backup_path}" "${latest_link}"
```

Between these two lines, `latest` does not exist. If another process (or a cron
overlap) reads the symlink during this window, it will fail. Use `ln -sfn` (which
is atomic on most filesystems) or create a temp symlink and `mv` it into place.

### ✅ 4.6 [robustness] Concurrent backup runs are not guarded

If cron fires twice (e.g., system time jump), two instances could run
simultaneously, creating interleaved backups and corrupted pruning. A lockfile
(e.g., via `flock`) would prevent this.

### 4.7 [improvement] `KEEP_BACKUPS` is not validated as a positive integer

A config value of `KEEP_BACKUPS=0` or `KEEP_BACKUPS=-1` or `KEEP_BACKUPS=abc`
would cause arithmetic errors or delete all backups. Validate that it is a
positive integer before proceeding.

### 4.8 [improvement] No `--info=progress2` or summary output

The script is cron-friendly (silent on success) which is good, but when run
interactively there is no progress indication. Consider detecting a TTY and
adding `--info=progress2` for interactive runs.

---

## 5. utility/unlock-pdf.sh

### ✅ 5.1 [security] Password is visible in the process list

Line 92:

```bash
qpdf --decrypt "--password=${password}" "${input_file}" "${output_file}"
```

The password is passed as a command-line argument, which means it is visible to
any user via `ps aux` for the duration of the `qpdf` process. `qpdf` supports
`--password-file` to read the password from a file descriptor. Consider:

```bash
qpdf --decrypt --password-file=<(printf '%s' "${password}") "${input_file}" "${output_file}"
```

This keeps the password off the process list. Document this caveat if you choose
not to change it.

### 5.2 [robustness] No validation that the input file exists or is a PDF

The script will fail with a cryptic `qpdf` error if the file doesn't exist or
isn't a valid PDF. Add a pre-check:

```bash
if [[ ! -f "$input_file" ]]; then
  log_error "File not found: $input_file"
  exit 1
fi
```

### 5.3 [robustness] Output file could silently overwrite an existing file

If `document-unlocked.pdf` already exists, `qpdf` will overwrite it without
warning. Consider checking for the output file and prompting or erroring.

### ✅ 5.4 [improvement] Missing `set -o pipefail`

See [1.3].

### 5.5 [improvement] Password on command line is visible in shell history

This is inherent to the interface design (password as a positional arg). The
README should note this and suggest `history -d` or a leading space. Alternatively,
add a `-p` flag or read from stdin when no password arg is provided.

---

## 6. photography/photo-backup.sh

### 6.1 [bug] `log_error` is called before color variables are defined

Lines 249 (in `parse_options`, the `*` case) and 139 (in
`handle_legacy_configuration`) call `log_error`. The color constants are defined
at the top of the script as `readonly` globals, so this is actually fine — they
are defined before any function runs. No bug on closer inspection, but the
ordering of function definitions before globals made this look suspect. Consider
moving all globals above all function definitions for clarity.

### ✅ 6.2 [bug] Legacy config migration uses `mv` which doesn't preserve permissions

Line 177:

```bash
mv "${temp_config}" "${config_file}"
```

`mktemp` creates files with mode 600. The original config file may have been
644 (readable by the script's non-root user). After `mv`, the config file will
be 600, potentially breaking subsequent reads. Use `cp` + `rm` instead, or
restore permissions with `chmod` after the move.

### ✅ 6.3 [bug] Legacy migration regex also matches commented-out lines

Line 133:

```bash
if grep -q -E "^SRC_[12]=" "${config_file}" && ! grep -q "^SOURCES=" "${config_file}"; then
```

If the migration already ran once (commenting out `SRC_1` as `# SRC_1=`), the
`^SRC_[12]=` pattern will correctly not match the commented version (since it
starts with `#`). Good. However, the `sed` on line 170:

```bash
sed 's/^\(SRC_[12]\)/# \1/' "${config_file}" > "${temp_config}"
```

will also match and re-comment any `SRC_3`, `SRC_10`, etc. (since `[12]` means
the character `1` or `2`, not the numbers 1 and 2, so this is fine). But it will
also match lines like `SRC_1_BACKUP=...` or `SRC_2_NOTE=...`. Use a more
anchored pattern: `'s/^\(SRC_[12]=\)/# \1/'`.

### ✅ 6.4 [robustness] Protection filter generation shells out to `sh`, not `bash`

Line 452: The inline script uses `sh -c '...'`, which invokes POSIX `sh`. The
`set -o pipefail` inside is a Bash extension and will fail on systems where `sh`
is `dash` (e.g., Debian/Ubuntu). Either use `bash -c` or remove the
`set -o pipefail` from the inlined script.

### ✅ 6.5 [robustness] `find -print0` + `read -d ""` — POSIX compatibility concern

Line 456: The `while IFS= read -r -d "" path` construct is Bash-specific and won't
work under `sh`. This reinforces [6.4]: use `bash -c` instead of `sh -c`.

### 6.6 [robustness] `run_command` pipes through `tee`, swallowing exit codes

Line 377:

```bash
"$@" 2>&1 | tee -a "${LOG_FILE}"
```

Without `pipefail` (which is set in this script), this is fine — the pipe returns
`tee`'s exit code, but since `pipefail` is on, it returns the failing command's
code. However, `2>&1` merges stderr into stdout, so error messages from rsync will
go to stdout instead of stderr. Consider using `tee` on stderr separately or
using process substitution to preserve the stream separation.

### 6.7 [robustness] `clean_directory` runs `find -delete` on source directories

Lines 425-426: `remove_files` runs `find ... -delete -print` on the user's source
directories before backup. If the user has legitimate files named `*_original`
(not related to macOS), they will be silently deleted. The `*_original` pattern is
quite broad. Consider making the cleanup patterns configurable, or document
exactly what gets deleted.

### 6.8 [improvement] `TEMP_DIR` cleanup trap doesn't handle signals

Line 52:

```bash
trap 'rm -rf "${TEMP_DIR}"' EXIT
```

`EXIT` is fine for normal termination but consider also trapping `INT` and `TERM`
to clean up on Ctrl+C.

Actually, in Bash, `EXIT` traps *do* fire on signal-induced exit. This is fine.

### 6.9 [improvement] `get_script_prefix()` is duplicated from `local-backup.sh`

Exact same function in two scripts. See [1.4].

### ✅ 6.10 [improvement] `-echo` after `-n 1` in parse_options error path

Line 249: In the `*` case of `getopts`, `OPTARG` may not be set for unknown
options. Test with `getopts` to confirm behavior — for flags not in the optstring,
`OPTARG` is set to the flag character when using `:` prefix, but not otherwise.
Since the optstring doesn't start with `:`, the shell prints its own error and
`OPTARG` is unset. The `log_error` will fail under `nounset`. Either prefix the
optstring with `:` to suppress default errors and handle them yourself, or remove
the `${OPTARG}` reference from the error message.

---

## 7. photography/remove-sidecars.pl

### ✅ 7.1 [bug] `unlink` return value is not checked

Line 240:

```perl
unlink $file;
```

`unlink` can fail (permissions, file already gone, etc.) and silently continues.
The reported "recovered" disk space will be wrong if any deletes fail. Check the
return value:

```perl
unlink $file or warn "Could not delete $file: $!\n";
```

### 7.2 [robustness] No argument validation or `--help` flag

If the user passes `--help` or an invalid option, it silently treats it as a
directory path and attempts to scan `--help` as a directory. Add basic argument
handling with `Getopt::Long` or at least validate that the argument is a directory.

### 7.3 [robustness] Symlink following during traversal

`traverse_tree` uses `opendir`/`readdir` and checks `-d $path` for recursion.
On systems with symlinks, this will follow symlinks into potentially cyclic or
very deep directory structures. Use `-l $path` to skip or detect symlinks, or
use `File::Find` which handles this.

### 7.4 [robustness] Very large directories could exhaust memory

The `$files` hash in `traverse_tree` and the global `$files_to_delete` hash both
grow without bound. For the stated use case (100k+ photos), this should be fine —
a hash of 100k entries is manageable. But the protection is `process_dir` being
called per-directory, keeping `$files` scoped. Acceptable.

### 7.5 [improvement] Case-sensitivity in extension matching

The default sidecar list includes both `JPG` and `jpg`, `JPEG` and `jpeg` — but
the RAW list includes `RW2`, `CR2`, `DNG`, `dng` (missing `rw2`, `cr2`). If a
camera produces lowercase RAW extensions, they won't be matched. Use
case-insensitive comparison (`lc()`) rather than relying on the user to list
every casing variant.

### 7.6 [improvement] `print_directories` has a complex one-liner that's hard to follow

Line 216:

```perl
for my $dir (sort(uniq(map { $count->{dirname($_)}++; dirname($_) } @{ $files_to_delete->{$raw_ext} }))) {
```

This calls `dirname` twice per file and has a side effect inside `map`. Refactor
for clarity.

### 7.7 [improvement] No dry-run mode

For a destructive operation (file deletion), a `--dry-run` / `-n` flag that shows
what would be deleted without actually deleting would add significant safety.

### 7.8 [style] No `use autodie` or error checking on `opendir`

Line 107: `opendir ... || die` is fine. But `closedir` on line 129 has no error
check. Use `use autodie` for consistent error handling, or keep the manual checks
and add one to `closedir`.

---

## 8. CI/CD Pipeline

### 8.1 [security] GPG passphrase passed via environment variable

Line 162:

```bash
echo "$GPG_PRIVATE_KEY" | gpg --batch --import --passphrase "$GPG_PASSPHRASE"
```

The passphrase is in an environment variable, which is visible in `/proc/*/environ`
on Linux. While GitHub Actions runners are ephemeral and isolated, using
`--pinentry-mode loopback` with `--passphrase-fd` is marginally more secure.
Low risk in this context.

### ✅ 8.2 [robustness] `actions/checkout@v3` is outdated

`actions/checkout@v3` is deprecated; `v4` has been the standard since late 2023.
Update all three checkout steps to `@v4`.

### 8.3 [robustness] `shasum` may not be available on all runners

Line 76:

```bash
CHECKSUM=$(curl -sSL "${TARBALL_URL}" | shasum -a 256 | awk '{print $1}')
```

Ubuntu runners should have `shasum` but the canonical Linux tool is `sha256sum`.
Use `sha256sum` directly for clarity and reliability on Linux runners, or use
`shasum -a 256` with a fallback.

### ✅ 8.4 [robustness] No error handling if the tarball download fails

If `curl` fails silently (e.g., 404), the checksum will be computed against an
HTML error page. Add `curl --fail` or check the HTTP status code.

### 8.5 [robustness] Race condition in multi-repo push

If two releases are published in quick succession, the Homebrew and APT repo
pushes could conflict (non-fast-forward). The workflow doesn't retry or lock.
Low probability but worth noting.

### ✅ 8.6 [improvement] No workflow for PRs

There is no CI workflow that runs on pull requests. Even a simple ShellCheck +
metadata validation step would catch issues before merge.

### 8.7 [improvement] `dpkg-scanpackages` deprecation warning

`dpkg-scanpackages` emits a deprecation warning on newer Debian/Ubuntu. Consider
using `apt-ftparchive packages` instead for generating the `Packages` file.

---

## 9. Configuration Files

### 9.1 [robustness] `local-backup.conf` ships with `BACKUP_DIR=` (empty)

The template has an empty `BACKUP_DIR=` value. If a user installs the package and
runs `local-backup` without editing the config, validation will catch it and error.
Good. But a clearer template would comment out the line entirely or use a
placeholder like `BACKUP_DIR="/path/to/your/backup"`.

### 9.2 [robustness] `photo-backup.conf` ships with empty arrays and strings

Similar to above. `SOURCES=()`, `HOST=""`, `DEST_PATH=""` will all be caught by
validation. Fine.

### 9.3 [improvement] Config files are sourced as shell code

See [4.2]. Both config files are `source`d, meaning they execute arbitrary shell.
This is the Bash convention for config files, but it is a known risk vector.
Document this clearly: "This file is sourced by Bash. Do not include untrusted
content."

---

## 10. Documentation

### ✅ 10.1 [bug] `system/README.md` documents obsolete environment variable names for `package-script.sh`

Line 41-48 of `system/README.md` lists environment variables like
`HOMEPAGE_URL`, `HOMEBREW_FORMULA_DIR`, `DEB_PACKAGE_DIR`, `CONFIG_DIR`,
`MAINTAINER_INFO`, `TARBALL_URL`, `VERSION`, `SHA256_CHECKSUM`. The actual
script uses `PKGSCR_` prefixed names (`PKGSCR_HOMEBREW_FORMULA_DIR`,
`PKGSCR_TARBALL_URL`, etc.). The documentation is completely out of date.

### ✅ 10.2 [bug] `system/README.md` says `package-script.sh` "parses metadata from a corresponding `README.md` file"

Line 28: The script actually parses metadata from comment blocks *inside the
script files themselves*, not from README files. This is factually wrong.

### ✅ 10.3 [bug] `utility/README.md` claims unlock-pdf auto-installs dependencies

The README says unlock-pdf "automatically calls the `install-dependency.sh` script
to install [qpdf]". The actual code only prints a manual install message and exits.
The integration with `install-dependency.sh` does not exist.

### 10.4 [improvement] No changelog or release notes convention

With per-script versioning, there is no way for users to know what changed in a
new version. Consider maintaining a `CHANGELOG.md` per script or using GitHub
Release notes.

### ✅ 10.5 [improvement] `photography/README.md` sample output shows `y` as a valid answer

Line 149:

```
Would you like to (d)elete them, (s)ee a list of directories, or (q)uit? [d/s/Q] y
```

The actual code only accepts `d`, `s`, or `q`. Answering `y` would be treated as
quit. The example should show `d`.

---

## 11. Homebrew Tap (jmerhar/homebrew-scripts)

### ✅ 11.1 [bug] Blank lines in generated `def install` blocks

Formulas without a config file (`install-dependency.rb`, `package-script.rb`,
`remove-sidecars.rb`, `unlock-pdf.rb`) all contain a trailing blank line inside
the `def install` block:

```ruby
  def install
    bin.install "./system/install-dependency.sh" => "install-dependency"

  end
```

This is generated by `package-script.sh` (see [2.2]). While Ruby tolerates it,
`brew audit --strict` may flag it, and it looks unpolished for generated output.

### ✅ 11.2 [improvement] No `test do` blocks in any formula

Homebrew best practices recommend a `test do ... end` block for every formula so
that `brew test <formula>` works. Even a simple version/help check would suffice:

```ruby
test do
  assert_match "Usage:", shell_output("#{bin}/unlock-pdf 2>&1", 1)
end
```

None of the six formulas include tests.

### ✅ 11.3 [improvement] `package-script` formula probably shouldn't be published

`package-script.sh` is a CI-only build tool that depends on `dpkg-deb` (not
available on macOS via Homebrew). It also `depends_on "awk"`, which is already
built into macOS. Publishing this to Homebrew has no practical use for end users
and could confuse people. Consider excluding CI-internal scripts from the tap.

Similarly, `install-dependency` is meant to be called by other scripts, not
installed standalone by users. Its Homebrew formula's utility is questionable.

### 11.4 [improvement] README doesn't list available scripts

The tap README only shows a generic install example. Users have no way to
discover what scripts are available without browsing the `Formula/` directory.
Add a table of available scripts with descriptions.

### 11.5 [improvement] README tap command is inconsistent

The README says `brew tap jmerhar/scripts` but the repo is
`jmerhar/homebrew-scripts`. Homebrew's convention is that `brew tap jmerhar/scripts`
maps to the repo `jmerhar/homebrew-scripts`, so this is actually correct. But it
would be clearer to show both forms.

---

## 12. APT Repository (jmerhar/apt-scripts)

### ✅ 12.1 [improvement] Old package versions accumulate in `pool/`

The `pool/main/` directory contains 30 `.deb` files across all historical versions
(e.g., 9 versions of `package-script`, 8 versions of `photo-backup`). The
`Packages` index only references the latest version of each, so the old `.deb`
files are dead weight — they consume repository space and get cloned by anyone
who checks out the repo, but are never installed by `apt-get`.

Add a cleanup step to the CI workflow that removes old versions from `pool/`,
or implement a retention policy (e.g., keep last 2 versions).

### 12.2 [improvement] `package-script` and `install-dependency` are published as Debian packages

Same concern as [11.3]. `package-script` depends on `awk` and `dpkg-deb` — on a
Debian system `dpkg-deb` is already installed and `awk` is in `base-files`. The
package has no real purpose for end users. Consider not publishing CI-internal
tools as packages.

### 12.3 [improvement] Debian control file includes a non-standard `Homepage` field from metadata

Looking at the generated `Packages` file, the packages include `Homepage:` which
is a standard Debian field — good. But the control file generation in
`package-script.sh` (see [2.5]) dumps *all* extra metadata keys into the control
file without validation. If a new metadata key is added (e.g., `Foo: bar`), it
will appear as a non-standard field in the control file, which `lintian` will warn
about.

### 12.4 [improvement] Release file checksums include the Release file itself

The `dists/stable/Release` file lists checksums for itself (`Release` at 199
bytes). This is a circular reference — the file's own checksum changes when the
file content changes. This happens because `apt-ftparchive release` scans
`dists/stable/` which already contains the previous `Release` file. The CI
workflow should delete the old `Release` before generating a new one:

```bash
rm -f dists/stable/Release
apt-ftparchive -c apt-ftparchive.conf release dists/stable/ > dists/stable/Release
```

### ✅ 12.5 [improvement] No GitHub Pages configuration documented

The APT repo is served via GitHub Pages (`https://jmerhar.github.io/apt-scripts/`).
The repo has no `.nojekyll` file. GitHub Pages runs Jekyll by default, which could
interfere with files starting with underscores or containing special characters.
Add an empty `.nojekyll` file to the repository root to disable Jekyll processing.

### 12.6 [improvement] GPG key has no documented expiration or rotation policy

The `public.key` is committed to the repo but there is no documentation about:
- When the key expires (or if it does)
- How users should handle key rotation
- The key fingerprint for manual verification

Add a section to the README with the key fingerprint and expiration date.

---

## Summary of Priority Items

**Fix these first (bugs / security):**

1. ✅ [10.1, 10.2] `system/README.md` is substantially out of date — wrong variable
   names and wrong description of how metadata works.
2. ✅ [10.3] `utility/README.md` documents a feature that doesn't exist.
3. ✅ [6.4, 6.5] `photo-backup.sh` shells out to `sh` with Bash-specific syntax.
   Will break on Debian/Ubuntu where `sh` is `dash`.
4. ✅ [4.1] `local-backup.sh` will crash if `EXCLUDES` is not defined in config.
5. ✅ [4.2] Config file sourcing as root is a privilege escalation risk — document
   or mitigate.
6. ✅ [5.1] PDF password visible in process list.
7. ✅ [6.2] Legacy migration clobbers config file permissions.
8. ✅ [7.1] `unlink` failures silently ignored in `remove-sidecars.pl`.

**High-value improvements:**

9. ✅ [1.1] Add ShellCheck and basic smoke tests to CI.
10. ✅ [8.2] Update `actions/checkout` to v4.
11. ✅ [8.4] Add `--fail` to `curl` in CI to catch download failures.
12. ✅ [4.5, 4.6] Make symlink update atomic; add a lockfile for cron safety.
13. ✅ [1.2, 1.3] Standardize shebangs and strict-mode flags.
14. ✅ [2.9] Reconsider `/usr/local` as the Debian install prefix. (Intentional — documented)
15. ✅ [11.3, 12.2] Stop publishing CI-internal tools (`package-script`,
    `install-dependency`) as user-facing packages.
16. ✅ [12.1] ~~Clean up old `.deb` versions from the APT pool.~~ All versions now served via multiversion Packages index.
17. ✅ [11.2] Add `test do` blocks to Homebrew formulas.
18. ✅ [12.4] Fix self-referencing checksum in APT Release file.
19. ✅ [12.5] Add `.nojekyll` to the APT repo.

---

## Remaining Items — Prioritised

### Tier 1 — Bugs (likely incorrect behavior)

- ✅ [2.1] Homebrew formula embeds repo-relative source path — may break installs from tarball.
- ✅ [2.2, 11.1] Blank line in `def install` when no config file — untidy generated output.
- ✅ [6.3] Legacy migration regex also matches commented-out lines.
- ✅ [6.10] `OPTARG` is unset under `nounset` in `parse_options` error path — will crash.
- ✅ [10.5] `photography/README.md` sample output shows `y` as a valid answer.

### Tier 2 — Robustness (could fail under realistic conditions)

- ✅ [2.3] Associative array iteration order is nondeterministic — unpredictable output.
- ✅ [2.4] Metadata regex includes trailing whitespace in values.
- ✅ [2.5] Debian control file field-name matching is fragile (substring match).
- ✅ [4.3] Backup pruning could delete non-backup directories like `lost+found`.
- ✅ [4.7] `KEEP_BACKUPS` not validated as a positive integer.
- ✅ [5.2] No validation that input file exists or is a PDF.
- ✅ [5.3] Output file silently overwrites existing file.
- ✅ [6.6] `run_command` merges stderr into stdout via `tee`.
- ✅ [7.2] No argument validation or `--help` in Perl script.
- ✅ [7.3] Symlink following during directory traversal.
- ✅ [8.3] `shasum` may not be available on all CI runners.

### Tier 3 — Improvements (quality / maintainability)

- ✅ [2.6] `xtrace` always on in `package-script.sh`.
- ✅ [2.7] Misleading "Skipping" message when `dpkg-deb` is missing.
- ✅ [2.8] `class_name` conversion doesn't handle underscores.
- ✅ [3.3] No validation of package name argument in `install-dependency.sh`. *(N/A — script deleted)*
- ✅ [3.4] `apt-get update` runs on every install. *(N/A — script deleted)*
- ✅ [4.8] No progress output for interactive backup runs.
- ✅ [5.5] Password visible in shell history. *(N/A — password now prompted interactively)*
- ✅ [6.7] `clean_directory` deletes `*_original` files broadly.
- [6.9] `get_script_prefix()` duplicated across scripts. *(Accepted — see Tier 4 [1.4])*
- [7.5] Case-sensitivity in RAW extension matching. *(Won't fix — case-sensitive matching is intentional, allows distinguishing sources e.g. Android .dng vs Lightroom .DNG. Future camera-based exclusion planned in TODO.md.)*
- ✅ [7.6] Complex one-liner in `print_directories`.
- ✅ [7.7] No dry-run mode for `remove-sidecars.pl`.
- ✅ [8.7] `dpkg-scanpackages` deprecation warning.
- ✅ [9.1] `local-backup.conf` ships with empty `BACKUP_DIR=`.
- ✅ [11.4] Homebrew tap README doesn't list available scripts.
- ✅ [12.3] Non-standard fields leak into Debian control file.

### Tier 4 — Low priority / won't fix

- ⏭️ [1.4] Duplicated helper code — accepted tradeoff for standalone scripts.
- ⏭️ [1.6] Inconsistent log format — style only.
- ⏭️ [3.2] `read -p` without `-r` — review confirms no bug.
- ✅ [3.5] `install-dependency.sh` not referenced. *(N/A — script deleted)*
- ⏭️ [4.4] Stale `latest` directory risk — minor edge case.
- ⏭️ [6.1] Color vars before functions — review confirms no bug.
- ⏭️ [6.8] Trap doesn't handle signals — EXIT is sufficient in Bash.
- ⏭️ [7.4] Large directories memory — acceptable for stated use case.
- ⏭️ [7.8] No `use autodie` — style only.
- ⏭️ [8.1] GPG passphrase via env var — low risk on ephemeral runners.
- ✅ [8.5] Race condition in multi-repo push — push steps now retry with rebase.
- ✅ [9.2] Config ships with empty values — caught by validation. *(Also improved in [9.1])*
- ⏭️ [9.3] Config sourced as shell code — already documented.
- ⏭️ [10.4] No changelog convention — process, not code.
- ⏭️ [11.5] Homebrew tap command is inconsistent — already correct per Homebrew conventions.
- ⏭️ [12.6] GPG key rotation docs — process, not code.

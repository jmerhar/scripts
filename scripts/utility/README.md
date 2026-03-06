# Utility Scripts

General-purpose user-facing utilities. For installation instructions, see the [main README](../../README.md#installation).

## `unlock-pdf`

Decrypts a password-protected PDF file using [`qpdf`](https://github.com/qpdf/qpdf).

### Features

* **Simple** — Unlocks a PDF with a single command.
* **Safe Output** — Creates a new `*-unlocked.pdf` file, leaving the original untouched.
* **Input Validation** — Checks that the file exists and has a `.pdf` extension before processing.
* **Overwrite Protection** — Refuses to run if the output file already exists.
* **Secure** — Passes the password via a file descriptor (`--password-file`) to keep it out of the process list.
* **Dependency Detection** — Prints OS-specific installation instructions if `qpdf` is not found.

### Requirements

* [`qpdf`](https://github.com/qpdf/qpdf)

### Usage

```bash
unlock-pdf <password> <input.pdf>
```

This creates `input-unlocked.pdf` in the same directory.

```bash
$ unlock-pdf 'my-secret-password' path/to/document.pdf
Writing path/to/document-unlocked.pdf...
Done.
```

> **Tip:** The password will be saved in your shell history. Prefix the command with a space (` unlock-pdf ...`) to prevent this, or use `history -d` afterwards.

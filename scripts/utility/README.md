# Utility Scripts

General-purpose user-facing utilities. For installation instructions, see the [main README](../../README.md#installation).

## `unlock-pdf`

Decrypts a password-protected PDF file using [`qpdf`](https://github.com/qpdf/qpdf).

### Features

* **Simple** — Unlocks a PDF with a single command.
* **Safe Output** — Creates a new `*-unlocked.pdf` file, leaving the original untouched.
* **Input Validation** — Checks that the file exists and has a `.pdf` extension before processing.
* **Overwrite Protection** — Refuses to run if the output file already exists.
* **Secure** — Prompts for the password interactively (hidden input), keeping it out of shell history and the process list.
* **Dependency Detection** — Prints OS-specific installation instructions if `qpdf` is not found.

### Requirements

* [`qpdf`](https://github.com/qpdf/qpdf)

### Usage

```bash
unlock-pdf <input.pdf>
```

The script prompts for the password interactively:

```
$ unlock-pdf path/to/document.pdf
Password:
Writing path/to/document-unlocked.pdf...
Done.
```

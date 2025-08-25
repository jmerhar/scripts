# Utility Scripts

This directory contains a collection of user-facing scripts designed to perform everyday tasks and automate common workflows.

## Scripts

### `unlock-pdf.sh`

A script to decrypt a password-protected PDF file.

#### Features
-   **Simple Usage**: Unlocks a PDF with a single command.
-   **Automatic Dependency Management**: If the required `qpdf` utility is not found, it automatically calls the `install-dependency.sh` script to install it.
-   **Safe Output**: Creates a new, unlocked file with an `-unlocked` suffix, preserving the original file.

#### Dependencies
-   **`qpdf`**: The core command-line tool used for PDF manipulation.
-   **`install-dependency.sh`**: (Optional) Must be in the system's `PATH` for automatic installation of `qpdf`.

#### Usage
Run the script with the PDF password and the input filename as arguments.

```bash
# Usage: ./unlock-pdf.sh <password> <input.pdf>

./unlock-pdf.sh 'my-secret-password' 'path/to/document.pdf'
```

This will create a new file named `document-unlocked.pdf` in the same directory.

#!/bin/bash

# This script decrypts a password-protected PDF file using qpdf.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Dependency Check ---
# Verify that qpdf is installed before proceeding.
if ! command -v qpdf &> /dev/null; then
    echo "Error: 'qpdf' is not installed or not in your PATH." >&2
    # Provide OS-specific installation instructions.
    case "$(uname)" in
        "Darwin")
            echo "Please install it using Homebrew: 'brew install qpdf'" >&2
            ;;
        "Linux")
            echo "Please install it using APT: 'sudo apt-get install qpdf'" >&2
            ;;
        *)
            echo "Please install 'qpdf' using your system's package manager." >&2
            ;;
    esac
    exit 1
fi

# --- 2. Argument Validation ---
# Check if exactly two arguments (password and input file) are provided.
if [ "$#" -ne 2 ]; then
    # Print usage instructions if the arguments are incorrect.
    echo "Usage: $(basename "$0") <password> <input.pdf>"
    exit 1
fi

# --- 3. Assign Variables ---
PASSWORD="$1"
INPUT_FILE="$2"

# --- 4. Process Files ---
# Generate the output filename.
# This uses Bash parameter expansion to remove the '.pdf' suffix from the input file
# and then appends '-unlocked.pdf'.
OUTPUT_FILE="${INPUT_FILE%.pdf}-unlocked.pdf"

# --- 5. Decrypt the PDF ---
echo "Writing ${OUTPUT_FILE}..."

# Run the qpdf command to decrypt the file.
# --password="$PASSWORD": Provides the password for decryption.
# "$INPUT_FILE": Specifies the source PDF.
# "$OUTPUT_FILE": Specifies the destination for the decrypted PDF.
qpdf --decrypt "--password=${PASSWORD}" "${INPUT_FILE}" "${OUTPUT_FILE}"

echo "done."

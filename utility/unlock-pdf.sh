#!/bin/bash

# This script decrypts a password-protected PDF file using qpdf.
# If a dependency is not found, it calls an external script to handle the installation.

# --- SETTINGS ---
# Name of the dependency installer script. Assumed to be in the system's PATH.
INSTALLER_SCRIPT="install-dependency"

# Exit immediately if a command exits with a non-zero status.
set -e

# --- FUNCTIONS ---

# Checks for a command and calls the installer script if it's not found.
# @param {string} dependency_name - The name of the command/package to check for.
ensure_dependency() {
    local dependency_name="$1"
    
    # Check if the dependency command is available in the system's PATH.
    if ! command -v "$dependency_name" &> /dev/null; then
        echo "'$dependency_name' is not found. Attempting to run the dependency installer..."
        
        # Check if the installer script itself exists in the PATH and is executable.
        if command -v "$INSTALLER_SCRIPT" &> /dev/null; then
            # Call the installer script and check its exit code.
            if ! "$INSTALLER_SCRIPT" "$dependency_name"; then
                echo "Error: The installer script failed to install '$dependency_name'." >&2
                exit 1
            fi
        else
            echo "Error: '$dependency_name' is not installed and the installer script '$INSTALLER_SCRIPT' was not found in your PATH." >&2
            echo "Please install '$dependency_name' manually or ensure '$INSTALLER_SCRIPT' is in your PATH." >&2
            exit 1
        fi
    fi
}


# --- SCRIPT START ---

# 1. Argument Validation
# Check if exactly two arguments (password and input file) are provided.
if [ "$#" -ne 2 ]; then
    # Print usage instructions if the arguments are incorrect.
    # Use 'basename' to only show the script's filename.
    echo "Usage: $(basename "$0") <password> <input.pdf>"
    exit 1
fi

# 2. Assign Variables
PASSWORD="$1"
INPUT_FILE="$2"

# 3. Dependency Check
# Ensure that 'qpdf' is installed, or attempt to install it.
ensure_dependency "qpdf"

# 4. Process Files
# Generate the output filename.
# This uses Bash parameter expansion to remove the '.pdf' suffix from the input file
# and then appends '-unlocked.pdf'.
OUTPUT_FILE="${INPUT_FILE%.pdf}-unlocked.pdf"

# 5. Decrypt the PDF
echo "Writing ${OUTPUT_FILE}..."

# Run the qpdf command to decrypt the file.
# --password="$PASSWORD": Provides the password for decryption.
# "$INPUT_FILE": Specifies the source PDF.
# "$OUTPUT_FILE": Specifies the destination for the decrypted PDF.
qpdf --decrypt "--password=${PASSWORD}" "${INPUT_FILE}" "${OUTPUT_FILE}"

echo "done."

#!/bin/bash

# This script handles the installation of a specified package
# on macOS (via Homebrew) or Debian/Ubuntu Linux (via apt-get).

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Argument Validation ---
# Check if exactly one argument (the package name) is provided.
if [ "$#" -ne 1 ]; then
    echo "Usage: $(basename "$0") <package_name>"
    exit 1
fi

PACKAGE_NAME="$1"

echo "Attempting to install '$PACKAGE_NAME'..."

# --- 2. OS-Specific Installation ---
# Determine the operating system.
OS_TYPE=$(uname)

case "$OS_TYPE" in
    "Darwin")
        # --- macOS Dependency Logic ---
        # Check if Homebrew ('brew') is installed.
        if ! command -v brew &> /dev/null; then
            echo "Error: Homebrew is not installed." >&2
            echo "Please install Homebrew to automatically manage dependencies: https://brew.sh/" >&2
            exit 1
        fi

        # Prompt the user for confirmation before installing.
        read -p "Do you want to install '$PACKAGE_NAME' with Homebrew? (y/N) " -n 1 -r
        echo # Move to a new line after the prompt.

        # Check if the user's reply starts with 'Y' or 'y'.
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # If confirmed, use Homebrew to install the package.
            echo "Installing '$PACKAGE_NAME'..."
            brew install "$PACKAGE_NAME"
            echo "'$PACKAGE_NAME' installed successfully."
        else
            # If not confirmed, exit the script.
            echo "Installation cancelled by user. Exiting."
            exit 1
        fi
        ;;

    "Linux")
        # --- Debian/Ubuntu Linux Dependency Logic ---
        # Check if apt-get is available.
        if ! command -v apt-get &> /dev/null; then
            echo "Error: 'apt-get' not found. This script supports Debian-based Linux distributions." >&2
            echo "Please install '$PACKAGE_NAME' manually." >&2
            exit 1
        fi

        # Prompt the user for confirmation before installing.
        read -p "Do you want to install '$PACKAGE_NAME' with apt-get? This will require sudo privileges. (y/N) " -n 1 -r
        echo # Move to a new line after the prompt.
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Updating package list and installing '$PACKAGE_NAME'..."
            # Update package lists and install the package.
            sudo apt-get update
            sudo apt-get install -y "$PACKAGE_NAME"
            echo "'$PACKAGE_NAME' installed successfully."
        else
            echo "Installation cancelled by user. Exiting."
            exit 1
        fi
        ;;

    *)
        # --- Unsupported OS ---
        echo "Error: Unsupported operating system '$OS_TYPE'." >&2
        echo "Please install '$PACKAGE_NAME' manually to proceed." >&2
        exit 1
        ;;
esac

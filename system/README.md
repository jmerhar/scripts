# System Scripts

This directory contains scripts that handle system-level tasks, such as package installation and environment configuration. These scripts are typically designed to be called by other, higher-level scripts and may not be intended for direct user interaction.

## Scripts

### `install-dependency.sh`

A cross-platform script to install a given package on macOS or Debian-based Linux.

#### Features
-   **OS Detection**: Automatically detects if the OS is macOS or Linux.
-   **Package Manager Support**: Uses Homebrew on macOS and `apt-get` on Debian/Ubuntu.
-   **User Confirmation**: Prompts the user for confirmation before proceeding with any installation.
-   **Error Handling**: Exits with a non-zero status code on failure, allowing calling scripts to handle errors.

#### Usage
This script is intended to be called from another script. It takes a single argument: the name of the package to install.

```bash
# Example: Called from another script to ensure 'qpdf' is installed
./install-dependency.sh qpdf

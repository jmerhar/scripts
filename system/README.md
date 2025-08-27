# System Scripts

This directory contains scripts that handle system-level tasks, such as package installation and environment configuration. These scripts are typically designed to be called by other, higher-level scripts and may not be intended for direct user interaction.

## Scripts

### `install-dependency.sh`

A cross-platform script to install a given package on macOS or Debian-based Linux.

#### Features
* **OS Detection**: Automatically detects if the OS is macOS or Linux.
* **Package Manager Support**: Uses Homebrew on macOS and `apt-get` on Debian/Ubuntu.
* **User Confirmation**: Prompts the user for confirmation before proceeding with any installation.
* **Error Handling**: Exits with a non-zero status code on failure, allowing calling scripts to handle errors.

#### Usage
This script is intended to be called from another script. It takes a single argument: the name of the package to install.

```bash
# Example: Called from another script to ensure 'qpdf' is installed
./install-dependency.sh qpdf
```

### `publish.sh`

A powerful, generic script that automates the process of publishing a command-line utility to both a Homebrew tap and a Debian APT repository. It is designed to be run from a CI/CD workflow, such as GitHub Actions, and is configured entirely through environment variables.

#### Features

* **Cross-Platform Packaging**: Creates both Homebrew formula files for macOS and Debian `.deb` packages for Linux.

* **Dynamic File Paths**: Uses environment variables to handle different repository names and file paths, making it highly reusable.

* **Automatic Metadata Extraction**: Automatically parses the script's `README.md` for its description and dependencies.

* **Checksum Calculation**: Automatically fetches the latest release and computes the `sha256` checksum.

* **Extensible**: The logic can be easily adapted to support other package managers.

#### Dependencies

* `curl`

* `shasum` (or equivalent on Linux)

* `awk`

* `dpkg-deb` (for Debian package creation)

* `gpg` (for APT repository signing)

#### Usage

This script is not intended for direct use on the command line. Instead, it is designed to be called by a CI/CD workflow, which provides it with the necessary environment variables. The workflow must be configured to set the following variables for the script to function correctly:

* `GITHUB_USER`: Your GitHub username (e.g., `jmerhar`).

* `SCRIPTS_REPO`: The name of the main scripts repository (e.g., `scripts`).

* `HOMEBREW_TAP_REPO`: The name of the Homebrew tap repository (e.g., `homebrew-scripts`).

* `APT_REPO`: The name of the APT repository (e.g., `apt-scripts`).

* `MAINTAINER_INFO`: The maintainer's name and email for the Debian packages.

* `TARBALL_URL`: The URL to the tarball of the new release.

* `VERSION`: The version string (e.g., `v1.0.1`).

* `SHA256_CHECKSUM`: The pre-calculated checksum of the release tarball.

* `DEB_DIST_DIR`: The temporary directory where final `.deb` files will be placed.

**Example of a Workflow Call:**

```bash
./system/publish.sh "utility/unlock-pdf.sh"
```
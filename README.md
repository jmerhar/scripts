# Shell Scripts Collection

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This repository contains a curated collection of scripts designed for the automation of various tasks within Unix-like operating environments, including macOS and Linux.

## Repository Structure

The repository is structured into three primary directories:

* `/system`: This directory houses low-level scripts, such as package builders and dependency managers, which are typically invoked by other scripts or CI/CD workflows.
* `/utility`: This directory contains high-level, user-facing scripts designed to execute specific, practical tasks.
* `/photography`: Contains scripts specifically related to photography workflows.

Each directory includes a dedicated `README.md` file that provides more detailed information regarding its contents.

## Installation

There are several methods for installing and utilizing these scripts. The recommended approach is to use a package manager, as this handles dependencies and PATH configuration automatically.

### macOS with Homebrew (Recommended)

For users on macOS with Homebrew, the scripts can be installed directly from a custom tap.

1.  **Add the custom tap:**
    ```bash
    brew tap jmerhar/scripts
    ```

2.  **Install a specific script:**
    ```bash
    # Example: Install the 'unlock-pdf' script
    brew install unlock-pdf
    ```

### Debian/Ubuntu Linux (Recommended)

For users on Debian-based distributions like Ubuntu, the scripts can be installed from a custom APT repository.

1.  **Add the GPG Key and Repository Source:**
    Run the following commands to trust the repository's GPG key and add it to your system's sources.
    ```bash
    # Add the GPG key
    wget -qO- https://jmerhar.github.io/apt-scripts/public.key | sudo gpg --dearmor -o /etc/apt/keyrings/jmerhar-scripts.gpg

    # Add the repository source
    echo "deb [arch=all signed-by=/etc/apt/keyrings/jmerhar-scripts.gpg] https://jmerhar.github.io/apt-scripts/ stable main" | sudo tee /etc/apt/sources.list.d/jmerhar-scripts.list
    ```

2.  **Install a specific script:**
    First, update your package list, then install the desired script.
    ```bash
    # Update package lists
    sudo apt-get update

    # Example: Install the 'unlock-pdf' script
    sudo apt-get install unlock-pdf
    ```

### Manual Installation

For other Unix-like systems, or for users who prefer not to use a package manager, the scripts can be installed manually.

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/jmerhar/scripts.git
    cd scripts
    ```

2.  **Make the script executable:**
    ```bash
    chmod +x utility/unlock-pdf.sh
    ```

3.  **Run the script:**
    Execute the script directly from its path, or move it to a directory in your system's `PATH` (e.g., `/usr/local/bin`) for global access.

## Contributing

Suggestions for improvement to this collection are welcome. Contributions can be made by opening an issue to discuss potential changes or by submitting a pull request with proposed enhancements.

## License

This project is distributed under the terms of the MIT License. For further details, please refer to the [LICENSE](LICENSE) file.

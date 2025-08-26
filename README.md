# Shell Scripts Collection

This repository contains a curated collection of scripts designed for the automation of various tasks within Unix-like operating environments, including macOS and Linux.

## Repository Structure

The repository is structured into two primary directories:

* `/system`: This directory houses low-level scripts intended for system administration and dependency management, which are typically invoked by other scripts.

* `/utility`: This directory contains high-level, user-facing scripts designed to execute specific, practical tasks.

Each directory includes a dedicated `README.md` file that provides more detailed information regarding its contents.

## Usage

There are two primary methods for installing and utilizing these scripts.

### macOS with Homebrew (Recommended)

For users on macOS with Homebrew, the scripts can be installed directly from a custom tap, which manages the installation and ensures they are available in the system's PATH.

1.  **Add the custom tap:**
    ```bash
    brew tap jmerhar/scripts
    ```

2.  **Install a specific script:**
    Once the tap is configured, individual scripts can be installed using `brew install`.
    ```bash
    # Example: Install the 'unlock-pdf' script
    brew install unlock-pdf
    ```

### Manual Installation

For other Unix-like systems, or for users who prefer not to use Homebrew, the scripts can be installed manually.

1.  **Clone the repository:**
    ```bash
    git clone [https://github.com/jmerhar/scripts.git](https://github.com/jmerhar/scripts.git)
    cd scripts
    ```

2.  **Make the script executable:**
    It is necessary to ensure that the script has execute permissions.
    ```bash
    chmod +x utility/unlock-pdf.sh
    ```

3.  **Run the script:**
    The script can be executed from its location or, for global accessibility, moved to a directory included in the system's `PATH` variable (e.g., `/usr/local/bin`).

## Contributing

Suggestions for improvement to this collection are welcome. Contributions can be made by opening an issue to discuss potential changes or by submitting a pull request with proposed enhancements.

## License

This project is distributed under the terms of the MIT License. For further details, please refer to the [LICENSE](LICENSE) file.

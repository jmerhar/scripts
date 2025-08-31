#!/bin/bash
# --- SCRIPT INFO START ---
# Name: install-dependency
# Description: Handles the installation of a specified package on macOS (via Homebrew) or Debian-based Linux (via apt-get).
# Author: Jure Merhar <dev@merhar.si>
# Homepage: https://github.com/jmerhar/scripts
# License: MIT
# --- SCRIPT INFO END ---
#
# Handles the installation of a specified package on macOS (via Homebrew) or
# Debian-based Linux (via apt-get).
#
# This script is designed to be called by other scripts that have external
# dependencies which need to be installed.
#
# Usage:
#   ./install-dependency.sh <package_name>

set -o errexit
set -o nounset

#######################################
# Prints a timestamped error message to stderr.
# Globals:
#   None
# Arguments:
#   Message to print.
# Outputs:
#   Writes timestamped error message to stderr.
#######################################
log_error() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: Error: $*" >&2
}

#######################################
# Prints the script's usage instructions to stdout.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
#######################################
show_usage() {
  echo "Usage: $(basename "$0") <package_name>"
}

#######################################
# Installs a package on macOS using Homebrew.
# Globals:
#   None
# Arguments:
#   The name of the package to install.
#######################################
install_package_macos() {
  local package_name="$1"

  if ! command -v brew &> /dev/null; then
    log_error "Homebrew is not installed."
    echo "Please install Homebrew to manage dependencies: https://brew.sh/" >&2
    exit 1
  fi

  read -p "Install '${package_name}' with Homebrew? (y/N) " -n 1 -r
  echo
  if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    echo "Installing '${package_name}'..."
    brew install "${package_name}"
    echo "'${package_name}' installed successfully."
  else
    echo "Installation cancelled by user."
    exit 1
  fi
}

#######################################
# Installs a package on Debian-based Linux using apt-get.
# Globals:
#   None
# Arguments:
#   The name of the package to install.
#######################################
install_package_linux() {
  local package_name="$1"

  if ! command -v apt-get &> /dev/null; then
    log_error "'apt-get' not found. This script supports Debian-based systems."
    echo "Please install '${package_name}' manually." >&2
    exit 1
  fi

  read -p "Install '${package_name}' with apt-get? (requires sudo) (y/N) " -n 1 -r
  echo
  if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    echo "Updating package list and installing '${package_name}'..."
    sudo apt-get update
    sudo apt-get install -y "${package_name}"
    echo "'${package_name}' installed successfully."
  else
    echo "Installation cancelled by user."
    exit 1
  fi
}

main() {
  if (( $# != 1 )); then
    log_error "Missing required package name argument."
    show_usage
    exit 1
  fi

  local package_name="$1"
  echo "Attempting to install '${package_name}'..."

  local os_type
  os_type=$(uname)

  case "${os_type}" in
    "Darwin")
      install_package_macos "${package_name}"
      ;;
    "Linux")
      install_package_linux "${package_name}"
      ;;
    *)
      log_error "Unsupported operating system '${os_type}'."
      echo "Please install '${package_name}' manually." >&2
      exit 1
      ;;
  esac
}

main "$@"

#!/bin/bash
#
# Decrypts a password-protected PDF file using the 'qpdf' command-line tool.
#
# This script requires 'qpdf' to be installed and available in the system's PATH.
# It provides OS-specific installation instructions if the dependency is not found.
#
# Usage:
#   ./unlock-pdf.sh <password> <input.pdf>

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
  echo "Usage: $(basename "$0") <password> <input.pdf>"
}

#######################################
# Verifies that the 'qpdf' dependency is installed.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes error messages to stderr if dependency is not found.
#######################################
check_dependencies() {
  if ! command -v qpdf &> /dev/null; then
    log_error "'qpdf' is not installed or not in your PATH."
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
}

#######################################
# Decrypts the given PDF file using the provided password.
# Globals:
#   None
# Arguments:
#   password: The password for the PDF file.
#   input_file: The path to the PDF file to decrypt.
# Outputs:
#   Writes progress messages to stdout.
#   Creates a new, unlocked PDF file.
#######################################
decrypt_pdf() {
  local password="$1"
  local input_file="$2"
  local output_file="${input_file%.pdf}-unlocked.pdf"

  echo "Writing ${output_file}..."
  qpdf --decrypt "--password=${password}" "${input_file}" "${output_file}"
  echo "Done."
}

main() {
  check_dependencies

  if (( $# != 2 )); then
    log_error "Missing required arguments."
    show_usage
    exit 1
  fi

  decrypt_pdf "$1" "$2"
}

main "$@"

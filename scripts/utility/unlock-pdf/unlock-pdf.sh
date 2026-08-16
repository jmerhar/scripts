#!/usr/bin/env bash
#
# Decrypts a password-protected PDF file using the 'qpdf' command-line tool.
#
# This script requires 'qpdf' to be installed and available in the system's PATH.
# It provides OS-specific installation instructions if the dependency is not found.
#
# Usage:
#   ./unlock-pdf.sh <input.pdf>

set -o errexit
set -o nounset
set -o pipefail

# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh

#######################################
# Prints an error message to stderr and exits.
# Arguments:
#   Message to print.
#######################################
die() {
  log_error "$*"
  exit 1
}

#######################################
# Verifies that the 'qpdf' dependency is installed.
# Outputs:
#   Writes install instructions to stderr if dependency is not found.
#######################################
check_dependencies() {
  if ! command -v qpdf &> /dev/null; then
    log_error "'qpdf' is not installed or not in your PATH."
    case "$(uname)" in
      "Darwin")
        log_error "Install it with: brew install qpdf"
        ;;
      "Linux")
        log_error "Install it with: sudo apt-get install qpdf"
        ;;
      *)
        log_error "Please install 'qpdf' using your system's package manager."
        ;;
    esac
    exit 1
  fi
}

#######################################
# Decrypts the given PDF file using the provided password.
# Arguments:
#   password: The password for the PDF file.
#   input_file: The path to the PDF file to decrypt.
# Outputs:
#   Creates a new, unlocked PDF file.
#######################################
decrypt_pdf() {
  local password="$1"
  local input_file="$2"
  local output_file="${input_file%.pdf}-unlocked.pdf"

  [[ -f "${output_file}" ]] && die "Output file already exists: ${output_file}"

  echo "Writing ${output_file}..."
  qpdf --decrypt --password-file=<(printf '%s' "${password}") "${input_file}" "${output_file}"
  echo "Done."
}

#######################################
# Validates dependencies, prompts for a password, and decrypts the PDF.
# Arguments:
#   input_file - Path to the PDF file to decrypt.
#######################################
main() {
  check_dependencies

  if (( $# != 1 )); then
    echo "Usage: $(basename "$0") <input.pdf>" >&2
    exit 1
  fi

  local input_file="$1"

  [[ -f "${input_file}" ]] || die "File not found: ${input_file}"
  [[ "${input_file}" == *.pdf || "${input_file}" == *.PDF ]] || die "Not a PDF file: ${input_file}"

  local password
  read -r -s -p "Password: " password
  echo

  [[ -n "${password}" ]] || die "Password cannot be empty."

  decrypt_pdf "${password}" "${input_file}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

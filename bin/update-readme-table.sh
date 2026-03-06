#!/usr/bin/env bash
#
# Regenerates a markdown table in a README file from scripts.yaml.
#
# Replaces content between <!-- BEGIN TABLE --> and <!-- END TABLE -->
# markers with a table of script names and descriptions.
#
# Usage:
#   update-readme-table.sh <readme-file> <column-header>
#
# Arguments:
#   readme-file   - Path to the README file to update.
#   column-header - Header for the first column (e.g., "Formula", "Package").

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
MANIFEST="${SCRIPT_DIR}/../scripts.yaml"

#######################################
# Prints a timestamped error message to stderr.
# Arguments:
#   Message to print.
#######################################
log_error() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [ERROR]: $*" >&2
}

#######################################
# Prints a timestamped info message to stderr.
# Arguments:
#   Message to print.
#######################################
log_info() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [INFO]: $*" >&2
}

#######################################
# Prints usage instructions to stderr.
# Arguments:
#   None
#######################################
show_usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <readme-file> <column-header>

Arguments:
  readme-file   - Path to the README file to update.
  column-header - Header for the first column (e.g., "Formula", "Package").
EOF
}

main() {
  if (( $# != 2 )); then
    log_error "Expected exactly 2 arguments."
    show_usage
    exit 1
  fi

  local readme_file="$1"
  local column_header="$2"

  if [[ ! -f "${readme_file}" ]]; then
    log_error "README file not found: ${readme_file}"
    exit 1
  fi

  if [[ ! -f "${MANIFEST}" ]]; then
    log_error "Manifest not found: ${MANIFEST}"
    exit 1
  fi

  if ! command -v yq &> /dev/null; then
    log_error "'yq' is required but not found in PATH."
    exit 1
  fi

  log_info "Updating table in ${readme_file}..."

  # Build the table content in a temp file
  local table_file
  table_file=$(mktemp)

  echo "| ${column_header} | Description |" >> "${table_file}"
  echo "|---------|-------------|" >> "${table_file}"

  while IFS= read -r name; do
    local description
    description=$(yq eval ".scripts.\"${name}\".description" "${MANIFEST}")
    echo "| \`${name}\` | ${description} |" >> "${table_file}"
  done < <(yq eval '.scripts | keys | .[]' "${MANIFEST}")

  # Replace content between markers: read table from file, splice into README
  awk -v tfile="${table_file}" '
    /<!-- BEGIN TABLE -->/ {
      print
      while ((getline line < tfile) > 0) print line
      close(tfile)
      found=1
      next
    }
    /<!-- END TABLE -->/ { print ""; found=0 }
    !found { print }
  ' "${readme_file}" > "${readme_file}.tmp" && mv "${readme_file}.tmp" "${readme_file}"

  rm -f "${table_file}"

  log_info "Table updated in ${readme_file}."
}

main "$@"

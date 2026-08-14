#!/usr/bin/env bash
#
# Regenerates a markdown table in a README file from scripts.yaml.
#
# Replaces content between <!-- BEGIN TABLE --> and <!-- END TABLE -->
# markers with a table of script names and descriptions.
#
# Three shapes come out of the same manifest:
#
#   * the downstream repos (the Homebrew tap and the APT repo) list every script by name, with no links,
#     because there is nothing in those repos to link to;
#   * this repository's root README links each script to its own directory and names that directory;
#   * a topic README lists only its own scripts, linking to each as a sibling directory.
#
# The link target is the directory rather than the README inside it: GitHub renders a directory's README.md
# when the directory is visited, so the shorter target works and shows the script's other files beside its
# docs. An `#anchor` is the one thing a directory link cannot carry, and with one README per script there is
# nothing to anchor to.
#
# Both the topic and the link target come from the manifest's `path:`, so they cannot disagree with where a
# script actually lives; bin/check-manifest.sh already fails the build when a registered path is missing.
#
# Usage:
#   update-readme-table.sh <readme-file> <column-header> [options]
#
# Arguments:
#   readme-file   - Path to the README file to update.
#   column-header - Header for the first column (e.g., "Formula", "Package", "Script").
#
# Options:
#   --topic NAME       Only include scripts under scripts/NAME/.
#   --link MODE        none (default), repo (link to scripts/<topic>/<name>/), or
#                      sibling (link to <name>/, relative to a topic README).
#   --field NAME       Manifest field to use as the text: description (default) or summary.
#   --platform-note    Append _(Linux only)_ for scripts the manifest does not publish to Homebrew.
#   --sort             List scripts alphabetically rather than in manifest order.
#   --with-location    Add a third column naming the script's directory.
#   --check            Do not write; exit non-zero if the file is not already up to date.
#
# Two fields exist because the audiences differ: `description` is package metadata, read by anyone
# inspecting a .deb or a formula, and runs long. `summary` is the one-line form a reader of the
# documentation index wants. The downstream repos pass neither option, so they get `description`.

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
Usage: $(basename "$0") <readme-file> <column-header> [options]

Arguments:
  readme-file   - Path to the README file to update.
  column-header - Header for the first column (e.g., "Formula", "Package").

Options:
  --topic NAME       Only include scripts under scripts/NAME/.
  --link MODE        none (default), repo, or sibling.
  --field NAME       description (default) or summary.
  --platform-note    Append _(Linux only)_ for scripts not published to Homebrew.
  --sort             List alphabetically rather than in manifest order.
  --with-location    Add a third column naming the script's directory.
  --check            Do not write; fail if the file is out of date.
EOF
}

#######################################
# Writes the table rows for the manifest to stdout.
# Globals:
#   MANIFEST
# Arguments:
#   column_header, topic filter (may be empty), link mode, with_location (true/false).
# Outputs:
#   The complete markdown table.
#######################################
build_table() {
  local column_header="$1" topic="$2" link_mode="$3" with_location="$4" field="$5" platform_note="$6"
  local sort_names="$7"

  if [[ "${with_location}" == true ]]; then
    echo "| ${column_header} | Description | Location |"
    echo "|---------|-------------|----------|"
  else
    echo "| ${column_header} | Description |"
    echo "|---------|-------------|"
  fi

  local name description path dir label
  while IFS= read -r name; do
    path=$(yq eval ".scripts.\"${name}\".path" "${MANIFEST}")
    dir=$(dirname "${path}")

    # The topic is the directory component under scripts/, taken from the same path as the link, so a
    # filtered table and its links cannot describe different places.
    if [[ -n "${topic}" && "${dir}" != "scripts/${topic}/"* ]]; then
      continue
    fi

    description=$(yq eval ".scripts.\"${name}\".${field} // .scripts.\"${name}\".description" "${MANIFEST}")
    # These texts are plain prose from the manifest, not markdown, so the two characters that would be
    # reinterpreted are neutralised here rather than by requiring the manifest to hold pre-escaped
    # markdown. An unescaped pipe ends the cell and drops the rest of it; a word wrapped in asterisks
    # renders as emphasis with the asterisks eaten. `*arr` survives either way, since a lone asterisk
    # followed by a letter and preceded by a space cannot close emphasis.
    description="${description//|/\\|}"
    description="${description//\*/\\*}"

    if [[ "${platform_note}" == true ]]; then
      # Derived from the manifest rather than written into the text: `platforms` already records which
      # channels a script publishes to, and one without homebrew is one macOS cannot run.
      local platforms
      platforms=$(yq eval ".scripts.\"${name}\".platforms // [] | join(\",\")" "${MANIFEST}")
      if [[ -n "${platforms}" && "${platforms}" != *homebrew* ]]; then
        description+=" _(Linux only)_"
      fi
    fi

    case "${link_mode}" in
      repo)    label="[\`${name}\`](${dir}/)" ;;
      sibling) label="[\`${name}\`](${name}/)" ;;
      *)       label="\`${name}\`" ;;
    esac

    if [[ "${with_location}" == true ]]; then
      echo "| ${label} | ${description} | \`${dir}/\` |"
    else
      echo "| ${label} | ${description} |"
    fi
  done < <(list_names "${sort_names}")
}

#######################################
# Lists the manifest's script names, in manifest order or alphabetically.
#
# Manifest order is the default because the downstream tables are grouped by topic that way; the
# documentation indexes ask for alphabetical, which is what a reader scans.
# Globals:
#   MANIFEST
# Arguments:
#   sort_names: true to sort.
# Outputs:
#   One name per line.
#######################################
list_names() {
  if [[ "$1" == true ]]; then
    yq eval '.scripts | keys | .[]' "${MANIFEST}" | sort
  else
    yq eval '.scripts | keys | .[]' "${MANIFEST}"
  fi
}

#######################################
# Splices a table between the markers in a README, writing the result to stdout.
# Arguments:
#   readme_file, table_file.
# Outputs:
#   The README with the table replaced.
#######################################
splice_table() {
  awk -v tfile="$2" '
    /<!-- BEGIN TABLE -->/ {
      print
      while ((getline line < tfile) > 0) print line
      close(tfile)
      found=1
      next
    }
    /<!-- END TABLE -->/ { print ""; found=0 }
    !found { print }
  ' "$1"
}

#######################################
# Regenerates the markdown table in a README from the manifest.
# Arguments:
#   See show_usage.
#######################################
main() {
  if (( $# < 2 )); then
    log_error "Expected at least 2 arguments."
    show_usage
    exit 1
  fi

  local readme_file="$1" column_header="$2"
  shift 2

  local topic="" link_mode="none" with_location=false check_only=false
  local field="description" platform_note=false sort_names=false
  while (( $# > 0 )); do
    case "$1" in
      --topic)
        if (( $# < 2 )); then log_error "--topic requires a name."; exit 1; fi
        topic="$2"; shift 2 ;;
      --link)
        if (( $# < 2 )); then log_error "--link requires a mode."; exit 1; fi
        case "$2" in
          none | repo | sibling) link_mode="$2" ;;
          *) log_error "--link must be none, repo or sibling, got '$2'."; exit 1 ;;
        esac
        shift 2 ;;
      --field)
        if (( $# < 2 )); then log_error "--field requires a name."; exit 1; fi
        case "$2" in
          description | summary) field="$2" ;;
          *) log_error "--field must be description or summary, got '$2'."; exit 1 ;;
        esac
        shift 2 ;;
      --platform-note) platform_note=true; shift ;;
      --sort) sort_names=true; shift ;;
      --with-location) with_location=true; shift ;;
      --check) check_only=true; shift ;;
      *) log_error "Unknown option '$1'."; show_usage; exit 1 ;;
    esac
  done

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

  local table_file
  table_file=$(mktemp)
  build_table "${column_header}" "${topic}" "${link_mode}" "${with_location}" \
    "${field}" "${platform_note}" "${sort_names}" > "${table_file}"

  local rendered
  rendered=$(mktemp)
  splice_table "${readme_file}" "${table_file}" > "${rendered}"

  if [[ "${check_only}" == true ]]; then
    if ! diff -q "${readme_file}" "${rendered}" >/dev/null; then
      log_error "${readme_file} is out of date; run 'make docs'."
      diff "${readme_file}" "${rendered}" >&2 || true
      rm -f "${table_file}" "${rendered}"
      exit 1
    fi
    rm -f "${table_file}" "${rendered}"
    return 0
  fi

  log_info "Updating table in ${readme_file}..."
  mv "${rendered}" "${readme_file}"
  rm -f "${table_file}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

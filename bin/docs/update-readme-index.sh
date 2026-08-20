#!/usr/bin/env bash
#
# Regenerates the script index section in a README file from scripts.yaml.
#
# Replaces content between <!-- BEGIN INDEX --> and <!-- END INDEX --> markers with a
# heading-per-script index: a level-3 heading linking the script name, the manifest
# `description` as a paragraph, and a compact metadata tagline (minimum bash version and
# dependencies).
#
# Four shapes come out of the same manifest, differing only in where the heading links:
#
#   * the downstream repos (the Homebrew tap and the APT repo) list every script by name,
#     linking nowhere, because there is nothing in those repos to link to;
#   * this repository's root README links each script to its own directory;
#   * a topic README lists only its own scripts, linking to each as a sibling directory.
#
# The link target is the directory rather than the README inside it: GitHub renders a
# directory's README.md when the directory is visited, so the shorter target works and shows
# the script's other files beside its docs. An `#anchor` is the one thing a directory link
# cannot carry, and with one README per script there is nothing to anchor to.
#
# Both the topic and the link target come from the manifest's `path:`, so they cannot
# disagree with where a script actually lives; bin/lint/check-manifest.sh already fails the
# build when a registered path is missing.
#
# The description is plain prose from the manifest, emitted verbatim. A pipe and an
# asterisk are not special in a paragraph (the way they are in a table cell, where one ends a
# cell and the other opens emphasis), and a backslash escape would render as a visible
# backslash, so nothing is escaped here.
#
# Usage:
#   update-readme-index.sh <readme-file> [options]
#
# Arguments:
#   readme-file - Path to the README file to update.
#
# Options:
#   --topic NAME       Only include scripts under scripts/NAME/.
#   --link MODE        none (default), repo (link to scripts/<topic>/<name>/), or
#                      sibling (link to <name>/, relative to a topic README).
#   --platform-note    Annotate single-platform scripts: _(Linux only)_ when the manifest does not
#                      publish to Homebrew, _(macOS only)_ when it does not publish to Debian.
#   --sort             List scripts alphabetically rather than in manifest order.
#   --check            Do not write; exit non-zero if the file is not already up to date.
#
# `description` is the only manifest text field: the packager reads it as package metadata,
# and the index shows it in full, since a paragraph holds a longer text comfortably.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"

#######################################
# Prints usage instructions to stderr.
# Arguments:
#   None
#######################################
show_usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <readme-file> [options]

Arguments:
  readme-file - Path to the README file to update.

Options:
  --topic NAME       Only include scripts under scripts/NAME/.
  --link MODE        none (default), repo, or sibling.
  --platform-note    Mark single-platform scripts _(Linux only)_ or _(macOS only)_.
  --sort             List alphabetically rather than in manifest order.
  --check            Do not write; fail if the file is out of date.
EOF
}

#######################################
# Joins its arguments with the given separator, skipping empty parts.
#
# A script with no minimum-bash declaration and no dependencies must produce no tagline at
# all rather than a dangling separator, so every segment is added only when it has content.
# Globals:
#   None
# Arguments:
#   sep: Separator to place between non-empty parts.
#   parts...: Strings to join; empties are dropped.
# Outputs:
#   The joined string.
#######################################
join_by() {
  local sep="$1" out=""
  shift
  local part
  for part in "$@"; do
    [[ -z "${part}" ]] && continue
    if [[ -z "${out}" ]]; then
      out="${part}"
    else
      out+="${sep}${part}"
    fi
  done
  printf '%s' "${out}"
}

#######################################
# Builds the dependency segment of a script's tagline.
#
# Common dependencies apply to every platform and are named first; homebrew- and
# debian-only dependencies follow in parentheses, so a reader sees what their package
# manager installs beyond the shared set. The manifest stores one logical dependency under
# different package names per platform (libxml2 vs libxml2-utils both provide xmllint), so
# the lists are not merged: a reader of either platform needs its own name.
# Globals:
#   MANIFEST
# Arguments:
#   name: The script's manifest key.
# Outputs:
#   The deps segment ("deps: curl, jq (+libxml2 macOS, libxml2-utils & unzip Linux)"),
#   or empty when the script declares no dependencies.
#######################################
deps_segment() {
  local name="$1"
  # Each dependency is wrapped in backticks so it renders as inline code, matching the
  # `bash X+` segment and keeping command names visually distinct from prose. The script
  # name reaches yq through strenv rather than interpolation, so a name containing a quote
  # or backtick could not break out of the expression.
  local common homebrew debian
  common=$(name="${name}" yq eval '.scripts[strenv(name)].dependencies.common // [] | map("`" + . + "`") | join(", ")' "${MANIFEST}")
  homebrew=$(name="${name}" yq eval '.scripts[strenv(name)].dependencies.homebrew // [] | map("`" + . + "`") | join(", ")' "${MANIFEST}")
  debian=$(name="${name}" yq eval '.scripts[strenv(name)].dependencies.debian // [] | map("`" + . + "`") | join(", ")' "${MANIFEST}")

  # Platform-specific packages only appear in parentheses when there are common ones to lead
  # with: the whole point of the parenthetical is "+ beyond the shared set". A script published
  # to one platform only declares no common deps and has nothing to split, so its single
  # platform's packages are named flat — the _(Linux only)_ annotation carries the platform.
  local deps_list="" platform_note=""
  if [[ -n "${common}" ]]; then
    deps_list="${common}"
    local platform_parts=()
    [[ -n "${homebrew}" ]] && platform_parts+=("${homebrew} macOS")
    [[ -n "${debian}" ]] && platform_parts+=("${debian} Linux")
    (( ${#platform_parts[@]} > 0 )) && platform_note=" (+$(join_by ', ' "${platform_parts[@]}"))"
  elif [[ -n "${homebrew}" || -n "${debian}" ]]; then
    # One-platform script: homebrew-only or debian-only, no platform suffix needed. The two
    # lists cannot both be non-empty without common deps in practice (a script published to
    # both platforms would declare the shared ones under common), but join them on ", " anyway
    # so a future manifest that does declare both without common reads as two lists, not one
    # run-together string.
    deps_list=$(join_by ', ' "${homebrew}" "${debian}")
  fi

  if [[ -z "${deps_list}" && -z "${platform_note}" ]]; then
    return
  fi

  printf 'deps: %s%s' "${deps_list}" "${platform_note}"
}

#######################################
# Writes the index block for a single script to stdout.
# Globals:
#   MANIFEST
# Arguments:
#   name, link_mode, topic, platform_note (true/false).
# Outputs:
#   A level-3 heading, the description paragraph, and the metadata tagline,
#   separated by blank lines.
#######################################
emit_script() {
  local name="$1" link_mode="$2" topic="$3" platform_note="$4"

  local path dir
  path=$(name="${name}" yq eval '.scripts[strenv(name)].path' "${MANIFEST}")
  dir=$(dirname "${path}")

  # The topic is the directory component under scripts/, taken from the same path as the link, so a
  # filtered index and its links cannot describe different places.
  if [[ -n "${topic}" && "${dir}" != "scripts/${topic}/"* ]]; then
    return
  fi

  local description
  description=$(name="${name}" yq eval '.scripts[strenv(name)].description' "${MANIFEST}")
  if [[ -z "${description}" ]]; then
    log_error "Manifest entry '${name}' has an empty description; the index cannot document it."
    exit 1
  fi

  local heading
  case "${link_mode}" in
    repo)    heading="### [\`${name}\`](${dir}/)" ;;
    sibling) heading="### [\`${name}\`](${name}/)" ;;
    *)       heading="### \`${name}\`" ;;
  esac

  # The platform annotation is derived from the manifest's `platforms` rather than written into the
  # text, so it cannot contradict what is published: a script the manifest does not publish to
  # Homebrew is one macOS cannot run, and one it does not publish to Debian is the reverse. A script
  # with no `platforms` key goes everywhere and is annotated on neither side.
  local platform_suffix=""
  if [[ "${platform_note}" == true ]]; then
    local platforms
    platforms=$(name="${name}" yq eval '.scripts[strenv(name)].platforms // [] | join(",")' "${MANIFEST}")
    if [[ -n "${platforms}" ]]; then
      if [[ "${platforms}" != *homebrew* ]]; then
        platform_suffix=" _(Linux only)_"
      elif [[ "${platforms}" != *debian* ]]; then
        platform_suffix=" _(macOS only)_"
      fi
    fi
  fi

  local bash_seg=""
  local min_bash
  min_bash=$(name="${name}" yq eval '.scripts[strenv(name)].min_bash // ""' "${MANIFEST}")
  if [[ -n "${min_bash}" ]]; then
    bash_seg="\`bash ${min_bash}+\`"
  fi

  local deps_seg
  deps_seg=$(deps_segment "${name}")

  # The tagline joins whatever segments exist; a script declaring neither a minimum bash version
  # nor dependencies emits no tagline line at all, rather than a blank one.
  local tagline
  tagline=$(join_by ' · ' "${bash_seg}" "${deps_seg}")
  # The annotation qualifies the segments rather than standing alongside them, so it is appended with
  # a space instead of joined with the separator. When there are no segments it becomes the whole
  # tagline, where that leading space would render as a stray indent, so it is dropped.
  if [[ -n "${tagline}" ]]; then
    tagline+="${platform_suffix}"
  else
    tagline="${platform_suffix# }"
  fi

  # No trailing blank: the separator between blocks is emitted by the caller, so the index
  # file never ends with a blank line that would double up against the one the splicer adds
  # before the END marker.
  echo "${heading}"
  echo ""
  echo "${description}"
  if [[ -n "${tagline}" ]]; then
    echo ""
    echo "${tagline}"
  fi
}

#######################################
# Writes the full index for the manifest to stdout.
# Globals:
#   MANIFEST
# Arguments:
#   topic filter (may be empty), link mode, platform_note (true/false), sort_names (true/false).
# Outputs:
#   The complete index section, one block per script separated by a blank line.
#######################################
build_index() {
  local topic="$1" link_mode="$2" platform_note="$3" sort_names="$4"

  # Each block is captured so the separator can be placed only between blocks that actually
  # print: a script outside the --topic filter emits nothing, and emitting a separator for it
  # would leave blank lines at the start and end of the index.
  local name block first=true
  while IFS= read -r name; do
    block=$(emit_script "${name}" "${link_mode}" "${topic}" "${platform_note}")
    [[ -z "${block}" ]] && continue
    if [[ "${first}" == true ]]; then
      first=false
    else
      echo ""
    fi
    printf '%s\n' "${block}"
  done < <(list_names "${sort_names}")
}

#######################################
# Lists the manifest's script names, in manifest order or alphabetically.
#
# Manifest order is the default because the downstream indexes were grouped by topic that way;
# the documentation indexes ask for alphabetical, which is what a reader scans.
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
# Splices an index between the markers in a README, writing the result to stdout.
# Arguments:
#   readme_file, index_file.
# Outputs:
#   The README with the marked section replaced.
#######################################
splice_section() {
  awk -v tfile="$2" -f "${SCRIPT_DIR}/splice-index.awk" "$1"
}

#######################################
# Regenerates the script index in a README from the manifest.
# Arguments:
#   See show_usage.
#######################################
main() {
  if (( $# < 1 )); then
    log_error "Expected a README file."
    show_usage
    exit 1
  fi

  local readme_file="$1"
  shift

  local topic="" link_mode="none" check_only=false
  local platform_note=false sort_names=false
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
      --platform-note) platform_note=true; shift ;;
      --sort) sort_names=true; shift ;;
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

  local index_file
  index_file=$(mktemp)
  build_index "${topic}" "${link_mode}" "${platform_note}" "${sort_names}" > "${index_file}"

  local rendered
  rendered=$(mktemp)
  splice_section "${readme_file}" "${index_file}" > "${rendered}"

  if [[ "${check_only}" == true ]]; then
    if ! diff -q "${readme_file}" "${rendered}" >/dev/null; then
      log_error "${readme_file} is out of date; run 'make docs'."
      diff "${readme_file}" "${rendered}" >&2 || true
      rm -f "${index_file}" "${rendered}"
      exit 1
    fi
    rm -f "${index_file}" "${rendered}"
    return 0
  fi

  log_info "Updating index in ${readme_file}..."
  mv "${rendered}" "${readme_file}"
  rm -f "${index_file}"
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

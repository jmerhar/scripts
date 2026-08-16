# shellcheck shell=bash
#
# The handful of tools that differ between GNU and BSD userlands.
#
# `stat` is the one that matters: its flags are entirely different on Linux and macOS, and these scripts
# publish to both. The flavour is probed once when this library loads rather than at each call, and the
# accessors are defined to match — which is also what keeps the probe out of the middle of a directory walk.
#
# Sourced at development time and inlined by compile-includes.sh at build time.

# Double-source guard
if [[ "${_PLATFORM_SH_LOADED:-}" == "true" ]]; then
  return 0
fi
_PLATFORM_SH_LOADED="true"

# Probed against a path that always exists, so the answer is about the tool rather than about the argument.
if stat -c '%s' / &> /dev/null; then
  ########################################
  # Prints a file's size in bytes.
  # Arguments:
  #   path: File to measure.
  # Outputs:
  #   The size, or nothing when the file cannot be read.
  # Returns:
  #   Non-zero when stat fails, so a caller can decide whether a vanished file is fatal.
  ########################################
  stat_size() { stat -c '%s' "$1"; }

  ########################################
  # Prints a file's modification time as seconds since the epoch.
  # Arguments:
  #   path: File to inspect.
  ########################################
  stat_mtime() { stat -c '%Y' "$1"; }
else
  stat_size() { stat -f '%z' "$1"; }
  stat_mtime() { stat -f '%m' "$1"; }
fi

########################################
# Prints a file's SHA-256 checksum, without the filename.
#
# Two commands, because Linux has sha256sum and macOS has shasum. Failing rather than printing a placeholder
# when neither exists: a caller comparing checksums needs to know it cannot, and a placeholder would make
# every file look identical.
# Arguments:
#   path: File to hash.
# Outputs:
#   The hex digest.
# Returns:
#   1 when no checksum tool is available.
########################################
file_checksum() {
  if command -v sha256sum &> /dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum &> /dev/null; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    return 1
  fi
}

########################################
# Reports whether a checksum tool is available.
#
# Separate from file_checksum so a script can tell the user once, up front, that checksum comparison is off
# — rather than discovering it per file.
# Returns:
#   0 when a checksum tool exists, 1 otherwise.
########################################
has_checksum_tool() {
  command -v sha256sum &> /dev/null || command -v shasum &> /dev/null
}

#!/usr/bin/env bash
#
# Builds ffmpeg and ffprobe with libfdk-aac and installs them into an install prefix.
#
# Every redistributable ffmpeg — Ubuntu's package and the static builds alike — is GPL, and GPL cannot
# ship libfdk-aac: the Fraunhofer AAC encoder is nonfree. Compiling it in yourself is the only way to
# have it, which is fine for personal use and not redistributable.
#
# The build is lean by design — fdk-aac, x264, x265, mp3lame and opus, nothing else — and it happens
# inside a throwaway container, so the host needs no build dependencies and the resulting binary's glibc
# matches the host it will run on. Each component is built from its latest stable release tag, discovered
# at run time, rather than from a branch head: a tested release, and no drift when master breaks. Every
# tag can be pinned instead, which is what makes a build reproducible.
#
# The codec libraries are built static and linked in, so only system libraries stay dynamic. Two
# workarounds apply only when the container base is old enough to need them, and fall away on their own
# as the host is upgraded: nasm from source when the base's is too old to assemble current ffmpeg
# assembly, and a generated x265.pc when x265's own build does not install one.
#
# The finished binaries go to <prefix>/bin, which precedes /usr/bin on PATH — so they shadow the
# distribution's ffmpeg without replacing it, and removing them reverts to it.
#
# Usage:
#   ./build-ffmpeg-nonfree.sh [OPTIONS]

set -o errexit
set -o nounset
set -o pipefail

# --- Shared Library ---
# shellcheck source=../../lib/cli.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/cli.sh"
# @include ../../lib/cli.sh
# shellcheck source=../../lib/core.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/core.sh"
# @include ../../lib/core.sh
# shellcheck source=../../lib/config.sh
source "$(cd "$(dirname "$0")" && pwd -P)/../../lib/config.sh"
# @include ../../lib/config.sh

# --- Environment seams ---
# Each names something a test must be able to redirect: the two commands that reach the network or the
# daemon, the file the host release is read from, and the directories the build writes to. The defaults
# are the real ones, so nothing here changes how a real run behaves.
: "${DOCKER_BIN:=docker}"
: "${GIT_BIN:=git}"
: "${OS_RELEASE:=/etc/os-release}"
: "${BUILD_DIR:=/var/tmp}"
readonly DOCKER_BIN GIT_BIN OS_RELEASE BUILD_DIR

# --- Global State (option flags) ---
_keep=false
_base_opt=""
_ffmpeg_opt=""
_x264_opt=""
_x265_opt=""
_fdkaac_opt=""
_opus_opt=""

# Resolved settings, filled in by apply_config and the resolvers below.
_dest=""
_cpu_limit="2"
_log_dir="/var/log/build-ffmpeg-nonfree"
_base_image=""
_ffmpeg_tag=""
_x264_ref="stable"
_x265_tag=""
_fdkaac_tag=""
_opus_tag=""

# Versions with no upstream tag to discover: lame has cut no release since 3.100, and the nasm fallback
# is a pin precisely because it is only reached when the container base is too old.
_lame_version="3.100"
_nasm_version="2.16.03"

# The workspace the container writes its output into, remembered so the exit trap can report it.
_workdir=""

########################################
# Prints the script's usage instructions to stdout.
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
# Outputs:
#   Writes usage text to stdout.
########################################
show_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Build ffmpeg and ffprobe with libfdk-aac in a throwaway container and install
them into the install prefix, shadowing the distribution's ffmpeg.

Options:
      --base IMAGE    Container base image (default: ubuntu:<the host's version>).
      --ffmpeg TAG    ffmpeg git tag (default: the latest stable n-tag).
      --x264 REF      x264 branch or tag (default: ${_x264_ref}; x264 cuts no release tags).
      --x265 TAG      x265 tag (default: the latest stable).
      --fdk-aac TAG   fdk-aac tag (default: the latest stable v-tag).
      --opus TAG      opus tag (default: the latest stable v-tag).
  -k, --keep          Keep the build workspace afterwards, for debugging.
  -d, --debug         Enable verbose debug logging.
  -h, --help          Show this help message.

Needs docker and write access to the install prefix. The compile is CPU-heavy —
x265 dominates — and is capped at ${_cpu_limit} cores, so expect 20-30 minutes.

Every run writes a log naming the exact tags it used and a command that
reproduces the build.
EOF
}

########################################
# Parses command-line arguments into global option flags.
# Globals:
#   The _*_opt globals and _keep.
# Arguments:
#   Command-line arguments passed to the script.
########################################
parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)
        require_option_value "$@"
        _base_opt="$2"
        shift 2
        ;;
      --ffmpeg)
        require_option_value "$@"
        _ffmpeg_opt="$2"
        shift 2
        ;;
      --x264)
        require_option_value "$@"
        _x264_opt="$2"
        shift 2
        ;;
      --x265)
        require_option_value "$@"
        _x265_opt="$2"
        shift 2
        ;;
      --fdk-aac)
        require_option_value "$@"
        _fdkaac_opt="$2"
        shift 2
        ;;
      --opus)
        require_option_value "$@"
        _opus_opt="$2"
        shift 2
        ;;
      -k|--keep)
        _keep=true
        shift
        ;;
      -d|--debug)
        enable_debug_mode
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      *)
        die_usage "Unknown option '$1'."
        ;;
    esac
  done
}

########################################
# Resolves the settings that come from either an option or the config file, the option winning.
#
# The install prefix is where the binaries go, and it defaults to the prefix this script is installed
# under so that a packaged copy installs beside itself; a checkout has no prefix, hence /usr/local.
# Globals:
#   DEST, CPU_LIMIT, LOG_DIR, and the tag settings; sets the resolved globals.
# Arguments:
#   None
# Returns:
#   0 when the settings are usable, 1 otherwise.
########################################
apply_config() {
  local prefix
  prefix="$(_get_script_prefix)"
  _dest="${DEST:-${prefix:-/usr/local}/bin}"
  _cpu_limit="${CPU_LIMIT:-${_cpu_limit}}"
  _log_dir="${LOG_DIR:-${_log_dir}}"
  _lame_version="${LAME_VERSION:-${_lame_version}}"
  _nasm_version="${NASM_VERSION:-${_nasm_version}}"

  _base_image="${_base_opt:-${BASE_IMAGE:-}}"
  _ffmpeg_tag="${_ffmpeg_opt:-${FFMPEG_TAG:-}}"
  _x264_ref="${_x264_opt:-${X264_REF:-${_x264_ref}}}"
  _x265_tag="${_x265_opt:-${X265_TAG:-}}"
  _fdkaac_tag="${_fdkaac_opt:-${FDKAAC_TAG:-}}"
  _opus_tag="${_opus_opt:-${OPUS_TAG:-}}"

  if [[ ! "${_cpu_limit}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    log_error "CPU_LIMIT must be a number, got '${_cpu_limit}'."
    return 1
  fi
  if [[ ! -d "${_dest}" ]]; then
    log_error "The install directory '${_dest}' does not exist."
    return 1
  fi
  if [[ ! -w "${_dest}" ]]; then
    log_error "The install directory '${_dest}' is not writable."
    return 1
  fi
}

########################################
# Chooses the log file for this run, falling back to the home directory.
#
# Logging must never be the reason a twenty-minute build does not start, so an unwritable log directory
# is a warning and a different path rather than an error.
# Globals:
#   _log_dir, LOG_FILE, SCRIPT_NAME
# Arguments:
#   None
########################################
setup_log_file() {
  local dir="${_log_dir}"
  if ! { mkdir -p "${dir}" 2>/dev/null && [[ -w "${dir}" ]]; }; then
    dir="${HOME:-/tmp}"
    log_warn "'${_log_dir}' is not writable; logging to ${dir} instead."
  fi
  LOG_FILE="${dir}/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"
}

########################################
# Prints the highest stable tag a remote repository offers.
# Globals:
#   GIT_BIN
# Arguments:
#   url: The repository to ask.
#   pattern: An extended regular expression matching only the tags to consider.
# Outputs:
#   The tag, sorted highest by version.
# Returns:
#   1 when the remote offered no matching tag.
########################################
latest_tag() {
  local url="$1" pattern="$2" tag
  tag="$("${GIT_BIN}" ls-remote --tags --refs "${url}" 2>/dev/null | awk -F/ '{print $NF}' | grep -E "${pattern}" | sort -V | tail -1)"
  [[ -n "${tag}" ]] || return 1
  printf '%s' "${tag}"
}

########################################
# Chooses the container base image: the host's own Ubuntu release, so the binary's glibc matches.
# Globals:
#   OS_RELEASE, _base_image
# Arguments:
#   None
########################################
resolve_base() {
  [[ -n "${_base_image}" ]] && return 0

  local id="" version=""
  if [[ -r "${OS_RELEASE}" ]]; then
    # Read rather than sourced: this file is machine-written, but sourcing it would run whatever it says.
    id="$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' "${OS_RELEASE}")"
    version="$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' "${OS_RELEASE}")"
  fi

  if [[ "${id}" == "ubuntu" && -n "${version}" ]]; then
    _base_image="ubuntu:${version}"
    return 0
  fi

  _base_image="ubuntu:22.04"
  log_warn "The host is not Ubuntu (ID='${id:-unknown}'); building on ${_base_image}. Override with --base."
}

########################################
# Fills in whichever component tags were not pinned, from each project's own releases.
# Globals:
#   The tag globals, GIT_BIN
# Arguments:
#   None
# Returns:
#   0 when every tag is known, 1 when a lookup failed.
########################################
resolve_versions() {
  if ! command -v "${GIT_BIN}" &>/dev/null; then
    log_error "'${GIT_BIN}' is needed to discover the latest tags. Install git, or pin every tag with the options."
    return 1
  fi

  if [[ -z "${_ffmpeg_tag}" ]]; then
    _ffmpeg_tag="$(latest_tag https://git.ffmpeg.org/ffmpeg.git '^n[0-9]+\.[0-9]+(\.[0-9]+)?$')" || true
  fi
  if [[ -z "${_x265_tag}" ]]; then
    _x265_tag="$(latest_tag https://bitbucket.org/multicoreware/x265_git.git '^[0-9]+\.[0-9]+$')" || true
  fi
  if [[ -z "${_fdkaac_tag}" ]]; then
    _fdkaac_tag="$(latest_tag https://github.com/mstorsjo/fdk-aac '^v[0-9]+\.[0-9]+\.[0-9]+$')" || true
  fi
  if [[ -z "${_opus_tag}" ]]; then
    _opus_tag="$(latest_tag https://github.com/xiph/opus.git '^v[0-9]+\.[0-9]+(\.[0-9]+)?$')" || true
  fi

  local -a unresolved=()
  [[ -n "${_ffmpeg_tag}" ]] || unresolved+=(ffmpeg)
  [[ -n "${_x265_tag}" ]] || unresolved+=(x265)
  [[ -n "${_fdkaac_tag}" ]] || unresolved+=(fdk-aac)
  [[ -n "${_opus_tag}" ]] || unresolved+=(opus)

  if (( ${#unresolved[@]} > 0 )); then
    log_error "Could not discover a release tag for: ${unresolved[*]}. Pin them with the options."
    return 1
  fi
}

########################################
# Logs the versions this run will build, and the command that reproduces it exactly.
# Globals:
#   Every version global.
# Arguments:
#   None
########################################
report_versions() {
  log_info "Building with:"
  log_info "    base    : ${_base_image}"
  log_info "    ffmpeg  : ${_ffmpeg_tag}"
  log_info "    x264    : ${_x264_ref}"
  log_info "    x265    : ${_x265_tag}"
  log_info "    fdk-aac : ${_fdkaac_tag}"
  log_info "    opus    : ${_opus_tag}"
  log_info "    lame    : ${_lame_version}, nasm fallback: ${_nasm_version}"
  local reproduce="${SCRIPT_NAME} --base ${_base_image} --ffmpeg ${_ffmpeg_tag} --x264 ${_x264_ref}"
  reproduce+=" --x265 ${_x265_tag} --fdk-aac ${_fdkaac_tag} --opus ${_opus_tag}"
  log_info "Reproduce this exact build with:"
  log_info "    ${reproduce}"
}

########################################
# Writes the script the container runs.
#
# It stays a here-document rather than moving into a file of its own, because it is not this script's
# language: it runs in the container, against the container's tools, and its own steps are the thing the
# quoting must leave alone. Nothing here is expanded by the host — every version arrives in the
# environment, so what is written is exactly what was authored.
# Globals:
#   None
# Arguments:
#   path: Where to write the script.
########################################
write_build_script() {
  cat > "$1" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
: "${FFMPEG_TAG:?} ${X265_TAG:?} ${FDKAAC_TAG:?} ${OPUS_TAG:?} ${X264_REF:?} ${LAME_VER:?} ${NASM_FALLBACK_VER:?}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates git wget xz-utils build-essential cmake pkg-config autoconf automake libtool libnuma-dev nasm yasm

PREFIX=/build/prefix
mkdir -p "$PREFIX/bin" /build/src
export PATH="$PREFIX/bin:$PATH"
cd /build/src

# nasm: the base's is used when it is new enough to assemble current ffmpeg assembly, and the pinned
# fallback is built from source when it is not.
sysnum=$(nasm -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 | awk -F. '{print $1*100+$2}')
if [ "${sysnum:-0}" -ge 215 ]; then
  echo "=== nasm: using the base's $(nasm -v | grep -oE '[0-9.]+' | head -1) ==="
else
  echo "=== nasm $NASM_FALLBACK_VER from source (the base's is too old) ==="
  wget -O nasm.tar.xz "https://www.nasm.us/pub/nasm/releasebuilds/${NASM_FALLBACK_VER}/nasm-${NASM_FALLBACK_VER}.tar.xz"
  tar xf nasm.tar.xz
  ( cd "nasm-${NASM_FALLBACK_VER}" && ./configure && make -j2 && install -m755 nasm ndisasm "$PREFIX/bin/" )
fi
nasm --version

echo "=== x264 ($X264_REF) ==="
git clone --depth 1 --branch "$X264_REF" https://code.videolan.org/videolan/x264.git
( cd x264 && ./configure --prefix="$PREFIX" --enable-static --enable-pic --disable-cli && make -j2 && make install )

echo "=== x265 ($X265_TAG) ==="
git clone --depth 1 --branch "$X265_TAG" https://bitbucket.org/multicoreware/x265_git.git x265
( cd x265/build/linux && cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DENABLE_SHARED=OFF -DENABLE_CLI=OFF ../../source && make -j2 && make install )

# ffmpeg requires x265.pc, which x265's cmake does not always install.
if [ ! -f "$PREFIX/lib/pkgconfig/x265.pc" ]; then
  X265_BUILD=$(awk '/#define X265_BUILD/{print $3}' "$PREFIX/include/x265_config.h")
  mkdir -p "$PREFIX/lib/pkgconfig"
  {
    echo "prefix=$PREFIX"
    echo 'exec_prefix=${prefix}'
    echo 'libdir=${prefix}/lib'
    echo 'includedir=${prefix}/include'
    echo ''
    echo 'Name: x265'
    echo 'Description: H.265/HEVC video encoder'
    echo "Version: ${X265_BUILD:-200}"
    echo 'Libs: -L${libdir} -lx265'
    echo 'Libs.private: -lstdc++ -lm -ldl -lrt -lnuma -lpthread'
    echo 'Cflags: -I${includedir}'
  } > "$PREFIX/lib/pkgconfig/x265.pc"
  echo "  generated x265.pc (Version ${X265_BUILD:-200})"
fi

echo "=== fdk-aac ($FDKAAC_TAG) ==="
git clone --depth 1 --branch "$FDKAAC_TAG" https://github.com/mstorsjo/fdk-aac
( cd fdk-aac && autoreconf -fiv && ./configure --prefix="$PREFIX" --disable-shared && make -j2 && make install )

echo "=== opus ($OPUS_TAG) ==="
git clone --depth 1 --branch "$OPUS_TAG" https://github.com/xiph/opus.git
( cd opus && ./autogen.sh && ./configure --prefix="$PREFIX" --disable-shared && make -j2 && make install )

echo "=== lame $LAME_VER ==="
wget -O lame.tar.gz "https://downloads.sourceforge.net/project/lame/lame/${LAME_VER}/lame-${LAME_VER}.tar.gz"
tar xzf lame.tar.gz
( cd "lame-${LAME_VER}" && ./configure --prefix="$PREFIX" --disable-shared --enable-nasm && make -j2 && make install )

echo "=== ffmpeg ($FFMPEG_TAG) ==="
PKG_CONFIG_PATH="$(find "$PREFIX" -name '*.pc' -printf '%h\n' | sort -u | paste -sd:)"
export PKG_CONFIG_PATH
echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
pkg-config --exists x265 && echo "  pkg-config sees x265 $(pkg-config --modversion x265)" || echo "  WARNING: pkg-config cannot see x265"

git clone --depth 1 --branch "$FFMPEG_TAG" https://git.ffmpeg.org/ffmpeg.git ffmpeg
( cd ffmpeg && ./configure --prefix="$PREFIX" --pkg-config-flags=--static --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" --extra-libs="-lpthread -lm" --enable-gpl --enable-nonfree --enable-libfdk-aac --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus && make -j2 && make install )

cp -v "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe" /work/
chown 1000:1000 /work/ffmpeg /work/ffprobe 2>/dev/null || true
INNER
}

########################################
# Runs the build in a throwaway container, leaving the binaries in the workspace.
# Globals:
#   DOCKER_BIN, _workdir, _base_image, _cpu_limit, and the version globals.
# Arguments:
#   None
# Returns:
#   The container's exit status.
########################################
run_build() {
  local -a command=("${DOCKER_BIN}" run --rm "--cpus=${_cpu_limit}")
  command+=(-e "FFMPEG_TAG=${_ffmpeg_tag}" -e "X265_TAG=${_x265_tag}" -e "FDKAAC_TAG=${_fdkaac_tag}")
  command+=(-e "OPUS_TAG=${_opus_tag}" -e "X264_REF=${_x264_ref}" -e "LAME_VER=${_lame_version}")
  command+=(-e "NASM_FALLBACK_VER=${_nasm_version}")
  command+=(-v "${_workdir}:/work" "${_base_image}" bash /work/build-inside.sh)

  log_info "Compiling in a throwaway ${_base_image} container, capped at ${_cpu_limit} CPUs. This takes 20-30 minutes."
  log_command "${command[@]}"
}

########################################
# Installs one built binary into the install directory.
#
# Written under a temporary name and moved into place, for two reasons: a process running the old binary
# keeps the inode it is executing rather than reading a half-written file, and a destination that is a
# hard link elsewhere is replaced rather than written through.
# Globals:
#   _dest
# Arguments:
#   source: The built binary.
#   name: The name to install it as.
# Returns:
#   Non-zero when the install failed.
########################################
install_binary() {
  local source="$1" name="$2"
  local staged="${_dest}/.${name}.incoming"
  install -m 0755 "${source}" "${staged}" || return 1
  mv "${staged}" "${_dest}/${name}"
}

########################################
# Reports whether the installed ffmpeg actually has the encoder this whole exercise is for.
#
# grep without -q: with pipefail, grep exiting on its first match closes the pipe, and ffmpeg's death by
# SIGPIPE would be read as a failed check.
# Globals:
#   _dest
# Arguments:
#   None
# Returns:
#   0 when libfdk_aac is present, 1 otherwise.
########################################
verify_install() {
  "${_dest}/ffmpeg" -hide_banner -encoders 2>/dev/null | grep libfdk_aac >/dev/null
}

########################################
# Reports the outcome of the run, whatever it was, and where the log is.
# Globals:
#   Every version global, LOG_FILE, _workdir, _keep
# Arguments:
#   status: The exit status being reported.
########################################
report_outcome() {
  local status="$1"
  if (( status == 0 )); then
    log_info "Installed ffmpeg ${_ffmpeg_tag} with libfdk_aac into ${_dest}; the distribution's copy stays as a fallback."
    log_info "Revert with: rm ${_dest}/ffmpeg ${_dest}/ffprobe"
  else
    log_error "Build failed (exit ${status}) with base=${_base_image:-unresolved} ffmpeg=${_ffmpeg_tag:-unresolved} x264=${_x264_ref} x265=${_x265_tag:-unresolved} fdk-aac=${_fdkaac_tag:-unresolved} opus=${_opus_tag:-unresolved}. Nothing was installed."
  fi
  [[ -n "${LOG_FILE:-}" ]] && log_info "Full log: ${LOG_FILE}"
  if [[ -n "${_workdir}" && -d "${_workdir}" ]]; then
    if [[ "${_keep}" == true ]]; then
      log_info "Kept the build workspace at ${_workdir}"
    else
      rm -rf "${_workdir}"
    fi
  fi
}

########################################
# Main entry point.
# Globals:
#   Everything above.
# Arguments:
#   Command-line arguments.
# Returns:
#   0 when the binaries are installed and carry libfdk_aac, 1 otherwise.
########################################
main() {
  parse_options "$@"

  load_optional_config >/dev/null || exit 1
  apply_config || exit 1
  setup_log_file

  # Registered only once the arguments are known to be good, so --help and a rejected option do not
  # report the outcome of a build that never started.
  trap 'report_outcome $?' EXIT

  if ! command -v "${DOCKER_BIN}" &>/dev/null; then
    log_error "'${DOCKER_BIN}' was not found. The build runs in a container, so docker is required."
    exit 1
  fi

  resolve_base
  resolve_versions || exit 1
  report_versions

  _workdir="$(mktemp -d "${BUILD_DIR}/ffmpeg-build.XXXXXX")"
  write_build_script "${_workdir}/build-inside.sh"

  if ! run_build; then
    log_error "The container build did not finish."
    exit 1
  fi

  if [[ ! -x "${_workdir}/ffmpeg" || ! -x "${_workdir}/ffprobe" ]]; then
    log_error "The build produced no ffmpeg and ffprobe in ${_workdir}."
    exit 1
  fi

  log_info "Installing ffmpeg and ffprobe into ${_dest}..."
  if ! install_binary "${_workdir}/ffmpeg" ffmpeg; then
    log_error "Could not install ffmpeg into ${_dest}."
    exit 1
  fi
  if ! install_binary "${_workdir}/ffprobe" ffprobe; then
    log_error "Could not install ffprobe into ${_dest}."
    exit 1
  fi

  if ! verify_install; then
    log_error "The installed ffmpeg has no libfdk_aac encoder, which is the point of building it. Check the configure flags in the log."
    exit 1
  fi
  log_info "libfdk_aac is available. Encode with: ffmpeg -c:a libfdk_aac ..."

  # A shell that has already looked up ffmpeg would otherwise keep running the old one.
  hash -r 2>/dev/null || true
}

# Only run when executed, not when sourced — the test suite sources this file to exercise its
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

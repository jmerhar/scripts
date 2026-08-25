#!/usr/bin/env bats
#
# build-ffmpeg-nonfree runs for half an hour, reaches the network, and installs binaries onto PATH — so
# none of that happens here. The seams take its place: DOCKER_BIN and GIT_BIN are doubles, OS_RELEASE and
# BUILD_DIR are fixtures, and DEST is a directory under the test's own temp dir.
#
# What is worth asserting is everything around the compile, since the compile itself is one command:
# which base and tags a run resolves, that it refuses rather than guesses when a lookup fails, that the
# binaries are staged and moved rather than written over, and that a build which lost libfdk_aac is
# reported as a failure instead of a success.
#
# The doubles are written per test rather than taken from test/stubs, because neither `docker` nor `git`
# can be shadowed on PATH here: the coverage runner drives real docker, and the suites build real git
# fixtures.

load ../test_helper

setup() {
  setup_common
  SCRIPT="$REPO_ROOT/scripts/system/build-ffmpeg-nonfree/build-ffmpeg-nonfree.sh"

  DEST="$BATS_TEST_TMPDIR/bin"
  BUILD_DIR="$BATS_TEST_TMPDIR/build"
  LOGS="$BATS_TEST_TMPDIR/logs"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$DEST" "$BUILD_DIR" "$LOGS"
  : > "$CALLS"

  CONFIG_FILE="$BATS_TEST_TMPDIR/build.conf"
  export CONFIG_FILE
  printf 'DEST="%s"\nLOG_DIR="%s"\n' "$DEST" "$LOGS" > "$CONFIG_FILE"

  export BUILD_DIR
  export OS_RELEASE="$BATS_TEST_TMPDIR/os-release"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$OS_RELEASE"

  DOCKER_BIN="$BATS_TEST_TMPDIR/docker-double"
  GIT_BIN="$BATS_TEST_TMPDIR/git-double"
  export DOCKER_BIN GIT_BIN
  docker_double_succeeds
  git_double_answers
}

########################################
# Writes a docker double that records its call and produces the two binaries the build should leave in
# the mounted workspace. The binaries are scripts that answer the encoder query, which is what the
# verification step reads.
# Arguments:
#   encoders: Optional text the fake ffmpeg prints for -encoders, defaulting to one naming libfdk_aac.
########################################
docker_double_succeeds() {
  local encoders="${1:-" V..... libfdk_aac           Fraunhofer AAC"}"
  cat > "$DOCKER_BIN" <<EOF
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >> "$CALLS"
# The workspace is the host side of the -v argument, which is where the build leaves its output.
work=""
prev=""
for arg in "\$@"; do
  if [[ "\${prev}" == "-v" ]]; then work="\${arg%%:*}"; fi
  prev="\${arg}"
done
[[ -n "\${work}" ]] || exit 0
for name in ffmpeg ffprobe; do
  printf '#!/usr/bin/env bash\nprintf "%s\\\\n"\n' '${encoders}' > "\${work}/\${name}"
  chmod +x "\${work}/\${name}"
done
EOF
  chmod +x "$DOCKER_BIN"
}

########################################
# Writes a docker double that fails without producing anything.
########################################
docker_double_fails() {
  cat > "$DOCKER_BIN" <<EOF
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >> "$CALLS"
exit 1
EOF
  chmod +x "$DOCKER_BIN"
}

########################################
# Writes a git double answering ls-remote with each project's own tag shapes.
#
# Per repository rather than one list for all four, because the projects number their releases
# differently and a shared list hides exactly the mistake worth catching: opus and fdk-aac both use
# v-tags, so a lookup that ignored the URL would hand opus fdk-aac's version and look correct.
# Arguments:
#   Tags to offer for every repository, overriding the per-project lists.
########################################
git_double_answers() {
  local -a override=("$@")
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "git %%s\\n" "$*" >> "%s"\n' "$CALLS"
    printf '[[ "$1" == "ls-remote" ]] || exit 0\n'
    printf 'url="${*: -1}"\n'
    if (( ${#override[@]} > 0 )); then
      printf 'tags="%s"\n' "${override[*]}"
    else
      printf 'case "${url}" in\n'
      printf '  *ffmpeg*)  tags="n6.1.1 n7.0 n7.1" ;;\n'
      printf '  *x265*)    tags="3.6 4.0 4.1" ;;\n'
      printf '  *fdk-aac*) tags="v2.0.2 v2.0.3" ;;\n'
      printf '  *opus*)    tags="v1.5.1 v1.5.2" ;;\n'
      printf '  *)         tags="" ;;\n'
      printf 'esac\n'
    fi
    printf 'for tag in ${tags}; do printf "deadbeef\\trefs/tags/%%s\\n" "${tag}"; done\n'
  } > "$GIT_BIN"
  chmod +x "$GIT_BIN"
}

########################################
# Writes a git double that offers no tags at all.
########################################
git_double_silent() {
  cat > "$GIT_BIN" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >> "$CALLS"
exit 0
EOF
  chmod +x "$GIT_BIN"
}

# --- Resolving what to build --------------------------------------------------------------------

@test "the container base matches the host's Ubuntu release" {
  run_snippet "$SCRIPT" 'resolve_base; printf "%s" "$_base_image"'
  [ "$status" -eq 0 ]
  [ "$output" = "ubuntu:24.04" ]
}

@test "a non-Ubuntu host is warned about and given a known base" {
  printf 'ID=debian\nVERSION_ID="12"\n' > "$OS_RELEASE"
  run_snippet "$SCRIPT" 'resolve_base; printf "%s" "$_base_image"'
  [[ "$output" == *"The host is not Ubuntu"* ]]
  [[ "$output" == *"ubuntu:22.04"* ]]
}

# os-release is machine-written, but sourcing it would run whatever it contains.
@test "the host release file is read, not executed" {
  printf 'ID=ubuntu\nVERSION_ID="24.04"\ntouch %s/sourced\n' "$BATS_TEST_TMPDIR" > "$OS_RELEASE"
  run_snippet "$SCRIPT" 'resolve_base; printf "%s" "$_base_image"'
  [ "$output" = "ubuntu:24.04" ]
  [ ! -e "$BATS_TEST_TMPDIR/sourced" ]
}

@test "an explicit base is left alone" {
  run_snippet "$SCRIPT" '_base_image="ubuntu:20.04"; resolve_base; printf "%s" "$_base_image"'
  [ "$output" = "ubuntu:20.04" ]
}

@test "the highest stable tag is chosen, not the newest ref" {
  git_double_answers n7.1 n6.1.1 n7.0
  run_snippet "$SCRIPT" 'latest_tag https://example.invalid/repo "^n[0-9]+\.[0-9]+(\.[0-9]+)?$"'
  [ "$status" -eq 0 ]
  [ "$output" = "n7.1" ]
}

@test "tags that do not match the stable pattern are ignored" {
  git_double_answers n7.1 n8.0-rc1 n7.2
  run_snippet "$SCRIPT" 'latest_tag https://example.invalid/repo "^n[0-9]+\.[0-9]+(\.[0-9]+)?$"'
  [ "$output" = "n7.2" ]
}

@test "every unpinned component gets a tag" {
  run_snippet "$SCRIPT" 'resolve_versions; printf "%s|%s|%s|%s" "$_ffmpeg_tag" "$_x265_tag" "$_fdkaac_tag" "$_opus_tag"'
  [ "$status" -eq 0 ]
  [ "$output" = "n7.1|4.1|v2.0.3|v1.5.2" ]
}

@test "a pinned tag is not looked up" {
  run_snippet "$SCRIPT" '_ffmpeg_tag=n6.0; resolve_versions >/dev/null; printf "%s" "$_ffmpeg_tag"'
  [ "$output" = "n6.0" ]
}

# Guessing here would build something other than what the run reports building.
@test "a lookup that finds nothing is refused, naming the components" {
  git_double_silent
  run_snippet "$SCRIPT" 'resolve_versions'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not discover a release tag for: ffmpeg x265 fdk-aac opus"* ]]
  [[ "$output" == *"Pin them with the options."* ]]
}

@test "a missing git is refused with a way forward" {
  GIT_BIN="$BATS_TEST_TMPDIR/not-installed" run_snippet "$SCRIPT" 'resolve_versions'
  [ "$status" -eq 1 ]
  [[ "$output" == *"is needed to discover the latest tags"* ]]
}

@test "the run reports the command that reproduces it" {
  run_snippet "$SCRIPT" '_base_image=ubuntu:24.04; _ffmpeg_tag=n7.1; _x265_tag=4.1; _fdkaac_tag=v2.0.3; _opus_tag=v1.5.2; report_versions'
  [[ "$output" == *"--base ubuntu:24.04 --ffmpeg n7.1 --x264 stable --x265 4.1 --fdk-aac v2.0.3 --opus v1.5.2"* ]]
}

# --- The build and the install ------------------------------------------------------------------

@test "a whole run installs both binaries and verifies the encoder" {
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -x "$DEST/ffmpeg" ]
  [ -x "$DEST/ffprobe" ]
  [[ "$output" == *"libfdk_aac is available"* ]]
}

@test "the container is capped and given every version in its environment" {
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" 'docker run --rm --cpus=2'
  stub_called_in "$CALLS" 'FFMPEG_TAG=n7.1'
  stub_called_in "$CALLS" 'X265_TAG=4.1'
  stub_called_in "$CALLS" 'FDKAAC_TAG=v2.0.3'
  stub_called_in "$CALLS" 'OPUS_TAG=v1.5.2'
  stub_called_in "$CALLS" 'X264_REF=stable'
}

@test "the configured CPU cap reaches docker" {
  printf 'DEST="%s"\nLOG_DIR="%s"\nCPU_LIMIT="4"\n' "$DEST" "$LOGS" > "$CONFIG_FILE"
  run_script "$SCRIPT"
  stub_called_in "$CALLS" 'docker run --rm --cpus=4'
}

@test "the build script the container runs is written into the workspace" {
  run_script "$SCRIPT" --keep
  [ "$status" -eq 0 ]
  run bash -c "cat '$BUILD_DIR'/ffmpeg-build.*/build-inside.sh"
  [[ "$output" == *"--enable-libfdk-aac"* ]]
  [[ "$output" == *"--enable-nonfree"* ]]
}

# The versions must arrive in the environment, never expanded into the script the container runs.
@test "the build script carries no host-side expansion" {
  run_script "$SCRIPT" --keep
  run bash -c "grep -c 'FFMPEG_TAG:?' '$BUILD_DIR'/ffmpeg-build.*/build-inside.sh"
  [ "$output" = "1" ]
  run bash -c "grep -c 'n7.1' '$BUILD_DIR'/ffmpeg-build.*/build-inside.sh || true"
  [ "$output" = "0" ]
}

@test "a failing container installs nothing" {
  docker_double_fails
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -e "$DEST/ffmpeg" ]
  [[ "$output" == *"Nothing was installed."* ]]
}

@test "a container that produced no binaries is refused" {
  cat > "$DOCKER_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$DOCKER_BIN"
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"produced no ffmpeg and ffprobe"* ]]
  [ ! -e "$DEST/ffmpeg" ]
}

# The entire point of the exercise is that one encoder, so a build that lost it is a failure.
@test "a build without libfdk_aac is a failure, not a quiet success" {
  docker_double_succeeds " V..... aac                  AAC (Advanced Audio Coding)"
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no libfdk_aac encoder"* ]]
}

# A running process keeps the inode it is executing, and a destination that is a hard link elsewhere is
# replaced rather than written through. See CLAUDE.md, "Replacing a file someone else is seeding".
@test "an existing binary is replaced rather than written through" {
  printf '#!/usr/bin/env bash\nprintf "old\\n"\n' > "$DEST/ffmpeg"
  chmod +x "$DEST/ffmpeg"
  ln "$DEST/ffmpeg" "$BATS_TEST_TMPDIR/other-name"
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/other-name"
  [[ "$output" == *"old"* ]]
  [ ! "$DEST/ffmpeg" -ef "$BATS_TEST_TMPDIR/other-name" ]
}

@test "no staging file is left in the install directory" {
  run_script "$SCRIPT"
  run bash -c "find '$DEST' -name '.*incoming' | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "the workspace is removed unless keeping it was asked for" {
  run_script "$SCRIPT"
  run bash -c "find '$BUILD_DIR' -maxdepth 1 -name 'ffmpeg-build.*' | wc -l | tr -d ' '"
  [ "$output" = "0" ]

  run_script "$SCRIPT" --keep
  run bash -c "find '$BUILD_DIR' -maxdepth 1 -name 'ffmpeg-build.*' | wc -l | tr -d ' '"
  [ "$output" = "1" ]
}

@test "an install directory that cannot be written to is refused before anything runs" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores the write bit"
  fi
  chmod a-w "$DEST"
  run_script "$SCRIPT"
  chmod u+w "$DEST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not writable"* ]]
  run bash -c "grep -c docker '$CALLS' || true"
  [ "$output" = "0" ]
}

@test "an install directory that does not exist is refused" {
  printf 'DEST="%s"\nLOG_DIR="%s"\n' "$BATS_TEST_TMPDIR/absent" "$LOGS" > "$CONFIG_FILE"
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "a missing docker is refused" {
  DOCKER_BIN="$BATS_TEST_TMPDIR/not-installed" run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"The build runs in a container"* ]]
}

@test "a CPU cap that is not a number is refused" {
  printf 'DEST="%s"\nCPU_LIMIT="lots"\n' "$DEST" > "$CONFIG_FILE"
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CPU_LIMIT must be a number"* ]]
}

# --- Logging ------------------------------------------------------------------------------------

@test "a run writes a log naming the versions and the outcome" {
  run_script "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c "cat '$LOGS'/build-ffmpeg-nonfree-*.log"
  [[ "$output" == *"ffmpeg  : n7.1"* ]]
  [[ "$output" == *"Installed ffmpeg n7.1"* ]]
}

@test "a failed run records the failure and the versions it tried" {
  docker_double_fails
  run_script "$SCRIPT"
  [ "$status" -eq 1 ]
  run bash -c "cat '$LOGS'/build-ffmpeg-nonfree-*.log"
  [[ "$output" == *"Build failed"* ]]
  [[ "$output" == *"ffmpeg=n7.1"* ]]
}

@test "an unwritable log directory is a warning, not a stop" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores the write bit"
  fi
  chmod a-w "$LOGS"
  run_script "$SCRIPT"
  chmod u+w "$LOGS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not writable; logging to"* ]]
}

# --- Options ------------------------------------------------------------------------------------

@test "the pinning options are recorded as parse_options sees them" {
  run_snippet "$SCRIPT" 'parse_options --base b --ffmpeg f --x264 a --x265 c --fdk-aac d --opus o --keep; printf "%s|%s|%s|%s|%s|%s|%s" "$_base_opt" "$_ffmpeg_opt" "$_x264_opt" "$_x265_opt" "$_fdkaac_opt" "$_opus_opt" "$_keep"'
  [ "$output" = "b|f|a|c|d|o|true" ]
}

@test "an unknown option is refused" {
  run_script "$SCRIPT" --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option '--nonsense'."* ]]
}

@test "an option missing its argument is refused" {
  run_script "$SCRIPT" --ffmpeg
  [ "$status" -eq 1 ]
  [[ "$output" == *"Option '--ffmpeg' requires an argument."* ]]
}

# --help must not report the outcome of a build that never ran.
@test "help prints the usage and reports no build" {
  run_script "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: build-ffmpeg-nonfree"* ]]
  [[ "$output" != *"Build failed"* ]]
}

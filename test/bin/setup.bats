#!/usr/bin/env bats
#
# setup.sh installs bats from source and yq from a release in the kcov container. It is short but every
# line is a version or a URL that has to be right, and a mistake in one surfaces as a CI job that fails
# several minutes in with wget saying nothing useful.
#
# wget, tar and dpkg are faked per test rather than added to test/stubs: a `tar` shadowing the real one for
# every suite would break the packaging tests, which build and read back genuine tarballs. The fakes go
# behind the shared stub directory on PATH, so what setup_common guarantees still holds — the shared stubs
# shadow everything, and these only catch what falls through.

load ../test_helper

setup() {
  setup_common
  TOOL="$REPO_ROOT/bin/coverage/setup.sh"

  # Every path the script writes to is redirected into the test's own directory. Without this the real
  # steps install into /usr/local and extract into /tmp — which one run of an earlier version of this
  # suite actually did, leaving an empty executable named yq on the developer's PATH.
  export TMP="$BATS_TEST_TMPDIR/tmp"
  export PREFIX="$BATS_TEST_TMPDIR/prefix"
  mkdir -p "$TMP" "$PREFIX/bin"

  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"

  FAKES="$BATS_TEST_TMPDIR/fakes"
  mkdir -p "$FAKES"
  cat > "$FAKES/dpkg" <<STUB
#!/usr/bin/env bash
printf 'dpkg %s\n' "\$*" >> "${CALLS}"
echo amd64
STUB
  chmod +x "$FAKES/dpkg"
  # wget creates the file it is told to write, and the script chmods it straight afterwards — so a fake
  # that only recorded the call would fail the step for the wrong reason. It refuses to write anywhere but
  # the test directory, which is what keeps a misread argument from landing in /usr/local again.
  cat > "$FAKES/wget" <<STUB
#!/usr/bin/env bash
printf 'wget %s\n' "\$*" >> "${CALLS}"
target=""
prev=""
for arg in "\$@"; do
  [[ "\${prev}" == "-qO" || "\${prev}" == "-O" ]] && target="\${arg}"
  prev="\${arg}"
done
if [[ -n "\${target}" && "\${target}" == "${BATS_TEST_TMPDIR}"/* ]]; then
  mkdir -p "\$(dirname "\${target}")"
  : > "\${target}"
fi
exit 0
STUB
  chmod +x "$FAKES/wget"

  # tar is faked, so nothing is really unpacked — but install_bats then runs the installer the archive
  # would have contained, so the fake has to leave one behind.
  cat > "$FAKES/tar" <<STUB
#!/usr/bin/env bash
printf 'tar %s\n' "\$*" >> "${CALLS}"
mkdir -p "${BATS_TEST_TMPDIR}/tmp/bats-core-1.14.0"
printf '#!/usr/bin/env bash\nexit 0\n' > "${BATS_TEST_TMPDIR}/tmp/bats-core-1.14.0/install.sh"
chmod +x "${BATS_TEST_TMPDIR}/tmp/bats-core-1.14.0/install.sh"
exit 0
STUB
  chmod +x "$FAKES/tar"
  # Shared stubs stay first, as setup_common requires; the fakes sit behind them.
  export PATH="$TEST_DIR/stubs:$FAKES:$PATH"

  export BATS_VERSION=v1.14.0
  export YQ_VERSION=v4.52.4
}

@test "fetches bats at the pinned tag, not the distribution package" {
  # Debian ships 1.8, which predates BATS_TEST_TIMEOUT — so a suite bounding a runaway loop would silently
  # have no bound in the container while having one locally.
  run_func "$TOOL" install_bats
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" 'wget .*bats-core/archive/refs/tags/v1\.14\.0\.tar\.gz'
  stub_called_in "$CALLS" 'tar -xzf .*/bats\.tar\.gz'
}

@test "a bats version without its v still fetches the tag" {
  # bats exports BATS_VERSION itself, without the prefix the release tags carry, so inside a suite the
  # variable arrives as 1.14.0 and an unnormalised URL would be a 404.
  BATS_VERSION=1.14.0 run_func "$TOOL" install_bats
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" 'wget .*refs/tags/v1\.14\.0\.tar\.gz'
}

@test "nothing is written outside the test directory" {
  # The guard against the accident that prompted these seams: an empty executable named yq on the
  # developer's PATH, left by a run that used the real /usr/local.
  run_func "$TOOL" install_yq
  [ "$status" -eq 0 ]
  [ ! -e /usr/local/bin/yq ] || [ -s /usr/local/bin/yq ]
  stub_called_in "$CALLS" "wget -qO ${PREFIX}/bin/yq"
}

@test "fetches mikefarah's yq at the pinned version" {
  # The distribution package named yq is the Python jq wrapper, which does not speak the v4 expressions
  # the packaging scripts use.
  run_func "$TOOL" install_yq
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" 'wget .*mikefarah/yq/releases/download/v4\.52\.4/yq_linux_amd64'
  [ -x "$PREFIX/bin/yq" ]
}

@test "sourcing the script installs nothing" {
  # run_func sources it to reach one function; unguarded, that would install into whatever machine the
  # suite is running on.
  run_func "$TOOL" true
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

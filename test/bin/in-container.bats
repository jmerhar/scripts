#!/usr/bin/env bats
#
# in-container.sh provisions the kcov container: packages, bats from source, yq from a release. It is
# short but every line is a version or a URL that has to be right, and a mistake in one surfaces as a CI
# job that fails several minutes in with wget saying nothing useful — the BATS_VERSION prefix collision
# that this suite's sibling caught being exactly that shape.
#
# apt-get, wget, tar and dpkg are faked per test rather than added to test/stubs: a `tar` shadowing the
# real one for every suite would break the packaging tests, which build and read back genuine tarballs.
# The fakes go behind the shared stub directory on PATH, so what setup_common guarantees still holds — the
# shared stubs shadow everything, and these only catch what falls through.
#
# bats cannot be faked that way at all: a stub under that name would be picked up by the coverage harness
# tracing these tests, so it comes through the BATS_BIN seam. SRC points the run at a scratch directory
# rather than the mount.

load ../test_helper

setup() {
  setup_common
  TOOL="$REPO_ROOT/bin/coverage/in-container.sh"

  SRC_DIR="$BATS_TEST_TMPDIR/src"
  mkdir -p "$SRC_DIR/test" "$SRC_DIR/coverage"
  export SRC="$SRC_DIR"
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
  local tool
  for tool in apt-get dpkg; do
    cat > "$FAKES/$tool" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "${CALLS}"
exit 0
STUB
    chmod +x "$FAKES/$tool"
  done
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
  export BATS_BIN="$BATS_TEST_TMPDIR/bats-double"
  cat > "$BATS_BIN" <<STUB
#!/usr/bin/env bash
printf 'bats-double %s\n' "\$*" >> "${CALLS}"
printf 'COVERAGE_DIR=%s\n' "\${COVERAGE_DIR:-unset}" >> "${CALLS}"
exit 0
STUB
  chmod +x "$BATS_BIN"

  export BATS_VERSION=v1.14.0
  export YQ_VERSION=v4.52.4
}

# --- Provisioning ------------------------------------------------------------------------------

@test "installs the tools the suites shell out to" {
  # A suite covering a script that needs one of these otherwise fails for want of the tool rather than for
  # a fault in the code, which is a long way to travel for a wrong answer.
  run_func "$TOOL" install_packages
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" 'apt-get update'
  stub_called_in "$CALLS" 'apt-get install .*libxml2-utils'
  stub_called_in "$CALLS" 'apt-get install .*procps'
  stub_called_in "$CALLS" 'apt-get install .*git'
}

@test "fetches bats at the pinned tag, not the distribution package" {
  # Debian ships 1.8, which predates BATS_TEST_TIMEOUT — so a suite bounding a runaway loop would silently
  # have no bound in the container while having one locally.
  run_func "$TOOL" install_bats
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" 'wget .*bats-core/archive/refs/tags/v1\.14\.0\.tar\.gz'
  stub_called_in "$CALLS" 'tar -xzf .*/bats\.tar\.gz'
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
  stub_called_in "$CALLS" 'wget .*mikefarah/yq/releases/download/v4\.52\.4/yq_linux_'
}

# --- Running the suite -------------------------------------------------------------------------

@test "runs the suite with COVERAGE_DIR pointing into the mount" {
  # Without it the test helper does not wrap anything in kcov, and the run produces a green suite and no
  # measurement at all.
  run_func "$TOOL" run_suite
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" "^bats-double --recursive test/$"
  stub_called_in "$CALLS" "^COVERAGE_DIR=${SRC_DIR}/coverage$"
}

@test "no JUNIT_DIR means no report flags" {
  run_func "$TOOL" run_suite
  [ "$status" -eq 0 ]
  ! stub_called_in "$CALLS" 'report-formatter'
}

@test "a JUNIT_DIR is joined onto the mount and passed to bats" {
  mkdir -p "$SRC_DIR/junit"
  JUNIT_DIR=junit run_func "$TOOL" run_suite
  [ "$status" -eq 0 ]
  stub_called_in "$CALLS" "report-formatter junit --output ${SRC_DIR}/junit"
}

@test "what the container wrote is left readable outside it" {
  # The container runs as root, so without this the host user and the CI steps that publish the report
  # cannot read what it produced.
  chmod 700 "$SRC_DIR/coverage"
  run_func "$TOOL" run_suite
  [ "$status" -eq 0 ]
  [[ "$(stat -f '%Lp' "$SRC_DIR/coverage" 2>/dev/null || stat -c '%a' "$SRC_DIR/coverage")" == *"5" ]]
}

@test "sourcing the script provisions nothing" {
  # run_func sources it to reach one function; unguarded, that would apt-get its way through whatever
  # machine the suite is running on.
  run_func "$TOOL" true
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

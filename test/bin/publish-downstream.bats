#!/usr/bin/env bats
#
# publish-downstream.sh pushes packaged artefacts into the tap and the APT repository. It was 49 lines
# spread over two workflow `run:` blocks, so the retry loop — the part that copes with parallel releases
# pushing to the same repository — could only be exercised by cutting several releases at once.
#
# git is real here, against a local bare repository standing in for the remote. Stubbing it would leave the
# thing under test unexercised: what matters is that a fetch-reset really discards a failed local commit,
# that "nothing to commit" really stops early, and that a rejected push really leads to another attempt.
# apt-ftparchive and gpg are stubbed, since neither decides anything this suite asserts.

load ../test_helper

setup() {
  setup_common
  fake_repo_tool publish-downstream.sh
  TOOL="$FAKE_TOOL"

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  CHECKOUT="$BATS_TEST_TMPDIR/downstream"
  git init --quiet --bare "$REMOTE"
  # The bare repository's HEAD follows init.defaultBranch, which is `main` on some machines and `master` on
  # others — including the CI runners. Pointed at main explicitly so that reading its log below resolves to
  # the branch the publisher pushes, rather than to a branch that does not exist.
  git -C "$REMOTE" symbolic-ref HEAD refs/heads/main

  git clone --quiet "$REMOTE" "$CHECKOUT" 2>/dev/null
  git_fixture_init "$CHECKOUT"
  mkdir -p "$CHECKOUT/Formula" "$CHECKOUT/pool/main" "$CHECKOUT/dists/stable/main/binary-all"
  printf '# Downstream\n\n<!-- BEGIN TABLE -->\n<!-- END TABLE -->\n' > "$CHECKOUT/README.md"
  printf 'APT::FTPArchive::Release::Origin "test";\n' > "$CHECKOUT/apt-ftparchive.conf"
  git -C "$CHECKOUT" add -A
  git -C "$CHECKOUT" commit --quiet -m "initial"
  git -C "$CHECKOUT" branch -M main
  git -C "$CHECKOUT" push --quiet -u origin main 2>/dev/null

  # The generator the publisher runs reads the fake repository's manifest.
  cat > "$FAKE_REPO/scripts.yaml" <<'EOF'
scripts:
  alpha-tool:
    path: scripts/utility/alpha-tool/alpha-tool.sh
    description: "A tool."
EOF
}

########################################
# Creates a packaged artefact in the fake repository's dist directory.
# Arguments:
#   channel: homebrew or debian.
#   name: File name to create.
########################################
make_artefact() {
  mkdir -p "$FAKE_REPO/dist/$1"
  printf 'artefact\n' > "$FAKE_REPO/dist/$1/$2"
}

########################################
# Runs the publisher against the fixture checkout.
########################################
publish_run() {
  local channel="$1"
  shift
  run_script "$TOOL" "$channel" "$CHECKOUT" "a commit message" --attempts 3 "$@"
}

# --- Homebrew ----------------------------------------------------------------------------------

@test "a formula is copied in and committed" {
  make_artefact homebrew alpha-tool.rb
  publish_run homebrew
  [ "$status" -eq 0 ]
  [ -f "$CHECKOUT/Formula/alpha-tool.rb" ]
  run git -C "$CHECKOUT" log -1 --format=%s
  [ "$output" = "a commit message" ]
}

@test "the commit reaches the remote" {
  make_artefact homebrew alpha-tool.rb
  publish_run homebrew
  [ "$status" -eq 0 ]
  run git -C "$REMOTE" log -1 --format=%s
  [ "$output" = "a commit message" ]
}

@test "the index is regenerated from the manifest" {
  make_artefact homebrew alpha-tool.rb
  publish_run homebrew
  run cat "$CHECKOUT/README.md"
  [[ "$output" == *"alpha-tool"* ]]
  [[ "$output" == *"A tool."* ]]
}

# A Debian-only release produces no formula. Skipping the copy rather than failing is what lets one
# release publish to one channel only.
@test "no formula to copy is not an error" {
  publish_run homebrew
  [ "$status" -eq 0 ]
  [[ "$output" == *"No formulas to copy"* ]]
}

@test "artefacts are copied, not moved, so a retry still has them" {
  make_artefact homebrew alpha-tool.rb
  publish_run homebrew
  [ -f "$FAKE_REPO/dist/homebrew/alpha-tool.rb" ]
}

# --- APT ---------------------------------------------------------------------------------------

@test "a deb is copied into the pool and the index is rebuilt and signed" {
  make_artefact debian alpha-tool.deb
  printf 'Package: alpha-tool\n' > "$STUB_FIXTURES/apt-ftparchive.stdout"
  publish_run apt
  [ "$status" -eq 0 ]
  [ -f "$CHECKOUT/pool/main/alpha-tool.deb" ]
  stub_called 'apt-ftparchive packages pool/'
  stub_called 'apt-ftparchive -c apt-ftparchive.conf release dists/stable/'
  stub_called 'gpg .*--clearsign -o dists/stable/InRelease dists/stable/Release'
}

@test "the signing key is imported once, before the loop" {
  make_artefact debian alpha-tool.deb
  printf 'Package: alpha-tool\n' > "$STUB_FIXTURES/apt-ftparchive.stdout"
  GPG_PRIVATE_KEY="KEYDATA" GPG_PASSPHRASE="pw" publish_run apt
  [ "$status" -eq 0 ]
  run bash -c "grep -c 'gpg --batch --import' '$STUB_CALLS' || true"
  [ "$output" = "1" ]
}

# An empty Release file makes apt clients reject the whole repository, and signing one would publish that
# rejection. Better to fail the run.
@test "an empty Release file stops the run before signing" {
  make_artefact debian alpha-tool.deb
  : > "$STUB_FIXTURES/apt-ftparchive.stdout"
  publish_run apt
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to generate a valid Release file"* ]]
  run bash -c "grep -c 'clearsign' '$STUB_CALLS' || true"
  [ "$output" = "0" ]
}

@test "no deb to copy is not an error" {
  printf 'Package: none\n' > "$STUB_FIXTURES/apt-ftparchive.stdout"
  publish_run apt
  [ "$status" -eq 0 ]
  [[ "$output" == *"No .deb packages to copy"* ]]
}

# --- The retry loop ----------------------------------------------------------------------------

# An identical rebuild changes nothing, and committing nothing is an error in git. Stopping early is the
# difference between a green run and a failed one.
@test "nothing to commit stops early and succeeds" {
  # The first run fills in the index, so it has something to commit; the second is the identical rebuild.
  publish_run homebrew
  [ "$status" -eq 0 ]
  publish_run homebrew
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to commit"* ]]
  [[ "$output" != *"Attempt 2"* ]]
}

# The case the loop exists for: another run pushed first, so this push is rejected. The next attempt
# fetches, resets — discarding the local commit — and regenerates from the remote's new state.
@test "a rejected push leads to another attempt against the new remote state" {
  make_artefact homebrew alpha-tool.rb

  # A second clone commits and pushes, so the first checkout's push will be rejected.
  local other="$BATS_TEST_TMPDIR/other"
  git clone --quiet "$REMOTE" "$other" 2>/dev/null
  git_fixture_init "$other"
  printf 'from elsewhere\n' > "$other/OTHER.md"
  git -C "$other" add -A
  git -C "$other" commit --quiet -m "someone else"
  git -C "$other" push --quiet 2>/dev/null

  # The checkout is behind, so its first push is rejected and the retry has to recover.
  publish_run homebrew
  [ "$status" -eq 0 ]
  [[ "$output" == *"Attempt 1"* ]]
  # The other commit survived, which is what proves the reset started from the remote rather than
  # clobbering it.
  run git -C "$REMOTE" log --format=%s
  [[ "$output" == *"someone else"* ]]
  [[ "$output" == *"a commit message"* ]]
}

# A permanently unreachable remote should exhaust the attempts and say so, rather than fail on the first
# raw git error — which is what tells the difference between "the remote moved" and "the remote is gone".
@test "giving up after the attempts run out is an error" {
  make_artefact homebrew alpha-tool.rb
  git -C "$CHECKOUT" remote set-url origin "$BATS_TEST_TMPDIR/not-a-repo"
  publish_run homebrew
  [ "$status" -ne 0 ]
  [[ "$output" == *"Gave up after 3 attempts"* ]]
  [[ "$output" == *"Fetch failed (attempt 3/3)"* ]]
}

@test "--dry-run commits but does not push" {
  make_artefact homebrew alpha-tool.rb
  publish_run homebrew --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"not pushing"* ]]
  run git -C "$CHECKOUT" log -1 --format=%s
  [ "$output" = "a commit message" ]
  run git -C "$REMOTE" log -1 --format=%s
  [ "$output" = "initial" ]
}

# --- Arguments -------------------------------------------------------------------------------

@test "an unknown channel is refused" {
  run_script "$TOOL" snap "$CHECKOUT" "msg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown channel 'snap'"* ]]
}

@test "a checkout directory that does not exist is refused" {
  run_script "$TOOL" homebrew "$BATS_TEST_TMPDIR/absent" "msg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checkout directory not found"* ]]
}

@test "too few arguments are refused with the usage" {
  run_script "$TOOL" homebrew
  [ "$status" -ne 0 ]
  [[ "$output" == *"Expected a channel"* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "a non-numeric attempt count is refused" {
  run_script "$TOOL" homebrew "$CHECKOUT" "msg" --attempts many
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "shows usage on request" {
  run_script "$TOOL" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: publish-downstream.sh"* ]]
}

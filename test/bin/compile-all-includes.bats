#!/usr/bin/env bats
#
# The walk that compiles every publishable script before packaging. It used to be inline shell in two
# workflows, where the only way to exercise it was to push; the point of it being a script is that a
# mistake in the walk — skipping a script, descending into the library, tripping over a path with a space —
# fails here instead.
#
# It writes to an output directory and never touches the sources, which is what lets the same command run
# in a working tree, in the lint workflow and in the release workflow. The property most worth pinning is
# that last one: a walk that rewrote the tree would be unusable in development, and a walk that quietly
# skipped a script would publish the development form.

load ../test_helper

setup() {
  setup_common
  # fake_repo_tool mirrors the real bin/, so the compiler this walk shells out to is already beside it.
  fake_repo_tool compile-all-includes.sh
  TREE="$FAKE_REPO/scripts"
  OUT="$FAKE_REPO/dist/compiled"
  mkdir -p "$TREE/lib"
  printf 'shared_fn() { echo shared; }\n' > "$TREE/lib/common.sh"
}

########################################
# Creates a script in the fixture tree, optionally with an include directive.
# Arguments:
#   path: Path relative to the fixture scripts/ directory.
#   include: "yes" to add the shellcheck+@include pair.
########################################
make_script() {
  local rel="$1" include="${2:-yes}"
  mkdir -p "$(dirname "$TREE/$rel")"
  # The directive is relative to the script, so its depth decides how many levels up the library is —
  # exactly as it does for the real scripts, which all sit one level down.
  local up="" depth
  depth=$(( $(tr -cd '/' <<< "$rel" | wc -c) ))
  while (( depth > 0 )); do
    up+="../"
    depth=$(( depth - 1 ))
  done
  {
    printf '#!/usr/bin/env bash\n'
    if [[ "$include" == yes ]]; then
      printf '# shellcheck source=%slib/common.sh\n' "$up"
      printf '# @include %slib/common.sh\n' "$up"
    fi
    printf 'echo body\n'
  } > "$TREE/$rel"
  chmod +x "$TREE/$rel"
}

########################################
# Runs the walk over the fixture tree, into the fixture output directory.
########################################
compile_run() {
  run_script "$FAKE_TOOL" -o "$OUT" "${1:-$TREE}"
}

# --- The walk ----------------------------------------------------------------------------------

@test "a script's include is resolved in the compiled copy" {
  make_script system/one.sh
  compile_run
  [ "$status" -eq 0 ]
  run cat "$OUT/one.sh"
  [[ "$output" == *"shared_fn() { echo shared; }"* ]]
  [[ "$output" != *"# @include"* ]]
}

# The compiled file is named after the script rather than after its path, because that is what a user
# installs: one file, named for the command.
@test "the compiled copy is named after the script, not its path" {
  make_script photography/nested/three.sh
  compile_run
  [ -f "$OUT/three.sh" ]
  [ ! -e "$OUT/photography" ]
}

@test "every script is compiled, at any depth" {
  make_script system/one.sh
  make_script utility/two.sh
  make_script photography/nested/three.sh
  compile_run
  [ "$status" -eq 0 ]
  local f
  for f in one.sh two.sh three.sh; do
    run grep -c "shared_fn" "$OUT/$f"
    [ "$output" = "1" ]
    run grep -c '# @include ' "$OUT/$f"
    [ "$output" = "0" ]
  done
}

# A script with no directives still has to reach dist/compiled, or packaging would find nothing there and
# fall back to the development form — the very split this arrangement removes.
@test "a script without a directive is compiled too, unchanged" {
  make_script utility/plain.sh no
  compile_run
  [ "$status" -eq 0 ]
  [ -f "$OUT/plain.sh" ]
  run diff "$TREE/utility/plain.sh" "$OUT/plain.sh"
  [ "$status" -eq 0 ]
}

@test "the compiled copy is executable" {
  make_script system/one.sh
  compile_run
  [ -x "$OUT/one.sh" ]
}

# The library is what gets inlined; compiling it would be meaningless, and it is not published.
@test "the shared library is not itself compiled" {
  make_script system/one.sh
  compile_run
  [ ! -e "$OUT/common.sh" ]
}

@test "the number compiled is reported" {
  make_script system/one.sh
  make_script utility/two.sh
  make_script utility/plain.sh no
  compile_run
  [[ "$output" == *"Compiled 3 script(s)."* ]]
}

@test "each compiled script is named as it is done, with its destination" {
  make_script system/one.sh
  compile_run
  [[ "$output" == *"Compiling: "*"one.sh -> "*"one.sh"* ]]
}

@test "a tree with nothing to compile succeeds and says so" {
  compile_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Compiled 0 script(s)."* ]]
}

@test "a path containing spaces is compiled, not split" {
  make_script "system/my script.sh"
  compile_run
  [ "$status" -eq 0 ]
  run grep -c "shared_fn" "$OUT/my script.sh"
  [ "$output" = "1" ]
}

# A failure has to stop the walk: publishing a half-compiled set would ship a script that cannot find its
# library at runtime.
@test "a script whose include cannot be resolved fails the walk" {
  make_script system/one.sh
  printf '# @include ../lib/does-not-exist.sh\n' >> "$TREE/system/one.sh"
  compile_run
  [ "$status" -ne 0 ]
}

@test "a missing directory is an error rather than a silent success" {
  compile_run "$FAKE_REPO/no-such-tree"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such directory"* ]]
}

@test "running twice produces the same output" {
  make_script system/one.sh
  compile_run
  local once
  once=$(cat "$OUT/one.sh")
  compile_run
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/one.sh")" = "$once" ]
}

@test "-o without a directory is refused" {
  run_script "$FAKE_TOOL" -o
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a directory"* ]]
}

# --- The sources are never touched -------------------------------------------------------------

# The whole reason for an output directory. A walk that rewrote the tree could not be run in development,
# which is how the repository ended up with one compile path for CI and none for a developer.
@test "the source scripts are left exactly as they were" {
  make_script system/one.sh
  make_script utility/two.sh
  local before_one before_two
  before_one=$(cat "$TREE/system/one.sh")
  before_two=$(cat "$TREE/utility/two.sh")
  compile_run
  [ "$status" -eq 0 ]
  [ "$(cat "$TREE/system/one.sh")" = "$before_one" ]
  [ "$(cat "$TREE/utility/two.sh")" = "$before_two" ]
  run grep -c '# @include ' "$TREE/system/one.sh"
  [ "$output" = "1" ]
}

@test "the repository's own scripts still carry their directives after a run" {
  make_script system/one.sh
  compile_run
  run grep -c '# @include ' "$REPO_ROOT/scripts/utility/subtitle-sync/subtitle-sync.sh"
  [ "$output" = "1" ]
}

#!/usr/bin/env bats
#
# The walk that inlines every publishable script before packaging. It used to be inline shell in two
# workflows, where the only way to exercise it was to push; the point of it being a script is that a
# mistake in the walk — skipping a script, descending into the library, tripping over a path with a space —
# fails here instead.
#
# Every test works in a fixture tree, so the repository's own scripts are never rewritten in place.

load test_helper

setup() {
  setup_common
  fake_repo_tool compile-all-includes.sh
  # The walk shells out to its sibling, so that has to be present in the fixture bin/ too.
  ln -s "$REPO_ROOT/bin/compile-includes.sh" "$FAKE_REPO/bin/compile-includes.sh"
  TREE="$FAKE_REPO/scripts"
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
# Runs the walk over the fixture tree.
########################################
compile_run() {
  run_script "$FAKE_TOOL" "${1:-$TREE}"
}

# --- The walk ----------------------------------------------------------------------------------

@test "a script with an include directive is compiled in place" {
  make_script system/one.sh
  compile_run
  [ "$status" -eq 0 ]
  run cat "$TREE/system/one.sh"
  [[ "$output" == *"shared_fn() { echo shared; }"* ]]
  [[ "$output" != *"# @include"* ]]
}

@test "every script carrying a directive is compiled, at any depth" {
  make_script system/one.sh
  make_script utility/two.sh
  make_script photography/nested/three.sh
  compile_run
  [ "$status" -eq 0 ]
  local f
  for f in system/one.sh utility/two.sh photography/nested/three.sh; do
    run grep -c "shared_fn" "$TREE/$f"
    [ "$output" = "1" ]
    run grep -c '# @include ' "$TREE/$f"
    [ "$output" = "0" ]
  done
}

@test "a script without a directive is left untouched" {
  make_script utility/plain.sh no
  local before
  before=$(cat "$TREE/utility/plain.sh")
  compile_run
  [ "$(cat "$TREE/utility/plain.sh")" = "$before" ]
}

# The library is what gets inlined; compiling it would be meaningless, and it is not published.
@test "the shared library is not itself compiled" {
  make_script system/one.sh
  printf '# @include ./other.sh\n' >> "$TREE/lib/common.sh"
  local before
  before=$(cat "$TREE/lib/common.sh")
  compile_run
  [ "$(cat "$TREE/lib/common.sh")" = "$before" ]
}

@test "the number compiled is reported" {
  make_script system/one.sh
  make_script utility/two.sh
  make_script utility/plain.sh no
  compile_run
  [[ "$output" == *"Compiled 2 script(s)."* ]]
}

@test "each compiled script is named as it is done" {
  make_script system/one.sh
  compile_run
  [[ "$output" == *"Compiling: "*"one.sh"* ]]
}

@test "a tree with nothing to compile succeeds and says so" {
  make_script utility/plain.sh no
  compile_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Compiled 0 script(s)."* ]]
}

@test "a path containing spaces is compiled, not split" {
  make_script "system/my script.sh"
  compile_run
  [ "$status" -eq 0 ]
  run grep -c "shared_fn" "$TREE/system/my script.sh"
  [ "$output" = "1" ]
}

# A failure has to stop the walk: publishing a half-inlined tree would ship a script that cannot find its
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

@test "running twice leaves the tree as the first run did" {
  make_script system/one.sh
  compile_run
  local once
  once=$(cat "$TREE/system/one.sh")
  compile_run
  [ "$status" -eq 0 ]
  [ "$(cat "$TREE/system/one.sh")" = "$once" ]
}

# --- Safety ------------------------------------------------------------------------------------

# The default target is the repository's own scripts/ directory, which the workflows rely on. A test that
# ran without an explicit argument would rewrite the working tree, so this asserts the fixture is what got
# compiled and the real tree still carries its directives.
@test "the repository's own scripts are not rewritten by these tests" {
  make_script system/one.sh
  compile_run
  run grep -c '# @include ' "$REPO_ROOT/scripts/utility/subtitle-sync.sh"
  [ "$output" = "1" ]
}

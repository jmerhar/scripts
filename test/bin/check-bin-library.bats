#!/usr/bin/env bats
#
# check-bin-library.sh is the bin/ counterpart of check-includes.sh. The tools source bin/_lib/ at run
# time, so a tool that calls log_error while sourcing only paths.sh loads fine and fails at the call —
# which for an error path can be during a release, when something is already going wrong. Nothing about
# that is visible to ShellCheck or to a passing test run, so it is checked mechanically.
#
# The tool takes paths as arguments, so each test hands it one hand-written tool rather than driving the
# real bin/ tree, and the fixtures are the whole input.

load ../test_helper

setup() {
  setup_common
  fake_repo_tool check-bin-library.sh
  TOOL_DIR="$FAKE_REPO/bin/lint"
}

########################################
# Writes a tool into the fixture's bin/lint/ and prints its path.
# Arguments:
#   name: File name.
#   body: Tool contents, read from stdin.
########################################
tool_at() {
  local path="$TOOL_DIR/$1"
  cat > "$path"
  chmod +x "$path"
  printf '%s' "$path"
}

# --- Sourcing what it uses ---------------------------------------------------------------------

@test "a tool that sources what it uses passes" {
  local t
  t=$(tool_at good.sh <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
log_info "reading ${MANIFEST}"
EOF
)
  run_script "$FAKE_TOOL" "$t"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 bin/ tool(s) source the library files they use"* ]]
}

# The failure this exists for: the call site is the first thing that breaks, and it may be an error path.
@test "a tool calling a log function without sourcing log.sh is refused" {
  local t
  t=$(tool_at bad-log.sh <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/paths.sh"
echo "${MANIFEST}"
log_error "boom"
EOF
)
  run_script "$FAKE_TOOL" "$t"
  [ "$status" -eq 1 ]
  [[ "$output" == *"uses log_error, provided by _lib/log.sh, which it does not source"* ]]
}

# paths.sh provides variables rather than functions, so a check looking only at functions would pass this.
@test "a tool using a path variable without sourcing paths.sh is refused" {
  local t
  t=$(tool_at bad-paths.sh <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
log_info "reading ${MANIFEST}"
EOF
)
  run_script "$FAKE_TOOL" "$t"
  [ "$status" -eq 1 ]
  [[ "$output" == *"uses MANIFEST, provided by _lib/paths.sh, which it does not source"* ]]
}

# A tool with its own log_error is not relying on the library's, exactly as for the publishable scripts.
@test "a tool that defines the symbol itself is not required to source the library" {
  local t
  t=$(tool_at own.sh <<'EOF'
#!/usr/bin/env bash
log_error() { echo "$*" >&2; }
log_error "boom"
EOF
)
  run_script "$FAKE_TOOL" "$t"
  [ "$status" -eq 0 ]
}

# A doc block naming REPO_ROOT under `Globals:` is documentation, not a use.
@test "a symbol named only in a comment is not a use" {
  local t
  t=$(tool_at commented.sh <<'EOF'
#!/usr/bin/env bash
#######################################
# Globals:
#   REPO_ROOT, MANIFEST
#######################################
echo hi
EOF
)
  run_script "$FAKE_TOOL" "$t"
  [ "$status" -eq 0 ]
}

# --- Using what it sources ---------------------------------------------------------------------

# The rule the publishable scripts follow too: a source line outlives the last call that needed it
# otherwise, and the next reader cannot tell whether it still matters.
@test "a tool sourcing a library it uses nothing from is refused" {
  local t
  t=$(tool_at unused.sh <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
echo hi
EOF
)
  run_script "$FAKE_TOOL" "$t"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sources _lib/log.sh but uses nothing from it"* ]]
}

# The guards are the library's own business; reading one would be reaching inside it.
@test "a double-source guard variable does not count as a provided symbol" {
  local t
  t=$(tool_at guard.sh <<'EOF'
#!/usr/bin/env bash
_BIN_LOG_SH_LOADED="true"
echo hi
EOF
)
  run_script "$FAKE_TOOL" "$t"
  [ "$status" -eq 0 ]
}

# --- The shellcheck hint pair ------------------------------------------------------------------

@test "a shellcheck hint naming a different file than the source line is refused" {
  local t
  t=$(tool_at mismatched.sh <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../_lib/paths.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
log_error "boom"
EOF
)
  run_script "$FAKE_TOOL" "$t"
  [ "$status" -eq 1 ]
  [[ "$output" == *"shellcheck hint names"* ]]
  [[ "$output" == *"but source loads 'log.sh'"* ]]
}

# The hint applies to the line beneath it, so an unrelated hint elsewhere is not paired with a later source.
@test "a hint separated from the source line is not paired with it" {
  local t
  t=$(tool_at separated.sh <<'EOF'
#!/usr/bin/env bash
# shellcheck source=/dev/null
eval "true"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../_lib/log.sh
source "${SCRIPT_DIR}/../_lib/log.sh"
log_error "boom"
EOF
)
  run_script "$FAKE_TOOL" "$t"
  [ "$status" -eq 0 ]
}

# --- Arguments and prerequisites ---------------------------------------------------------------

# Every tool, and only the tools: the library files themselves are what provide the symbols, so counting
# them in would report a number that does not match the tools checked.
@test "the whole bin tree except the library is checked when no tool is named" {
  local expected
  # -L to match the walk: the fixture mirrors bin/ as symlinks, which `-type f` alone does not match.
  expected=$(find -L "$FAKE_REPO/bin" -mindepth 2 -type f -name '*.sh' -not -path '*/_lib/*' | wc -l | tr -d ' ')
  run_script "$FAKE_TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All $expected bin/ tool(s) source the library files they use"* ]]
  [ "$expected" -gt 1 ]
}

@test "a tool that does not exist is reported rather than skipped" {
  run_script "$FAKE_TOOL" "$TOOL_DIR/absent.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tool not found"* ]]
}

@test "--help explains the checks" {
  run_script "$FAKE_TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: check-bin-library.sh"* ]]
}

.PHONY: compile coverage-tooling docs docs-check help install lint published smoke test test-ci test-coverage coverage check clean

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*##|^##@' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} {printf "  \033[36mmake %-14s\033[0m %s\n", $$1, $$2}'

# Defined here so both `coverage-tooling` (which fetches it) and `coverage` (which runs it) see one name.
COVERAGE_REPORT := .coverage-report.py

##@ Setup

install: ## Install the test toolchain via Homebrew
	brew install bats-core yq

##@ Quality

# --severity=warning matches .github/workflows/lint.yml, so a local run and CI agree. The stubs and
# the test helper are named without a .sh extension, so that workflow's find(1) misses them; they are
# listed explicitly here.
# find rather than a glob: the scripts sit one directory deeper than they used to, and a glob that stops
# matching reports success while checking nothing. The stubs and the test helper have no .sh extension, so
# they are named separately.
lint: ## ShellCheck everything, and validate the manifest and declared bash versions
	find bin scripts -name '*.sh' -print0 | xargs -0 shellcheck --severity=warning
	shellcheck --severity=warning test/test_helper.bash test/stubs/_stub
	bin/check-manifest.sh
	bin/check-bash-version.sh
	bin/check-programs.sh
	bin/check-includes.sh
	$(MAKE) docs-check

# Compiles every script into dist/compiled/ — the single file per script that gets published, carrying the
# library and any awk or jq programs inline. Safe in a working tree: it writes only to dist/.
compile: ## Compile every script into dist/compiled/
	bin/compile-all-includes.sh

# Packages every manifest entry at a throwaway version, which is what catches a manifest and a packager
# that have stopped agreeing. Writes into dist/, which `make clean` removes.
#
# The packager compiles each script into dist/compiled before packaging it, so what this smoke-tests is the
# published form rather than the development one.
smoke: ## Package every manifest entry at v0.0.0 as a smoke test
	bin/smoke-package-all.sh

# Compiles into a throwaway directory and asserts the result is self-contained: no script still sources the
# library or reads a program, and every inlined program matches its file.
published: ## Verify every published script compiles to a self-contained file
	bin/check-published-form.sh

# The root index and every topic index come from scripts.yaml, so a script cannot be renamed,
# moved or added without its documentation following. `make lint` runs the same generator with --check, so
# a stale index fails the build rather than going unnoticed.
docs: ## Regenerate the README index sections from the manifest
	@bin/update-all-indexes.sh

docs-check: ## Fail if any README index section is out of date
	@bin/update-all-indexes.sh --check

test: ## Run the bats suite
	bats --recursive test/

# The suite passing locally is not the same as it passing in CI, and the difference has bitten repeatedly:
# GITHUB_ACTIONS is set for the whole job, so a test asserting no annotations must clear it; and the
# runners' git defaults to `master` where a developer's may default to `main`, which changes what a bare
# fixture repository's HEAD points at. This runs the suite with both, so that class of failure surfaces
# before a push rather than after.
test-ci: ## Run the suite with the environment CI has
	GITHUB_ACTIONS=true \
	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=master \
	bats --recursive test/

# Measured in the pinned kcov container, even locally: kcov's macOS build ignores the shebang and execs
# /bin/bash, which is 3.2, and most of these scripts need 4.0 or newer. run-coverage.sh detects that and
# falls back, so this needs Docker running rather than a local kcov.
test-coverage: ## Run the suite under kcov without gating (writes coverage/)
	bin/run-coverage.sh

# The coverage summary and gate are shared tooling from jmerhar/coverage, configured by coverage.toml.
# Fetched rather than vendored, so a local gate enforces exactly what CI does. Refreshed on every run
# rather than only when absent: v1 moves within its major version, so a cached copy would drift from
# what CI enforces. -z makes an unchanged file cost a 304, and a failed request falls back to the copy
# already on disk, so this still works offline.
coverage-tooling: ## Fetch the shared coverage-report script (run automatically by `make coverage`)
	@curl -fsSL -z $(COVERAGE_REPORT) -o $(COVERAGE_REPORT) \
		https://raw.githubusercontent.com/jmerhar/coverage/v1/bin/coverage-report.py \
		|| test -f $(COVERAGE_REPORT)

coverage: coverage-tooling ## Run the suite under kcov and enforce the coverage gate
	bin/run-coverage.sh
	python3 $(COVERAGE_REPORT) --gate

check: lint test published ## Lint + tests + published form (gate a commit on this)

##@ Housekeeping

clean: ## Remove build and coverage artefacts (all regenerable)
	rm -rf dist coverage junit $(COVERAGE_REPORT)

.PHONY: compile docs docs-check install lint published smoke test test-ci test-coverage coverage check clean

# help, devtools-update, coverage-tooling and devtools-check come from jmerhar/devtools; make
# fetches them on the first run and whenever devtools.toml changes.
.DEFAULT_GOAL := help
DEVTOOLS_FETCH := tools/devtools-fetch.sh
include .devtools/make/devtools.mk
.devtools/make/devtools.mk: devtools.toml $(DEVTOOLS_FETCH)
	$(DEVTOOLS_FETCH)

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
	bin/lint/check-manifest.sh
	bin/lint/check-bash-version.sh
	bin/lint/check-programs.sh
	bin/lint/check-includes.sh
	bin/lint/check-bin-library.sh
	bin/lint/check-continuations.sh
	bin/lint/check-inline-programs.sh
	$(MAKE) docs-check

# Compiles every script into dist/compiled/ — the single file per script that gets published, carrying the
# library and any awk or jq programs inline. Safe in a working tree: it writes only to dist/.
compile: ## Compile every script into dist/compiled/
	bin/compile/compile-all-includes.sh

# Packages every manifest entry at a throwaway version, which is what catches a manifest and a packager
# that have stopped agreeing. Writes into dist/, which `make clean` removes.
#
# The packager compiles each script into dist/compiled before packaging it, so what this smoke-tests is the
# published form rather than the development one.
smoke: ## Package every manifest entry at v0.0.0 as a smoke test
	bin/package/smoke-package-all.sh

# Compiles into a throwaway directory and asserts the result is self-contained: no script still sources the
# library or reads a program, and every inlined program matches its file.
published: ## Verify every published script compiles to a self-contained file
	bin/lint/check-published-form.sh

# The root index and every topic index come from scripts.yaml, so a script cannot be renamed,
# moved or added without its documentation following. `make lint` runs the same generator with --check, so
# a stale index fails the build rather than going unnoticed.
docs: ## Regenerate the README index sections from the manifest
	@bin/docs/update-all-indexes.sh

docs-check: ## Fail if any README index section is out of date
	@bin/docs/update-all-indexes.sh --check

test: ## Run the bats suite
	bin/test/run-suite.sh

# The suite passing locally is not the same as it passing in CI, and the difference has bitten repeatedly:
# GITHUB_ACTIONS is set for the whole job, so a test asserting no annotations must clear it; and the
# runners' git defaults to `master` where a developer's may default to `main`, which changes what a bare
# fixture repository's HEAD points at. run-suite.sh --ci applies that environment, so the class of
# failure surfaces before a push rather than after.
test-ci: ## Run the suite with the environment CI has
	bin/test/run-suite.sh --ci

# Measured in the pinned kcov container, even locally (`local = false` in coverage.toml), so this needs
# Docker: the scripts branch on the platform, the coreutils flavour and root, and a Mac would measure
# different lines from the Linux container CI publishes.
test-coverage: coverage-tooling ## Run the suite under kcov without gating (writes coverage/)
	bash $(COVERAGE_TOOLING)/run-kcov.sh

coverage: test-coverage ## Run the suite under kcov and enforce the coverage gate
	python3 $(COVERAGE_TOOLING)/coverage-report.py --gate

check: lint test-ci published devtools-check ## Lint + tests + published form (gate a commit on this)

##@ Housekeeping

clean: ## Remove build and coverage artefacts (all regenerable)
	rm -rf dist coverage junit

.PHONY: help install lint test check clean

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*##|^##@' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next} {printf "  \033[36mmake %-12s\033[0m %s\n", $$1, $$2}'

##@ Setup

install: ## Install the test toolchain
	brew install bats-core

##@ Quality

# --severity=warning matches .github/workflows/lint.yml, so a local run and CI agree. The stubs and
# the test helper are named without a .sh extension, so that workflow's find(1) misses them; they are
# listed explicitly here.
lint: ## ShellCheck everything, and check the declared bash versions
	shellcheck --severity=warning bin/*.sh scripts/*/*.sh
	shellcheck --severity=warning test/test_helper.bash test/stubs/_stub
	bin/check-bash-version.sh

test: ## Run the bats suite
	bats test/

check: lint test ## Lint + tests (gate a commit on this)

##@ Housekeeping

clean: ## Remove build artefacts (all regenerable)
	rm -rf dist

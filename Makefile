.DEFAULT_GOAL := help

IOS_DIR := apps/ios
SERVER_DIR := apps/server

.PHONY: help codex-worktree-test ios-help server-help

help: ## Show monorepo development commands.
	@printf '%s\n' \
		'Quant monorepo commands:' \
		'  make ios-<target>       Run a target from apps/ios/Makefile' \
		'  make server-<target>    Run a target from apps/server/Makefile' \
		'' \
		'Examples:' \
		'  make ios-build' \
		'  make ios-test TEST_TARGET=QuantTests' \
		'  make ios-deploy-device DEVICE=Clemens-iPhone2' \
		'  make server-test' \
		'  make server-docker-build' \
		'  make server-config' \
		'  make codex-worktree-test' \
		'' \
		'Run make ios-help or make server-help for every application target.'

codex-worktree-test: ## Test isolated Codex worktree integration.
	./scripts/test-codex-worktree.sh

ios-help:
	+$(MAKE) -C "$(IOS_DIR)" help

server-help:
	+$(MAKE) -C "$(SERVER_DIR)" help

ios-%:
	+$(MAKE) -C "$(IOS_DIR)" "$*"

server-%:
	+$(MAKE) -C "$(SERVER_DIR)" "$*"

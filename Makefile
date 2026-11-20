.DEFAULT_GOAL := help

.PHONY: help test build docker-build run

help: ## Show available commands.
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  %-18s %s\n", $$1, $$2 }' "$(firstword $(MAKEFILE_LIST))"

test: ## Run all Go tests.
	go test ./...

build: ## Build the server locally.
	go build ./cmd/quant-server

docker-build: ## Build the production container.
	docker build -t quant-server:local .

run: ## Start the Compose stack.
	docker compose up --build

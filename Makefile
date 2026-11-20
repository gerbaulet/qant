.DEFAULT_GOAL := help

COMPOSE ?= docker compose

.PHONY: help test build docker-build config up start stop restart down status logs health run

help: ## Show available commands.
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  %-18s %s\n", $$1, $$2 }' "$(firstword $(MAKEFILE_LIST))"

test: ## Run all Go tests.
	go test ./...

build: ## Build the server locally.
	go build ./cmd/quant-server

docker-build: ## Build the production container.
	docker build -t quant-server:local .

config: ## Validate the Compose configuration.
	$(COMPOSE) config --quiet

up: config ## Build and start the server in the background.
	$(COMPOSE) up --detach --build

start: ## Start existing server containers.
	$(COMPOSE) start

stop: ## Stop the server without removing its containers.
	$(COMPOSE) stop

restart: ## Restart the running server.
	$(COMPOSE) restart

down: ## Stop and remove containers while preserving job data.
	$(COMPOSE) down --remove-orphans

status: ## Show the server container status.
	$(COMPOSE) ps

logs: ## Follow the latest server logs.
	$(COMPOSE) logs --follow --tail=100

health: ## Check whether the local server is healthy.
	curl --fail --silent --show-error http://127.0.0.1:8080/healthz
	@printf '\n'

run: up ## Alias for "make up".

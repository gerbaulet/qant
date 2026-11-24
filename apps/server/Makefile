.DEFAULT_GOAL := help

COMPOSE ?= docker compose
TAILSCALE ?= tailscale
TAILSCALE_TARGET ?= 8080
TAILSCALE_HTTPS_PORT ?= 443
DEPLOY_HOST ?= server01.tail851aa0.ts.net
DEPLOY_USER ?= clemens

.PHONY: help test build docker-build config up start stop restart down status logs health run tailscale-up tailscale-down tailscale-status host-status deploy deploy-server

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

tailscale-up: ## Publish the server privately with Tailscale Serve.
	$(TAILSCALE) serve --bg $(TAILSCALE_TARGET)

tailscale-down: ## Disable Tailscale Serve on HTTPS port 443.
	$(TAILSCALE) serve --https=$(TAILSCALE_HTTPS_PORT) off

tailscale-status: ## Show the active Tailscale Serve configuration.
	$(TAILSCALE) serve status

host-status: ## Show host security and service status (run on the server).
	sudo quant-provision status

deploy-server: deploy ## Deploy to server01; override DEPLOY_HOST or DEPLOY_USER if needed.

deploy:
	@test -n "$(DEPLOY_HOST)" || { echo "DEPLOY_HOST is required (for example SERVER-NAME.ts.net)" >&2; exit 2; }
	@test -n "$(DEPLOY_USER)" || { echo "DEPLOY_USER is required (for example clemens)" >&2; exit 2; }
	scripts/deploy-server.sh --host "$(DEPLOY_HOST)" --user "$(DEPLOY_USER)"

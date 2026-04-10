# ============================================================================
# eBillio RADIUS  --  developer / test convenience Makefile
#
# Every target has a `## ...` comment which `make help` picks up.
# ============================================================================

SHELL := /usr/bin/env bash

# Load .env if present so targets that touch the DB have DB_ROOT_PASSWORD /
# RADIUS_SECRET in scope. Missing file is fine for targets like `help`.
ifneq (,$(wildcard .env))
include .env
export
endif

MYSQL_CONTAINER  ?= radius-mysql
RADIUS_CONTAINER ?= radius-server

.DEFAULT_GOAL := help

.PHONY: help up down logs seed clean-test-data test test-auth test-accounting \
        test-coa shell-mysql shell-radius validate-config

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} \
	     /^[a-zA-Z0-9_.-]+:.*?## / \
	     {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

up: ## Build and start the docker compose stack
	docker compose up -d --build

down: ## Stop and remove the docker compose stack
	docker compose down

logs: ## Tail freeradius + mysql logs
	docker compose logs -f freeradius mysql

seed: ## Load sql/seed-test-data.sql into the radius database (test users/NAS)
	@if [ -z "$$DB_ROOT_PASSWORD" ]; then \
	    echo "DB_ROOT_PASSWORD not set  --  populate .env first" >&2; exit 1; \
	fi
	@if [ -z "$$RADIUS_SECRET" ]; then \
	    echo "RADIUS_SECRET not set  --  populate .env first" >&2; exit 1; \
	fi
	@echo "Seeding test data into radius DB..."
	@sed "s|__RADIUS_SECRET__|$$RADIUS_SECRET|g" sql/seed-test-data.sql \
	    | docker exec -i $(MYSQL_CONTAINER) \
	        mysql -uroot -p"$$DB_ROOT_PASSWORD" radius
	@echo "  -> seeded."

clean-test-data: ## Delete all testuser-* / testgroup-* rows from the DB
	@if [ -z "$$DB_ROOT_PASSWORD" ]; then \
	    echo "DB_ROOT_PASSWORD not set  --  populate .env first" >&2; exit 1; \
	fi
	@echo "Wiping test data..."
	@docker exec -i $(MYSQL_CONTAINER) \
	    mysql -uroot -p"$$DB_ROOT_PASSWORD" radius < sql/clean-test-data.sql
	@echo "  -> cleaned."

test: ## Run the full test suite (auth + accounting + coa)
	@bash tests/run-all.sh

test-auth: ## Run just the authentication tests
	@bash tests/test-auth.sh

test-accounting: ## Run just the accounting tests
	@bash tests/test-accounting.sh

test-coa: ## Run just the CoA smoke test (skips if listener not enabled)
	@bash tests/test-coa.sh

shell-mysql: ## Open a mysql shell in the radius database
	@if [ -z "$$DB_ROOT_PASSWORD" ]; then \
	    echo "DB_ROOT_PASSWORD not set  --  populate .env first" >&2; exit 1; \
	fi
	docker exec -it $(MYSQL_CONTAINER) \
	    mysql -uroot -p"$$DB_ROOT_PASSWORD" radius

shell-radius: ## Open a shell in the freeradius container
	docker exec -it $(RADIUS_CONTAINER) /bin/bash

validate-config: ## Run `freeradius -C` inside the container to validate config
	docker exec -it $(RADIUS_CONTAINER) freeradius -C -d /etc/freeradius/3.0

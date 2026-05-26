.PHONY: help setup validate deploy logs verify status test-client clean

# TAK Server Docker Deployment Makefile
# Provides convenient commands for common deployment tasks

PROJECT_ROOT := $(shell pwd)
DOCKER_COMPOSE := docker-compose
ENV_FILE := $(PROJECT_ROOT)/.env
DOCKER_DIR := $(PROJECT_ROOT)/docker
SCRIPTS_DIR := $(PROJECT_ROOT)/scripts

help:
	@echo "TAK Server Docker Deployment - Available Commands"
	@echo ""
	@echo "Setup & Configuration:"
	@echo "  make setup                - Interactive setup wizard"
	@echo "  make validate             - Validate .env configuration"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy               - Build and start containers"
	@echo "  make start                - Start containers (no rebuild)"
	@echo "  make stop                 - Stop running containers"
	@echo "  make restart              - Restart containers"
	@echo ""
	@echo "Verification & Monitoring:"
	@echo "  make verify               - Run post-deployment verification"
	@echo "  make status               - Show deployment health status"
	@echo "  make test-client          - Test client connection"
	@echo "  make logs                 - Tail TAK Server logs"
	@echo "  make logs-db              - Tail database logs"
	@echo "  make logs-all             - Tail all container logs"
	@echo ""
	@echo "Development:"
	@echo "  make clean                - Remove containers and volumes"
	@echo "  make reset                - Hard reset (removes all data)"
	@echo "  make shell                - Open shell in TAK Server container"
	@echo ""

# ============================================================================
# Setup & Configuration
# ============================================================================

setup:
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo "No .env file found. Running setup wizard..."; \
		bash "$(SCRIPTS_DIR)/setup.sh"; \
	else \
		echo ".env already exists. Run 'make validate' to check configuration."; \
	fi

validate:
	@bash "$(DOCKER_DIR)/validate-env.sh"

# ============================================================================
# Deployment
# ============================================================================

deploy: validate
	@echo "Building and deploying TAK Server..."
	$(DOCKER_COMPOSE) up -d --build
	@echo ""
	@echo "Containers starting. Monitor with: make logs"
	@echo "Verify deployment with: make verify"

start:
	$(DOCKER_COMPOSE) up -d

stop:
	$(DOCKER_COMPOSE) stop

restart: stop start

# ============================================================================
# Verification & Monitoring
# ============================================================================

verify:
	@bash "$(SCRIPTS_DIR)/verify-deployment.sh"

status:
	@bash "$(SCRIPTS_DIR)/status.sh"

test-client:
	@bash "$(DOCKER_DIR)/test-client-connection.sh"

logs:
	$(DOCKER_COMPOSE) logs -f takserver

logs-db:
	$(DOCKER_COMPOSE) logs -f takserver-db

logs-all:
	$(DOCKER_COMPOSE) logs -f

# ============================================================================
# Development
# ============================================================================

clean:
	$(DOCKER_COMPOSE) down

reset:
	$(DOCKER_COMPOSE) down -v
	rm -f "$(PROJECT_ROOT)/.env"
	rm -rf "$(PROJECT_ROOT)/data/certs"
	@echo "Reset complete. Run 'make setup' to reconfigure."

shell:
	docker exec -it $$(docker ps -q -f name=takserver) /bin/bash

# ============================================================================
# CI/CD Targets (for automation)
# ============================================================================

.PHONY: ci-validate ci-deploy ci-test ci-clean

ci-validate: validate

ci-deploy: validate
	$(DOCKER_COMPOSE) up -d --build
	@sleep 30
	@bash "$(SCRIPTS_DIR)/verify-deployment.sh"

ci-test: test-client

ci-clean: clean

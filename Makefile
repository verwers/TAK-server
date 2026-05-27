.PHONY: help setup validate init-resources deploy logs verify status test-client clean cot-tail cot-sql

# TAK Server Docker Deployment Makefile
# Provides convenient commands for common deployment tasks

PROJECT_ROOT := $(shell pwd)
DOCKER_COMPOSE := docker compose
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
	@echo "  make cot-tail             - Tail CoT messaging log inside the container"
	@echo "  make cot-sql              - Poll Postgres for the latest CoT events (live feed)"
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

# ----------------------------------------------------------------------------
# Persistent resources (external volumes + network)
#
# These survive `docker compose down` and version bumps so the Postgres
# database and historical logs are not lost when TAK_VERSION changes.
# Safe to run repeatedly; `docker volume/network create` already prints a
# warning and exits 0 if the resource exists.
# ----------------------------------------------------------------------------
init-resources:
	@docker volume create takserver-db-data >/dev/null
	@docker volume create takserver-logs    >/dev/null
	@docker network create takserver-net    >/dev/null 2>&1 || true

# ============================================================================
# Deployment
# ============================================================================

deploy: validate init-resources
	@echo "Building and deploying TAK Server..."
	$(DOCKER_COMPOSE) up -d --build
	@echo ""
	@echo "Containers starting. Monitor with: make logs"
	@echo "Verify deployment with: make verify"

start: init-resources
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

cot-tail:
	docker exec -it $$(docker compose ps -q takserver) sh -c 'tail -F /opt/tak/logs/takserver-messaging.log'

cot-sql:
	@PW=$$(grep '^POSTGRES_PASSWORD=' $(ENV_FILE) | cut -d= -f2-); \
	DB=$$(docker compose ps -q takserver-db); \
	if [ -z "$$DB" ]; then echo "Database container not running."; exit 1; fi; \
	echo "Polling cot_router for new CoT events (full XML). Ctrl-C to stop."; \
	LAST=0; \
	while true; do \
		SQL="SELECT id || '|' || '<event version=\"2.0\" uid=\"' || coalesce(uid,'') || '\" type=\"' || coalesce(cot_type,'') || '\" how=\"' || coalesce(how,'') || '\" time=\"' || coalesce(to_char(time at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'') || '\" start=\"' || coalesce(to_char(start at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'') || '\" stale=\"' || coalesce(to_char(stale at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'') || '\"><point lat=\"' || coalesce(ST_Y(event_pt)::text,'0') || '\" lon=\"' || coalesce(ST_X(event_pt)::text,'0') || '\" hae=\"' || coalesce(point_hae::text,'9999999') || '\" ce=\"' || coalesce(point_ce::text,'9999999') || '\" le=\"' || coalesce(point_le::text,'9999999') || '\"/>' || coalesce(detail,'') || '</event>' FROM cot_router WHERE id > $$LAST ORDER BY id ASC;"; \
		ROWS=$$(docker exec -e PGPASSWORD=$$PW $$DB psql -h 127.0.0.1 -U martiuser -d cot -A -t -c "$$SQL" 2>/dev/null); \
		if [ -n "$$ROWS" ]; then \
			echo "$$ROWS"; \
			LAST=$$(echo "$$ROWS" | tail -n1 | cut -d'|' -f1); \
		fi; \
		sleep 2; \
	done

# ============================================================================
# Development
# ============================================================================

clean:
	$(DOCKER_COMPOSE) down

reset:
	$(DOCKER_COMPOSE) down -v
	# External resources are not touched by `down -v`; remove them explicitly.
	-docker volume rm takserver-db-data 2>/dev/null
	-docker volume rm takserver-logs    2>/dev/null
	-docker network rm takserver-net    2>/dev/null
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

ci-deploy: validate init-resources
	$(DOCKER_COMPOSE) up -d --build
	@sleep 30
	@bash "$(SCRIPTS_DIR)/verify-deployment.sh"

ci-test: test-client

ci-clean: clean

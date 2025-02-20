# include .env-api
SHELL := /bin/bash
BIN := $(shell pwd)/bin
VERSION ?= $(shell git rev-parse --short HEAD)
GO?=$(shell which go)
export GOBIN := $(BIN)
export PATH := $(BIN):$(PATH)

BUILD_CMD := $(GO) install -ldflags "-X main.build=${VERSION}"

LOCAL_DEV_PATH = $(shell pwd)/infrastructure/local
DOCKER_COMPOSE_FILE := $(LOCAL_DEV_PATH)/docker-compose.yml
DOCKER_COMPOSE_FILE_INFRA := $(LOCAL_DEV_PATH)/docker-compose-infra.yml
DOCKER_COMPOSE_CMD := docker compose -p issuer -f $(DOCKER_COMPOSE_FILE)
DOCKER_COMPOSE_INFRA_CMD := docker compose -p issuer -f $(DOCKER_COMPOSE_FILE_INFRA)
ENVIRONMENT := ${ISSUER_API_ENVIRONMENT}


# Local environment overrides via godotenv
DOTENV_CMD = $(BIN)/godotenv
ENV = $(DOTENV_CMD) -f .env-issuer

.PHONY: build-local
build-local:
	$(BUILD_CMD) ./cmd/...

.PHONY: build/docker
build/docker: ## Build the docker image.
	DOCKER_BUILDKIT=1 \
	docker build \
					-f ./Dockerfile \
					-t issuer/api:$(VERSION) \
					--build-arg VERSION=$(VERSION) \
					--build-arg BUILD_DATE=`date -u +"%Y-%m-%dT%H:%M:%SZ"` \
					.

.PHONY: clean
clean: ## Go clean
	$(GO) clean ./...

.PHONY: tests
tests:
	$(GO) test -v ./... --count=1

.PHONY: test-race
test-race:
	$(GO) test -v --race ./...

$(BIN)/oapi-codegen: tools.go go.mod go.sum ## install code generator for API files.
	go get github.com/deepmap/oapi-codegen/cmd/oapi-codegen
	$(GO) install github.com/deepmap/oapi-codegen/cmd/oapi-codegen

.PHONY: api
api: $(BIN)/oapi-codegen
	$(BIN)/oapi-codegen -config ./api/config-oapi-codegen.yaml ./api/api.yaml > ./internal/api/api.gen.go


.PHONY: api-ui
api-ui: $(BIN)/oapi-codegen
	$(BIN)/oapi-codegen -config ./api_ui/config-oapi-codegen.yaml ./api_ui/api.yaml > ./internal/api_ui/api.gen.go

.PHONY: up
up:
	$(DOCKER_COMPOSE_INFRA_CMD) up -d redis postgres vault

.PHONY: run
run:
	$(eval DELETE_FILE = $(shell if [ -f ./.env-ui ]; then echo "false"; else echo "true"; fi))
	@if [ -f ./.env-ui ]; then echo "false"; else touch ./.env-ui; fi
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile" $(DOCKER_COMPOSE_CMD) up -d api pending_publisher
	@if [ $(DELETE_FILE) = "true" ] ; then rm ./.env-ui; fi

.PHONY: run-arm
run-arm:
	$(eval DELETE_FILE = $(shell if [ -f ./.env-ui ]; then echo "false"; else echo "true"; fi))
	@if [ -f ./.env-ui ]; then echo "false"; else touch ./.env-ui; fi
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile-arm" $(DOCKER_COMPOSE_CMD) up -d api pending_publisher
	@if [ $(DELETE_FILE) = "true" ] ; then rm ./.env-ui; fi

.PHONY: run-ui
run-ui: add-host-url-swagger
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile" $(DOCKER_COMPOSE_CMD) up -d api-ui ui notifications pending_publisher

.PHONY: run-ui-arm
run-ui-arm: add-host-url-swagger
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile-arm" $(DOCKER_COMPOSE_CMD) up -d api-ui ui notifications pending_publisher

.PHONY: build
build:
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile" $(DOCKER_COMPOSE_CMD) build api pending_publisher

.PHONY: build-arm
build-arm:
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile-arm" $(DOCKER_COMPOSE_CMD) build api pending_publisher

.PHONY: build-ui
build-ui:
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile" $(DOCKER_COMPOSE_CMD) build api-ui ui notifications pending_publisher

.PHONY: build-ui-arm
build-ui-arm:
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile-arm" $(DOCKER_COMPOSE_CMD) build api-ui ui notifications pending_publisher

.PHONY: down
down:
	$(DOCKER_COMPOSE_INFRA_CMD) down --remove-orphans
	$(DOCKER_COMPOSE_CMD) down --remove-orphans

.PHONY: stop
stop:
	$(DOCKER_COMPOSE_INFRA_CMD) stop
	$(DOCKER_COMPOSE_CMD) stop

.PHONY: up-test
up-test:
	$(DOCKER_COMPOSE_INFRA_CMD) up -d test_postgres vault test_local_files_apache

.PHONY: clean-vault
clean-vault:
	rm -R infrastructure/local/.vault/data/init.out
	rm -R infrastructure/local/.vault/file/core/
	rm -R infrastructure/local/.vault/file/logical/
	rm -R infrastructure/local/.vault/file/sys/

$(BIN)/platformid-migrate:
	$(BUILD_CMD) ./cmd/migrate

$(BIN)/install-goose: go.mod go.sum
	$(GO) install github.com/pressly/goose/v3

$(BIN)/golangci-lint: go.mod go.sum
	$(GO) install github.com/golangci/golangci-lint/cmd/golangci-lint

$(BIN)/godotenv: tools.go go.mod go.sum
	$(GO) install github.com/joho/godotenv/cmd/godotenv

.PHONY: db/migrate
db/migrate: $(BIN)/install-goose $(BIN)/godotenv $(BIN)/platformid-migrate ## Install goose and apply migrations.
	$(ENV) sh -c '$(BIN)/migrate'

.PHONY: lint
lint: $(BIN)/golangci-lint
	$(BIN)/golangci-lint run

# usage: make private_key=xxx add-private-key
.PHONY: add-private-key
add-private-key:
	docker exec issuer-vault-1 \
	vault write iden3/import/pbkey key_type=ethereum private_key=$(private_key)

.PHONY: print-vault-token
print-vault-token:
	$(eval TOKEN = $(shell docker logs issuer-vault-1 2>&1 | grep " .hvs" | awk  '{print $$2}' | tail -1 ))
	@echo $(TOKEN)

.PHONY: add-vault-token
add-vault-token:
	$(eval TOKEN = $(shell docker logs issuer-vault-1 2>&1 | grep " .hvs" | awk  '{print $$2}' | tail -1 ))
	sed '/ISSUER_KEY_STORE_TOKEN/d' .env-issuer > .env-issuer.tmp
	@echo ISSUER_KEY_STORE_TOKEN=$(TOKEN) >> .env-issuer.tmp
	mv .env-issuer.tmp .env-issuer


.PHONY: run-initializer
run-initializer:
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile" $(DOCKER_COMPOSE_CMD) up -d initializer
	sleep 5

.PHONY: generate-issuer-did
generate-issuer-did: run-initializer
	$(eval DID = $(shell docker logs -f --tail 1 issuer-initializer-1 | grep "did"))
	@echo $(DID)
	sed '/ISSUER_API_UI_ISSUER_DID/d' .env-api > .env-api.tmp
	@echo ISSUER_API_UI_ISSUER_DID=$(DID) >> .env-api.tmp
	mv .env-api.tmp .env-api
	docker logs issuer-initializer-1
	docker rm issuer-initializer-1

.PHONY: run-initializer-arm
run-initializer-arm:
	COMPOSE_DOCKER_CLI_BUILD=1 DOCKER_FILE="Dockerfile-arm" $(DOCKER_COMPOSE_CMD) up -d initializer
	sleep 5

.PHONY: generate-issuer-did-arm
generate-issuer-did-arm: run-initializer-arm
	$(eval DID = $(shell docker logs -f --tail 1 issuer-initializer-1 | grep "did"))
	@echo $(DID)
	sed '/ISSUER_API_UI_ISSUER_DID/d' .env-api > .env-api.tmp
	@echo ISSUER_API_UI_ISSUER_DID=$(DID) >> .env-api.tmp
	mv .env-api.tmp .env-api
	docker logs issuer-initializer-1
	docker rm issuer-initializer-1

.PHONY: add-host-url-swagger
add-host-url-swagger:
	@if [ $(ENVIRONMENT) != "" ] && [ $(ENVIRONMENT) != "local" ]; then \
					sed -i -e  "s#server-url = [^ ]*#server-url = \""${ISSUER_API_UI_SERVER_URL}"\"#g" api_ui/spec.html; \
	fi

.PHONY: rm-issuer-imgs
rm-issuer-imgs: stop
	docker rmi -f issuer-api issuer-ui issuer-api-ui issuer-pending_publisher|| true

.PHONY: restart-ui
restart-ui: rm-issuer-imgs up run run-ui

.PHONY: restart-ui-arm
restart-ui-arm: rm-issuer-imgs up run-arm run-ui-arm

.PHONY: trigon-issuer-env
trigon-issuer-env:
	@echo "Creating .env.trigon-issuer.temp file..."
	@rm -f .env.trigon-issuer.temp
	@touch .env.trigon-issuer.temp

	@for variable in ISSUER_API_AUTH_USER ISSUER_ETHEREUM_URL ISSUER_DATABASE_URL ISSUER_REDIS_URL ISSUER_KEY_STORE_ADDRESS ISSUER_SERVER_URL; do \
		read -p "Enter value for $$variable: " value; \
		echo "$$variable=$$value" >> .env.trigon-issuer.temp; \
		echo "$$variable added to .env.trigon-issuer.temp file."; \
	done

	@while true; do \
		read -s -p "Enter password for ISSUER_API_AUTH_USER: " password; \
		echo; \
		read -p "Confirm password: " password_confirm; \
		echo; \
		if [ "$$password" = "$$password_confirm" ]; then \
			echo "ISSUER_API_AUTH_PASSWORD=$$password" >> .env.trigon-issuer.temp; \
			echo "ISSUER_API_AUTH_PASSWORD added to .env.trigon-issuer.temp file."; \
			break; \
		else \
			echo "Passwords do not match. Please try again."; \
		fi; \
	done

	@echo "Combining values from .env.trigon-issuer.base..."
	@cat .env.trigon-issuer.base >> .env.trigon-issuer.temp
	@echo "Values from .env.trigon-issuer.base combined with user inputs."

	@echo "Renaming .env.trigon-issuer.temp file to .env.trigon-issuer..."
	@mv .env.trigon-issuer.temp .env.trigon-issuer
	@echo ".env.trigon-issuer.temp file renamed to .env.trigon-issuer. Exiting."


# Add the code for generating a did and 
# adding it to the .env.trigon-api.temp file
# After user inputs are done
.PHONY: trigon-api-env
trigon-api-env:
	@echo "Creating .env.trigon-api.temp file..."
	@rm -f .env.trigon-api.temp
	@touch .env.trigon-api.temp

	@for variable in ISSUER_API_UI_AUTH_USER ISSUER_API_UI_SERVER_URL ISSUER_API_UI_SERVER_PORT ISSUER_API_UI_ISSUER_NAME ISSUER_API_UI_ISSUER_LOGO; do \
		read -p "Enter value for $$variable: " value; \
		echo "$$variable=$$value" >> .env.trigon-api.temp; \
		echo "$$variable added to .env.trigon-api.temp file."; \
	done

	@while true; do \
		read -s -p "Enter password for ISSUER_API_UI_AUTH_USER: " password; \
		echo; \
		read -p "Confirm password: " password_confirm; \
		echo; \
		if [ "$$password" = "$$password_confirm" ]; then \
			echo "ISSUER_API_UI_AUTH_PASSWORD=$$password" >> .env.trigon-api.temp; \
			echo "ISSUER_API_UI_AUTH_PASSWORD added to .env.trigon-api.temp file."; \
			break; \
		else \
			echo "Passwords do not match. Please try again."; \
		fi; \
	done


	@echo "Combining values from .env.trigon-api.base..."
	@cat .env.trigon-api.base >> .env.trigon-api.temp
	@echo "Values from .env.trigon-api.base combined with user inputs."

	@echo "Renaming .env.trigon-api.temp file to .env.trigon-api..."
	@mv .env.trigon-api.temp .env.trigon-api.ui
	@echo ".env.trigon-api.temp file renamed to .env.trigon-api. Exiting."


# usage: make private_key=xxx trigon-run
.PHONY: trigon-run
trigon-run:
	@echo "Setting up docker containers for redis postgres vault"
	$(DOCKER_COMPOSE_INFRA_CMD) up -d redis postgres vault

	@echo "Adding vault token"
	$(eval TOKEN = $(shell docker logs issuer-vault-1 2>&1 | grep " .hvs" | awk  '{print $$2}' | tail -1 ))
	sed '/ISSUER_KEY_STORE_TOKEN/d' .env-issuer > .env-issuer.tmp
	@echo ISSUER_KEY_STORE_TOKEN=$(TOKEN) >> .env-issuer.tmp
	mv .env-issuer.tmp .env-issuer

	@echo "Adding privatekey to vault"
	docker exec issuer-vault-1 \
	vault write iden3/import/pbkey key_type=ethereum private_key=$(private_key)

	@echo "Building local"
	$(BUILD_CMD) ./cmd/...

	@echo "Setting up DB"
	$(BIN)/install-goose $(BIN)/godotenv $(BIN)/platformid-migrate ## Install goose and apply migrations.
	$(ENV) sh -c '$(BIN)/migrate'

	@echo "Starting the issuer node"
	$(ENV) sh -c '$(BIN)/platform'

SHELL := /bin/bash
.DEFAULT_GOAL := help

# renovate: datasource=pypi depName=yamllint
YAMLLINT_VERSION ?= 1.38.0
SHELLCHECK_IMAGE ?= docker.io/koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d

.PHONY: help up down stop dev sync smoke wait secrets argocd-password test lint build image

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

up: ## Create the k3d cluster and reconcile envs/local through Argo CD (LOCAL_GIT=1 to use the working tree)
	scripts/up.sh

down: ## Delete the k3d cluster and registry (keeps the local CA in ~/.relay-local)
	scripts/down.sh

stop: ## Stop the cluster but keep it (the next `make up` is a cached start)
	k3d cluster stop relay

dev: up ## Alias for `make up`

sync: ## LOCAL_GIT=1 only: push a working-tree snapshot to the in-cluster git server and refresh Argo CD
	scripts/local-git.sh sync

smoke: ## Check every platform service is healthy and reachable through the Gateway
	scripts/smoke.sh

wait: ## Wait until every Argo CD Application is Synced/Healthy
	scripts/wait-apps.sh

secrets: ## (Re)create missing local secrets in relay-secret-source
	scripts/secrets.sh

argocd-password: ## Print the initial Argo CD admin password
	@kubectl --context k3d-relay -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

test: ## Render every env overlay and Helm Application, validate with kubeconform
	scripts/validate.sh render

lint: ## yamllint, shellcheck, and helm lint --strict on app charts
	pipx run --spec yamllint==$(YAMLLINT_VERSION) yamllint --strict .
	docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt $(SHELLCHECK_IMAGE) -x scripts/*.sh bootstrap/local-git/entrypoint.sh
	scripts/validate.sh lint

build: ## Nothing to build
	@echo "SKIPPED: relay-infra has no build artifacts."

image: ## No image for this repo (the LOCAL_GIT server image is built by `make up`)
	@echo "SKIPPED: relay-infra does not produce a published image."

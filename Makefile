SHELL := /bin/bash
.DEFAULT_GOAL := help

# renovate: datasource=pypi depName=yamllint
YAMLLINT_VERSION ?= 1.38.0
SHELLCHECK_IMAGE ?= docker.io/koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
# renovate: datasource=github-releases depName=golangci/golangci-lint
GOLANGCI_LINT_VERSION ?= 2.14.0
# The S3 conformance target in Docker. Keep the tag equal to the chart in platform/seaweedfs (scripts/s3-conformance.sh checks).
SEAWEEDFS_IMAGE ?= docker.io/chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882

.PHONY: help up down stop dev sync smoke wait secrets argocd-password keycloak-test-users test lint vuln conformance-s3 conformance-s3-cluster build image

help: ## List targets
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-24s %s\n", $$1, $$2}'

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

keycloak-test-users: ## Print the Keycloak test users and the staff TOTP enrolment URI
	@scripts/keycloak.sh test-users

test: ## Render and kubeconform every env overlay and Helm Application; Go unit tests with -race
	scripts/validate.sh render
	go test -race -count=1 ./...

lint: ## yamllint, shellcheck, helm lint --strict on app charts, golangci-lint
	pipx run --spec yamllint==$(YAMLLINT_VERSION) yamllint --strict .
	docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt $(SHELLCHECK_IMAGE) -x scripts/*.sh bootstrap/local-git/entrypoint.sh
	scripts/validate.sh lint
	@golangci-lint version 2>/dev/null | grep -q "version $(GOLANGCI_LINT_VERSION)" || { \
	  echo "golangci-lint $(GOLANGCI_LINT_VERSION) is required (found: $$(golangci-lint version 2>/dev/null || echo none))."; \
	  echo "Install: https://golangci-lint.run/welcome/install/"; exit 1; }
	golangci-lint run ./...

vuln: ## govulncheck (version pinned in go.mod tool directive)
	go tool govulncheck ./...

conformance-s3: ## S3 conformance suite against SeaweedFS in Docker (ARGS="-target=<name>" writes a report)
	SEAWEEDFS_IMAGE=$(SEAWEEDFS_IMAGE) scripts/s3-conformance.sh container $(ARGS)

conformance-s3-cluster: ## S3 conformance suite against the k3d cluster's SeaweedFS (needs make up)
	SEAWEEDFS_IMAGE=$(SEAWEEDFS_IMAGE) scripts/s3-conformance.sh cluster $(ARGS)

build: ## Nothing to build
	@echo "SKIPPED: relay-infra has no build artifacts."

image: ## No image for this repo (the LOCAL_GIT server image is built by `make up`)
	@echo "SKIPPED: relay-infra does not produce a published image."

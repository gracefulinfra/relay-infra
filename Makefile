SHELL := /bin/bash
.DEFAULT_GOAL := help

# renovate: datasource=pypi depName=yamllint
YAMLLINT_VERSION ?= 1.38.0
SHELLCHECK_IMAGE ?= docker.io/koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
# renovate: datasource=github-releases depName=golangci/golangci-lint
GOLANGCI_LINT_VERSION ?= 2.14.0
# The S3 conformance target in Docker. Keep the tag equal to the chart in platform/seaweedfs (scripts/s3-conformance.sh checks).
SEAWEEDFS_IMAGE ?= docker.io/chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882

.PHONY: help up down stop dev dev-smoke dev-env dev-down dev-users sync smoke wait secrets argocd-password keycloak-test-users test lint vuln conformance-s3 conformance-s3-cluster conformance-s3-external portability portability-report portability-down build image

# Environment for up/down/stop/smoke/...: an overlay in envs/ with an env.sh (local, local-b).
RELAY_ENV ?= local
export RELAY_ENV

help: ## List targets
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-24s %s\n", $$1, $$2}'

up: ## Create the k3d cluster and reconcile envs/$RELAY_ENV through Argo CD (LOCAL_GIT=1 to use the working tree)
	scripts/up.sh

down: ## Delete the k3d cluster and registry (keeps the local CA in ~/.relay-local)
	scripts/down.sh

stop: ## Stop the cluster but keep it (the next `make up` is a cached start)
	k3d cluster stop "$$(bash -c 'source scripts/lib.sh && echo $$CLUSTER_NAME')"

dev: ## Compose dev stack: PostgreSQL, S3, Keycloak (PROFILE=observability adds OTel, Tempo, Prometheus, Grafana)
	scripts/dev.sh up $(PROFILE)

dev-smoke: ## Check the Compose dev stack
	scripts/dev-smoke.sh

dev-env: ## Print the dev stack's connection settings, with its local credentials
	@scripts/dev.sh env

dev-down: ## Stop the Compose dev stack (keeps its data; `scripts/dev.sh destroy` removes it)
	scripts/dev.sh down

dev-users: ## Print the dev stack's Keycloak test users and the staff TOTP enrolment URI
	@KEYCLOAK_URL=http://localhost:18180 KEYCLOAK_USERS_ENV="$${RELAY_HOME:-$$HOME/.relay-local}/dev/.env" scripts/keycloak.sh test-users

sync: ## LOCAL_GIT=1 only: push a working-tree snapshot to the in-cluster git server and refresh Argo CD
	scripts/local-git.sh sync

smoke: ## Check every platform service is healthy and reachable through the Gateway
	scripts/smoke.sh

wait: ## Wait until every Argo CD Application is Synced/Healthy
	scripts/wait-apps.sh

secrets: ## (Re)create missing local secrets in relay-secret-source
	scripts/secrets.sh

argocd-password: ## Print the initial Argo CD admin password
	@kubectl --context "k3d-$$(bash -c 'source scripts/lib.sh && echo $$CLUSTER_NAME')" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

keycloak-test-users: ## Print the Keycloak test users and the staff TOTP enrolment URI
	@scripts/keycloak.sh test-users

test: ## Render and kubeconform every env overlay and Helm Application; Go unit tests with -race
	scripts/validate.sh render
	go test -race -count=1 ./...

lint: ## yamllint, shellcheck, helm lint --strict on app charts, golangci-lint
	pipx run --spec yamllint==$(YAMLLINT_VERSION) yamllint --strict .
	docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt $(SHELLCHECK_IMAGE) -x scripts/*.sh scripts/portability/*.sh envs/*/env.sh bootstrap/local-git/entrypoint.sh
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

conformance-s3-external: ## S3 conformance suite against an env's external S3 (RELAY_ENV=local-b; needs scripts/external-s3.sh up)
	SEAWEEDFS_IMAGE=$(SEAWEEDFS_IMAGE) scripts/s3-conformance.sh external $(ARGS)

portability: ## Portability rehearsal FROM=local → TO=local-b: seed, export, restore, verify, report (docs/portability.md)
	SEAWEEDFS_IMAGE=$(SEAWEEDFS_IMAGE) scripts/portability/run.sh

portability-report: ## Re-render the latest portability run's report into docs/portability/runs/
	scripts/portability/report.sh

portability-down: ## Delete the local-b cluster and its external S3 (keeps its CA and credentials in ~/.relay-local/local-b)
	RELAY_ENV=local-b scripts/down.sh
	RELAY_ENV=local-b scripts/external-s3.sh down

build: ## Nothing to build
	@echo "SKIPPED: relay-infra has no build artifacts."

image: ## No image for this repo (the LOCAL_GIT server image is built by `make up`)
	@echo "SKIPPED: relay-infra does not produce a published image."

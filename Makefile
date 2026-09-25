SHELL := /bin/bash
.DEFAULT_GOAL := help

# renovate: datasource=github-releases depName=yannh/kubeconform
KUBECONFORM_VERSION ?= 0.8.0
# renovate: datasource=pypi depName=yamllint
YAMLLINT_VERSION ?= 1.38.0
export KUBECONFORM_VERSION

.PHONY: help dev test lint build image

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

dev: ## Local k3d platform (pending)
	@echo "PENDING: 'make up' and the local k3d platform arrive with P0-05."

test: ## Render every chart and validate the manifests with kubeconform
	scripts/validate.sh render

lint: ## yamllint and helm lint --strict
	pipx run --spec yamllint==$(YAMLLINT_VERSION) yamllint --strict .
	scripts/validate.sh lint

build: ## Nothing to build
	@echo "SKIPPED: relay-infra has no build artifacts."

image: ## No image for this repo
	@echo "SKIPPED: relay-infra does not produce an image."

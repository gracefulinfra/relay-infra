# relay-infra

GitOps for every Relay cluster: platform services, app Helm charts, and per-environment Kustomize overlays reconciled by Argo CD.

Part of **Relay**, a cloud-agnostic podcast network platform built as a portfolio project.
The build is driven by a prompt series; see the prompt index (`prompts/00-INDEX.md` in the planning
workspace) and the architecture decisions in
[relay-contracts/adr](https://github.com/gracefulinfra/relay-contracts/tree/main/adr).

## Status

Bootstrapped by **P0-01**. This repo contains only the CI and tooling skeleton; there is no product code yet.

## Quickstart

Prerequisites: see [relay-contracts/docs/version-matrix.md](https://github.com/gracefulinfra/relay-contracts/blob/main/docs/version-matrix.md).

```bash
git clone https://github.com/gracefulinfra/relay-infra.git
cd relay-infra
make test
make lint
```

| Target | What it does today |
| --- | --- |
| `make test` | Renders every chart and validates it with `kubeconform -strict` against Kubernetes 1.36.4 |
| `make lint` | `yamllint --strict` and `helm lint --strict` |
| `make dev` | Pending: the k3d platform (`make up`) arrives with P0-05 |
| `make build`, `make image` | Skipped: this repo has no build artifacts |

Requires `helm` 4.x, Go (to run the pinned kubeconform), and `pipx` (to run the pinned yamllint).

`charts/relay-smoke` is a bootstrap chart that only exists so the checks have something real to validate.
P0-05 replaces it.

## CI

`.github/workflows/ci.yml` runs the `validate` job (yamllint, helm lint, and kubeconform) on every PR and push.

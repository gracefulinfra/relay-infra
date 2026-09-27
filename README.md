# relay-infra

GitOps for every Relay cluster: platform services, app Helm charts, and per-environment Kustomize overlays reconciled by Argo CD.

Part of **Relay**, a cloud-agnostic podcast network platform built as a portfolio project.
The build is driven by a prompt series; see the prompt index (`prompts/00-INDEX.md` in the planning
workspace) and the architecture decisions in
[relay-contracts/adr](https://github.com/gracefulinfra/relay-contracts/tree/main/adr).

## Quickstart (local k3d platform)

```bash
git clone https://github.com/gracefulinfra/relay-infra.git
cd relay-infra
make up        # k3d cluster + Argo CD + every platform service, reconciled from envs/local
make smoke     # health and Gateway reachability checks
make down      # delete the cluster (the local CA in ~/.relay-local is kept)
```

Then open:

| URL | What | Login |
| --- | --- | --- |
| <https://argocd.relay.localtest.me> | Argo CD | `admin`, password from `make argocd-password` |
| <https://auth.relay.localtest.me/realms/relay-staff/account/> | Keycloak staff realm (TOTP required) | `make keycloak-test-users` prints the user, password, and TOTP enrolment URI |
| <https://auth.relay.localtest.me/admin/> | Keycloak admin console | `relay-secret-source/keycloak-admin` |

Internal services (PostgreSQL, SeaweedFS S3, the Argo Workflows UI) are not routed: use `kubectl port-forward`.
`*.relay.localtest.me` resolves to 127.0.0.1 in public DNS, so there is nothing to add to `/etc/hosts`.

### Prerequisites

| Tool | Notes |
| --- | --- |
| Docker | Docker Desktop needs at least 8 GB of memory (see [docs/laptop-profile.md](docs/laptop-profile.md)). Host ports 80, 443, and 5001 must be free (`make portability` also uses 5002 and 18443) |
| k3d 5.9.x, kubectl, Helm 4.x | Pinned versions: [relay-contracts/docs/version-matrix.md](https://github.com/gracefulinfra/relay-contracts/blob/main/docs/version-matrix.md) |
| Go 1.27 | Installs the pinned `yq`, `kubeconform`, `rclone` and `age` into `.local/bin` on first use, and runs the conformance suites |
| golangci-lint 2.14.0 | `make lint` only |
| `make`, `git`, `curl`, `jq`, `openssl`, `envsubst` (gettext) | `envsubst` ships with `brew install gettext` on macOS |
| `pipx` | `make lint` only (pinned yamllint) |

### Which commit does Argo CD deploy?

Argo CD always reconciles from git, never from your disk:

- **Default:** `https://github.com/gracefulinfra/relay-infra.git` at your current branch if it exists
  on `origin`, otherwise `main`. Override it with `REPO_URL=` and `REVISION=`.
- **`LOCAL_GIT=1 make up`:** an in-cluster git server (`bootstrap/local-git`) serves a snapshot of your
  working tree, including uncommitted and untracked files (it follows `.gitignore`). After editing, run
  `make sync` to push a new snapshot and hard-refresh Argo CD. CI uses this mode.

### Trusting the local CA

`scripts/secrets.sh` creates a local CA once in `~/.relay-local/ca/`, and cert-manager issues the
Gateway's `*.relay.localtest.me` certificate from it. Trust it once to avoid browser warnings:

```bash
# macOS (asks for your password)
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/.relay-local/ca/relay-local-ca.crt
```

```bash
# Debian/Ubuntu
sudo cp ~/.relay-local/ca/relay-local-ca.crt /usr/local/share/ca-certificates/relay-local-ca.crt && sudo update-ca-certificates
```

Firefox keeps its own trust store: Settings → Privacy & Security → Certificates → Import. The CA is
limited to `pathlen:0` and exists only on your machine. To remove it, delete it from the trust store and
`rm -rf ~/.relay-local` (the next `make up` creates a new one).

## Layout

```text
bootstrap/     k3d config, the relay-root app-of-apps template, the LOCAL_GIT git server
platform/      one directory per platform service: an Argo CD Application (Helm chart + valuesObject)
               plus the provider-neutral manifests that configure it
apps/          Relay app charts (from P1-01)
envs/          Kustomize overlays plus env.sh script settings: local (k3d), local-b (the portability
               rehearsal target), provider-a and provider-b (compile-only stubs)
conformance/   test suites a storage or cluster target must pass before Relay uses it (s3/: P0-06)
scripts/       up, down, secrets, local-git, wait-apps, smoke, validate, s3-conformance, external-s3;
               portability/ (seed, export, restore, verify, report, run)
```

How it fits together:

1. `make up` creates the cluster, runs `scripts/secrets.sh`, installs Argo CD with Helm (chart and values
   are read from `platform/argo-cd/application.yaml`), and applies `bootstrap/root-app.yaml`.
2. `relay-root` renders `envs/<env>`, which is every platform Application plus its configuration.
   Sync waves order CRDs before the resources that use them, and Argo CD then adopts its own Helm release.
3. Anything that differs by provider is patched only in `envs/<env>/`. [envs/README.md](envs/README.md)
   lists every knob.
4. Secrets: [ADR-0007](https://github.com/gracefulinfra/relay-contracts/blob/main/adr/0007-secret-management.md).
   External Secrets Operator reads a single `ClusterSecretStore`. Locally, that store is the
   `relay-secret-source` namespace, which `scripts/secrets.sh` fills. Set `GHCR_TOKEN` (`read:packages`)
   before `make up` to get the `ghcr-pull` secret for private images (ADR-0004).

More detail: [docs/platform.md](docs/platform.md).

## Make targets

| Target | What it does |
| --- | --- |
| `make up` / `make dev` | Create (or start) the cluster and wait until every Application is Synced/Healthy. `RELAY_ENV=<env>` picks the overlay and its `envs/<env>/env.sh` (default `local`) |
| `make smoke` | `scripts/smoke.sh`: Argo CD, secrets, TLS, Gateway, S3 privacy, CNPG health and an on-demand backup to S3, Keycloak TOTP login, and an Argo Workflow artifact |
| `make keycloak-test-users` | Print the Keycloak test users and the staff TOTP enrolment URI |
| `make sync` | `LOCAL_GIT=1` only: push a working-tree snapshot and refresh Argo CD |
| `make stop` / `make down` | Stop the cluster and keep it (a cached start), or delete it |
| `make test` | Render every env overlay and every Helm Application in it, then run kubeconform `-strict` with CRD schemas generated from the charts. It also fails if any overlay renders a Secret with data. Then `go test -race ./...` (the conformance harness's unit tests) |
| `make lint` | yamllint, shellcheck, `helm lint --strict` on `apps/*` (skipped until P1-01 adds a chart), and golangci-lint 2.14.0 |
| `make vuln` | govulncheck on the Go module |
| `make conformance-s3` | The [S3 conformance suite](conformance/s3/README.md) against SeaweedFS in Docker. `ARGS="-target=<name>"` writes a report |
| `make conformance-s3-cluster` | The same suite against the k3d cluster's SeaweedFS |
| `make conformance-s3-external` | The same suite against an env's external S3 over TLS (`RELAY_ENV=local-b`) |
| `make portability` | The [portability rehearsal](docs/portability.md): seed `local`, export to `local-b`'s storage, restore `local-b` through GitOps, verify, and write a run report to `docs/portability/runs/` |
| `make portability-down` | Delete the `local-b` cluster and its external S3 |
| `make build`, `make image` | Skipped: no published artifacts |

## CI

`.github/workflows/ci.yml` runs three jobs:

- `validate`: `make lint`, `make test`, and `make vuln`.
- `s3-conformance`: `make conformance-s3`. Any hard-case failure fails the job; the report is in the job
  summary and the `s3-conformance` artifact.
- `e2e`: `LOCAL_GIT=1 scripts/up.sh` and `scripts/smoke.sh` on a fresh `ubuntu-24.04` runner. This is
  the clean-machine run; the job summary records timings and per-pod memory.

`.github/workflows/portability.yml` runs `LOCAL_GIT=1 make portability` on demand (`workflow_dispatch`,
about 30 minutes). The report is the job summary; timings, logs, manifest and inventories are the
artifact (never the age identity or the encrypted bundle).

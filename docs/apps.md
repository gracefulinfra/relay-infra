# Relay apps on the platform

`apps/` holds Relay's own applications: one chart per app plus its Argo CD Application
(`apps/<app>.application.yaml`), in the `apps` AppProject. That project allows charts from this repository only,
namespaced resources only, and the `relay` namespace only.

## relay-api (P1-01)

The chart `apps/relay-api` deploys one image (`ghcr.io/gracefulinfra/relay-api`, pinned by digest) as three workloads:

| Workload | Sync | What |
| --- | --- | --- |
| `ConfigMap`, `ExternalSecret relay-api-db`, ServiceAccounts, NetworkPolicies | wave −2/−3 | Config, and `RELAY_DATABASE_URL` assembled from the CNPG `relay-app` Secret (read cross-namespace by a `SecretStore` whose one permission is `platform/postgres/app-access.yaml`) |
| `Job relay-api-migrate` | `Sync` hook, wave −1 | `relay-migrate up` on every sync. A failure stops the sync before the Deployments roll |
| `Deployment relay-api` (+ `Service`, `HPA` 1–3, `PDB`, `HTTPRoute api.<domain>` for `/v0/` only) | wave 0 | The API. Ops port 9090 (`/healthz`, `/readyz`, `/metrics`) is scraped by Prometheus, never routed |
| `Deployment relay-worker` | wave 0 | River workers |

- **Order.** The migration Job runs after its configuration and before any new pod, on first install and
  on every upgrade. Migrations are expand/contract (relay-contracts ADR 0010), so old pods keep serving
  while the Job and the rollout run.
- **Network.** Default deny. The API accepts `/v0` traffic from the Gateway only. Egress is limited to cluster
  DNS, PostgreSQL (`relay-db`), S3, Keycloak (API only), and the OTel collector. The worker and the Job get
  less (see `templates/networkpolicy.yaml`). Kubernetes API access for the worker arrives with P1-05.
- **Identity.** Separate ServiceAccounts for the API, the worker, and the migrator. None mounts a token.
- **Pods.** Non-root (65532), read-only root filesystem, no capabilities, `RuntimeDefault` seccomp, and
  `GOMEMLIMIT` at 90% of the memory limit.
- **Deploy a new version.** Set `image.digest` in `apps/relay-api.application.yaml` to the digest relay-api CI
  printed for a `main` build (its signature is verified in that job).
- **Operate.** relay-api `docs/runbook.md` covers a failed migration Job, unready pods, and idempotency conflicts.

## Rehearsed on k3d

See the P1-01 PR for the evidence: first install, an upgrade whose migration fails (the sync stops, and the
old pods keep serving), then recovery.

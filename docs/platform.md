# Platform layer

How the platform services are deployed, and how to operate them locally. Introduced by P0-05.

## One pattern for every service

Each `platform/<service>/` directory is a Kustomize base with:

- `application.yaml`: an Argo CD `Application` with a single Helm source. The chart version is pinned
  in `targetRevision`, and all values are inline in `spec.source.helm.valuesObject`. Inline values keep
  `kustomize build envs/<env>` a complete and reviewable description of what gets deployed, and
  env overlays can merge-patch the values.
- Provider-neutral configuration for the service, such as the `Gateway`, `ClusterIssuer`, and
  `ClusterSecretStore`. Env-specific fields hold an obvious placeholder (`relay.example.invalid`, or an
  empty `spec`) that every overlay replaces.

`envs/<env>/kustomization.yaml` lists the bases and patches the provider knobs
([envs/README.md](../envs/README.md)). Argo CD's `relay-root` Application renders that overlay, so there
is one root per cluster, and everything else is a child resource with a sync wave.

## Sync waves

| Wave | What |
| --- | --- |
| -100 | Namespaces (with their labels) and the `platform` AppProject |
| -90 | Controllers with no dependencies: Argo CD itself, External Secrets Operator, Envoy Gateway (which also installs the Gateway API CRDs) |
| -80 | cert-manager (after the Gateway API CRDs, because `enableGatewayAPI` needs them) |
| -70 | Secret-store identity and `ClusterSecretStore/relay-secrets` |
| -60 | `ExternalSecret`s, `ClusterIssuer/relay-issuer`, `GatewayClass`, `EnvoyProxy` |
| -50 | `Gateway/relay` (cert-manager issues the listener certificate) |
| -40 | `HTTPRoute`s |

Argo CD waits for each wave to be Healthy before starting the next. A child Application counts as
Healthy only through the `resource.customizations.health.argoproj.io_Application` check in the Argo CD
values. `relay-root` retries with backoff, which covers webhooks whose Deployment reports ready shortly
before their Service has endpoints.

## Adding a platform service

1. Create `platform/<service>/` with `application.yaml` (pinned chart, `valuesObject` with resource requests
   and limits) and `kustomization.yaml`. If the chart comes from a new source, add it to
   `platform/namespaces/project.yaml`.
2. Declare its namespace in `platform/namespaces/namespaces.yaml`. Add `relay.dev/gateway-access: "true"`
   if the service routes through the Gateway.
3. Get secrets through an `ExternalSecret` that reads `ClusterSecretStore/relay-secrets`, and add the value
   generation to `scripts/secrets.sh`. Never commit a `Secret` with data: `make test` fails if you do.
4. Add the base to every `envs/*/kustomization.yaml`, patch its provider knobs, and document the knobs in
   `envs/README.md`.
5. Add checks to `scripts/smoke.sh`, pin the version in relay-contracts `docs/version-matrix.md`, and
   update [laptop-profile.md](laptop-profile.md) if the memory budget changes.

## Runbook

| Symptom | Cause and fix |
| --- | --- |
| `make up` stops at "Docker is not running", or k3d cannot bind 80/443/5001 | Start Docker Desktop, or free those ports. `lsof -nP -iTCP:443 -sTCP:LISTEN` shows who holds a port. |
| `relay-root` sync errors mention `failed calling webhook ... no endpoints available` | A webhook (cert-manager or ESO) is still starting. `relay-root` retries with backoff; wait. If it lasts more than 5 minutes, check the webhook pod's logs. |
| `external-secrets` shows Progressing for about 2 minutes on a fresh cluster | Expected: the cert-controller generates the webhook certificate, and the kubelet takes up to a minute to project it into the webhook pod. |
| A resource stays OutOfSync right after changing Argo CD settings | The comparison cache is stale: `kubectl -n argocd annotate application relay-root argocd.argoproj.io/refresh=hard --overwrite`. Server-side diff is on (`controller.diff.server.side`), so API-server defaults are not drift. |
| `make sync` changes don't show up | Argo CD only reads the `local` branch of the in-cluster git server. Check `kubectl -n relay-git logs deploy/git-server` for the push, then hard-refresh `relay-root`. |
| Browser warns about the certificate | Trust `~/.relay-local/ca/relay-local-ca.crt` (README). `curl --cacert ~/.relay-local/ca/relay-local-ca.crt` works without trusting it. |
| `ClusterSecretStore relay-secrets` is not Ready | `relay-secret-source` is missing Secrets or the `secret-reader` RBAC: rerun `make secrets`, then `kubectl describe clustersecretstore relay-secrets`. |
| The local CA expired (825 days) or leaked | `rm -rf ~/.relay-local`, then `make down && make up`, and trust the new CA. |

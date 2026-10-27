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
| -90 | Controllers with no dependencies: Argo CD itself, External Secrets Operator, Envoy Gateway (which also installs the Gateway API CRDs), the CloudNativePG operator |
| -80 | cert-manager (after the Gateway API CRDs, because `enableGatewayAPI` needs them) |
| -70 | Secret-store identity and `ClusterSecretStore/relay-secrets` |
| -65 | `EnvoyProxy/relay-proxy` (before the GatewayClass that references it) |
| -60 | `ExternalSecret`s, `ClusterIssuer/relay-issuer`, `GatewayClass`, the CNPG barman-cloud plugin (needs cert-manager) |
| -50 | `Gateway/relay` (cert-manager issues the listener certificate), SeaweedFS (its PostSync hook creates the buckets) |
| -40 | `HTTPRoute`s, CNPG `ObjectStore`s and `Cluster`s (`relay`, `keycloak-db`), Argo Workflows, the Keycloak realm ConfigMap |
| -30 | Keycloak (needs its database), `ScheduledBackup`s, Prometheus, Grafana, Tempo |
| -25 | The OTel Collector (after the backends it exports to) |
| -20 | `HTTPRoute/grafana` (after the Grafana Service exists) |

Argo CD waits for each wave to be Healthy before starting the next. A child Application counts as
Healthy only through the `resource.customizations.health.argoproj.io_Application` check in the Argo CD
values. `relay-root` retries with backoff, which covers webhooks whose Deployment reports ready shortly
before their Service has endpoints.

## Data, identity, and workflows

| Service | Where | Notes |
| --- | --- | --- |
| SeaweedFS | `seaweedfs` | All-in-one pod (master, volume, filer, S3 on :8333), 10 Gi PVC, 768 Mi limit with `GOMEMLIMIT`. S3 auth is on. Buckets `relay-media`, `relay-feeds`, `relay-backups`, and `relay-logs` are all private. One identity per consumer (`cnpg`, `workflows`, `otel`), each limited to its bucket, plus `admin`. Not routed through the Gateway |
| PostgreSQL `relay` | `relay-db` | CNPG 1.30, PostgreSQL 17.11, 1 instance. WAL and base backups go to `s3://relay-backups/cnpg/relay/` through the barman-cloud plugin, with a nightly `ScheduledBackup` and 7-day retention. The app credentials are in `relay-app` |
| PostgreSQL `keycloak-db` | `keycloak` | Keycloak's own cluster, archived to `s3://relay-backups/cnpg/keycloak-db/` |
| Keycloak | `keycloak` | 26.7.4 at `https://auth.<domain>`. Realms are imported from `platform/keycloak/realms/*.json` on first start (existing realms are skipped). `relay-staff` makes TOTP a default required action; `relay-listeners` allows self-registration. Test users: `make keycloak-test-users` |
| Argo Workflows | `relay-media` | Namespace-scoped (`singleNamespace`). Workflows run as `argo-workflow`, and artifacts and logs go to `s3://relay-media/argo-artifacts/`. The server uses `client` auth and is not routed. Parallelism is 1 locally |

On-demand backup of `relay`:

```bash
kubectl -n relay-db apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: {name: manual-backup}
spec: {cluster: {name: relay}, method: plugin, pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}}
EOF
kubectl -n relay-db get backup manual-backup -w
```

## Observability

Everything telemetry goes through one entry point, the OpenTelemetry Collector, so Relay services only
ever speak OTLP (conventions: observability).

```text
Relay services ──OTLP──▶ otel-collector (DaemonSet, :4317 gRPC / :4318 HTTP)
pod stdout/stderr ─filelog─┘      │
                                   ├─ traces  ─▶ Tempo (monolithic, local disk, 24 h)
                                   ├─ metrics ─▶ Prometheus OTLP receiver (2 d or 1 GB)
                                   └─ logs    ─▶ s3://relay-logs/otel/year=/month=/day=/hour=/minute=/*.json.gz
Prometheus also scrapes itself and pods/Services annotated prometheus.io/scrape: "true", minus Envoy Gateway and Tempo.
Grafana (https://grafana.<domain>) reads Prometheus and Tempo.
```

| Service | Where | Notes |
| --- | --- | --- |
| Prometheus | `observability` | The plain `prometheus` chart: one server, **no operator and no CRDs**, 2 d or 1 GB retention on a 2 Gi PVC, OTLP receiver on. It scrapes itself and anything annotated `prometheus.io/scrape: "true"` (relay-api and relay-worker on their ops port, cert-manager), except Envoy Gateway and Tempo, which are dropped by relabelling to fit the laptop profile. OTLP metrics arrive through the collector. **Alertmanager is off** until P1-18 defines alert routing. Not routed |
| Grafana | `observability` | `https://grafana.<domain>`. The login is in `relay-secret-source/grafana-admin` (generated; never a chart default). Two provisioned datasources, Prometheus (`uid: prometheus`) and Tempo (`uid: tempo`), with no bundled dashboards and Grafana alerting off. No persistence |
| Tempo | `observability` | Tempo 3 monolithic (no Kafka), OTLP only, 24 h retention on a 4 Gi PVC. Not routed; query it through Grafana |
| OTel Collector | `observability` | contrib image (the `awss3` exporter), one pod per node. Pods send OTLP to `otel-collector.observability.svc:4317/4318` (`internalTrafficPolicy: Local`). The `filelog` receiver reads `/var/log/pods`, which needs uid 0: every capability is dropped and the root filesystem is read-only. Logs are batched (30 s or 5,000 records) into gzipped OTLP JSON objects in `relay-logs` with the `otel` identity, which can write only that bucket |

Read logs back out of object storage (they survive the cluster, and the portability rehearsal copies them):

```bash
secret() { kubectl --context k3d-relay -n relay-secret-source get secret s3-admin -o jsonpath="{.data.$1}" | base64 -d; }
kubectl --context k3d-relay -n seaweedfs exec deploy/seaweedfs-all-in-one -- curl -s \
  --aws-sigv4 aws:amz:us-east-1:s3 --user "$(secret access_key_id):$(secret secret_access_key)" \
  "http://localhost:8333/relay-logs?list-type=2&prefix=otel/"
```

Each object is gzipped OTLP JSON: download one the same way and pipe it through `gunzip | jq`.

### Why not kube-prometheus-stack

It was deployed first in this PR and removed. Its operator CRDs are several MB each, and reconciling
them OOM-killed the Argo CD application controller at 768 Mi. Together with the operator, kube-state-metrics,
node-exporter, and its rule set, it pushed the 7.75 GiB node into memory pressure: pods were
evicted, and the controller could no longer sync the fix. The plain chart gives the same OTLP-first
metrics path at a fraction of the size. Revisit it only for a real cluster with memory to spare.

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
| `GatewayClass relay` stays `Accepted=False, InvalidParameters` | It was created before `EnvoyProxy/relay-proxy` (wave -65 prevents this). Nudge it: `kubectl annotate gatewayclass relay relay.dev/reconcile=$(date +%s) --overwrite`. |
| `external-secrets` shows Progressing for about 2 minutes on a fresh cluster | Expected: the cert-controller generates the webhook certificate, and the kubelet takes up to a minute to project it into the webhook pod. |
| A resource stays OutOfSync right after changing Argo CD settings | The comparison cache is stale: `kubectl -n argocd annotate application relay-root argocd.argoproj.io/refresh=hard --overwrite`. Server-side diff is on (`controller.diff.server.side`), so API-server defaults are not drift. |
| `make sync` changes don't show up | Argo CD only reads the `local` branch of the in-cluster git server. Check `kubectl -n relay-git logs deploy/git-server` for the push, then hard-refresh `relay-root`. |
| Browser warns about the certificate | Trust `~/.relay-local/ca/relay-local-ca.crt` (README). `curl --cacert ~/.relay-local/ca/relay-local-ca.crt` works without trusting it. |
| `ClusterSecretStore relay-secrets` is not Ready | `relay-secret-source` is missing Secrets or the `secret-reader` RBAC: rerun `make secrets`, then `kubectl describe clustersecretstore relay-secrets`. |
| A `Backup` stays `running` or fails, or `ContinuousArchiving` is False | Check the plugin sidecar with `kubectl -n relay-db logs relay-1 -c plugin-barman-cloud`, and `kubectl -n cnpg-system logs deploy/barman-cloud-plugin-barman-cloud`. The usual causes are the `s3-backup` Secret not synced yet, or the S3 identity lacking rights on `relay-backups` (see `seaweedfs-s3-config`). |
| Keycloak realm JSON changes are not applied | Import skips realms that already exist. Locally, `make down && make up`; otherwise use the admin console or API. The admin credentials are in `relay-secret-source/keycloak-admin`. |
| `keycloak.sh login-staff` fails with "did not return an authorization code" | The code is time-based: check that the host clock is in sync. Keycloak also rejects a reused code, and the script waits for the next 30 s step when needed. Repeated failures can trigger brute-force lockout (10 failures); a successful login resets the count. |
| `make conformance-s3` (or the CI `s3-conformance` job) fails | A hard S3 case failed: storage no longer behaves the way Relay needs. Read the case's sanitized trace in the `go test -v` output (or the `s3-conformance` artifact) and the report's observations. Do not merge a SeaweedFS or storage change until it passes; see [conformance/s3/README.md](../conformance/s3/README.md). "SEAWEEDFS_IMAGE tag ... does not match" means the `Makefile` image and the chart in `platform/seaweedfs` were bumped separately: update them together. |
| A smoke workflow never finishes | `kubectl -n relay-media get wf`, then `kubectl -n relay-media logs deploy/argo-workflows-workflow-controller`. Parallelism is 1, so a stuck workflow blocks the queue: delete it. |
| The local CA expired (825 days) or leaked | `rm -rf ~/.relay-local`, then `make down && make up`, and trust the new CA. |
| Grafana login fails, or it shows the chart's default password prompt | `relay-secret-source/grafana-admin` missing when Grafana first started: `make secrets`, then `kubectl -n observability rollout restart deploy/grafana`. |
| Smoke "every Prometheus scrape target is up" fails | `up == 0` names the job and pod. Check the pod's `prometheus.io/port` and `prometheus.io/path` annotations, then the pod itself. |
| No new objects under `s3://relay-logs/otel/` | `kubectl -n observability logs ds/otel-collector`: `AccessDenied` means the `otel` identity or `otel-s3` Secret is wrong (`make secrets`); a TLS error on an external endpoint means the `s3-ca` Secret is missing. Objects appear up to 30 s after the logs, because of batching. |
| Traces sent but not in Tempo | Check the collector for `otlp_grpc/tempo` export errors, then `kubectl -n observability logs sts/tempo`. Tempo keeps 24 h only. |

# Dev stack (Docker Compose)

`make dev` starts the backing services that Relay apps need for everyday work, in Docker Compose, in
about 15 seconds once the images are pulled. It is the inner loop. The k3d platform (`make up`) is
still the environment for GitOps, Argo Workflows, the portability rehearsal, and every phase gate,
because those need Kubernetes ([ADR 0009](https://github.com/gracefulinfra/relay-contracts/blob/main/adr/0009-compose-dev-stack.md)).

```bash
make dev                         # PostgreSQL, S3 (SeaweedFS), Keycloak
make dev PROFILE=observability   # plus the OTel Collector, Tempo, Prometheus, Grafana
make dev-smoke                   # check it
make dev-env                     # connection settings, with the local credentials
make dev-users                   # Keycloak test users and the staff TOTP enrolment URI
make dev-down                    # stop; data volumes are kept
scripts/dev.sh destroy           # stop and delete the data volumes
```

## What matches the platform

| Service | Dev stack | Platform (k3d) | Same |
| --- | --- | --- | --- |
| PostgreSQL | `postgres:17.11` on `127.0.0.1:15432`, databases `relay` and `keycloak` | CNPG, PostgreSQL 17.11 | Major and minor version, database names |
| S3 | SeaweedFS 4.47 on `http://127.0.0.1:18333` (path-style) | SeaweedFS 4.47 in-cluster | Image, the four private buckets, the per-consumer identities (`admin`, `cnpg`, `workflows`, `otel`) and their bucket scopes (`scripts/lib.sh` `S3_IDENTITIES`) |
| Keycloak | 26.7.4 `start-dev` on `http://localhost:18180` | 26.7.4 at `https://auth.<domain>` | Image and **the same realm files** (`platform/keycloak/realms`), so `relay-staff` requires TOTP here too |
| OTel Collector | contrib 0.160.0 on `127.0.0.1:4317/4318` | contrib 0.160.0 DaemonSet | Image and routing: traces to Tempo, metrics to Prometheus's OTLP receiver, logs to `s3://relay-logs/otel/` as the `otel` identity |
| Tempo, Prometheus, Grafana | Tempo 3.0.3, Prometheus v3.15.0, Grafana 13.2.2 on `http://localhost:13000` | The same versions | Datasource uids `prometheus` and `tempo` |

The dev smoke test checks the same guarantees as the platform smoke test for these services: S3
privacy and identity scopes, the Keycloak password + TOTP login, and the three OTLP paths.

## What differs (by design)

- **No Kubernetes**: no Argo CD, Argo Workflows, CNPG backups, Envoy Gateway, cert-manager, or ESO.
  Anything that needs those is tested on k3d.
- **Plain HTTP on localhost**, no TLS or Gateway. Keycloak runs `start-dev`.
- **No pod log collection**: apps send their logs over OTLP (conventions: structured logs through the
  collector). The platform's `filelog` receiver has no Compose equivalent.
- **Secrets** are generated once by `scripts/dev.sh` into `~/.relay-local/dev/.env` (mode 600), never in
  the repository and never rotated automatically, because the data volumes depend on them.
  `scripts/dev.sh destroy` plus deleting that file starts over.

## Resources

About 0.7 GiB for the core services and 1.2 GiB with the observability profile, measured with
`docker stats` ([laptop-profile.md](laptop-profile.md)). Stop the k3d cluster (`make stop`) before
starting the dev stack on the reference laptop: both at once do not fit the 7.75 GiB Docker VM.

## Runbook

| Symptom | Cause and fix |
| --- | --- |
| `make dev` fails with "port is already allocated" | Another process holds 15432, 18333, 18180, 4317, 4318, 13000, or 19090. `lsof -nP -iTCP:<port> -sTCP:LISTEN` shows it. |
| Keycloak stays `starting` | First start imports the realms and takes about 30 s. `docker compose -p relay-dev logs keycloak`. |
| S3 returns `InvalidAccessKeyId` | The IAM config is built from `~/.relay-local/dev/.env` at `make dev`. Rerun `make dev` to recreate the container with it. |
| SeaweedFS exits with `permission denied` on its config | It must receive the config through `seaweedfs.env`, not a bind mount (see `SEAWEEDFS_ENTRYPOINT` in `scripts/lib.sh`). |

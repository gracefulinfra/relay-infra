# Laptop profile

The local platform is sized for a **16 GB laptop whose Docker Desktop VM has about 8 GB** (owner
decision, P0-05). Every platform chart runs a single replica with explicit requests and limits, short
retention, and heavy jobs run one at a time. This file holds the measured numbers. Update it whenever a
platform service is added or resized.

## Reference machine

| | |
| --- | --- |
| Host | Apple Silicon Mac, 10 CPUs, 16 GB RAM, macOS 27 |
| Docker Desktop VM | 10 CPUs, 7.75 GiB memory |
| Cluster | k3d 5.9.0, one k3s v1.36.4 server node, no agents |

## Measurements

Measured with `kubectl top` and `docker stats` once `make smoke` passed. "Node anon" is the anonymous
(non-page-cache) memory of the k3s node container's cgroup: all pods plus k3s itself.

| Stage | Pods (sum) | Node anon | Largest pods |
| --- | --- | --- | --- |
| P0-05 PR1: Argo CD, ESO, cert-manager, Envoy Gateway | ≈1.1 GiB | ≈2.1 GiB | argocd-application-controller 400–610 Mi, argocd-repo-server ≈100 Mi |
| P0-05 PR2: + CNPG ×2, SeaweedFS, Keycloak, Argo Workflows | ≈2.3 GiB | ≈4.4 GiB | keycloak ≈630 Mi, argocd-application-controller ≈530 Mi, each PostgreSQL instance ≈110–130 Mi, seaweedfs ≈100 Mi |
| P0-05 PR3: + Prometheus, Grafana, OTel Collector, Tempo | ≈2.9 GiB | ≈4.55 GiB (of 7.75) | observability ≈690 Mi in total: prometheus-server ≈340 Mi, grafana ≈225 Mi, otel-collector ≈75 Mi, tempo ≈50 Mi |

P0-05 PR3: kube-prometheus-stack was tried first and **did not fit**. Reconciling its CRDs OOM-killed
the Argo CD application controller at 768 Mi, in a loop, and the operator, exporters, and rules pushed
the node to about 6 GiB, where it was briefly NotReady and pods were evicted. The plain Prometheus chart
(server only, no CRDs) replaced it ([platform.md](platform.md#why-not-kube-prometheus-stack)). Grafana 13
needs about 300 Mi to start: at a 256 Mi limit it never started listening, so it has a 400 Mi limit with
`GOMEMLIMIT=340MiB`. Prometheus 3 sets its own Go memory limit from the container limit (384 Mi).

P0-07: SeaweedFS was OOM-killed at its 512 Mi limit while the portability seed wrote 1 GiB (64 × 16 MiB
objects, four at a time). Go's garbage collector does not see the cgroup limit, so the limit is now
768 Mi with `GOMEMLIMIT=560MiB`. The `local-b` cluster runs no SeaweedFS (its S3 is the external
container), and the laptop fits one platform at a time, so the portability rehearsal stops `relay`
before it starts `relay-b`.

## Start-up timings

The target is ≤ 10 minutes for `make up` on this machine. It's a benchmark, not a gate.

| Stage | Cold start | Cached start |
| --- | --- | --- |
| P0-05 PR3 | **4m 46s** fresh cluster (`make down`, then `LOCAL_GIT=1 make up`; the k3s image and `.local/` tools were cached, and container images were pulled again); platform sync 3m 36s | not re-measured |
| P0-05 PR2 | **4m 56s** (same procedure; platform sync 3m 47s, about 100 s of it ESO bootstrapping its webhook certificate) | **55s** |
| P0-05 PR1 | **2m 45s** (`make down`, k3s image and `.local/` tools deleted; container images pulled from the internet) | **41s** (`make stop` → `make up`) |

- **Cold start**: `make down`, remove the k3s image from Docker and delete `.local/` (tool binaries and
  chart cache), then `LOCAL_GIT=1 make up`. Every container image is pulled.
- **Cached start**: `make stop`, then `make up`. The node keeps its images and volumes, and the time is
  mostly k3s restarting plus Argo CD re-reconciling.
- Timings come from the phase table that `scripts/up.sh` prints. The raw logs are attached to the PR.

Cached starts were 4m 39s until the ESO cert-controller's CRD requeue interval dropped from 5m to 30s:
its readiness waits for that loop, and `external-secrets` gated the whole platform.

## Serial heavy jobs

Heavy media jobs (Argo Workflows, from P1-05) run one at a time locally: the workflow controller's
parallelism is set to 1 in `envs/local`.

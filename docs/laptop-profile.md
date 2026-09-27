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
| P0-05 PR2: + CNPG ×2, SeaweedFS, Keycloak, Argo Workflows | _pending_ | _pending_ | |
| P0-05 PR3: + Prometheus, Grafana, OTel Collector, Tempo | _pending_ | _pending_ | |

## Start-up timings

The target is ≤ 10 minutes for `make up` on this machine. It's a benchmark, not a gate.

| Stage | Cold start | Cached start |
| --- | --- | --- |
| P0-05 PR1 | **2m 45s** (`make down`, k3s image and `.local/` tools deleted; container images pulled from the internet) | **41s** (`make stop` → `make up`) |

- **Cold start**: `make down`, remove the k3s image from Docker and delete `.local/` (tool binaries and
  chart cache), then `LOCAL_GIT=1 make up`. Every container image is pulled.
- **Cached start**: `make stop`, then `make up`. The node keeps its images and volumes, and the time is
  mostly k3s restarting plus Argo CD re-reconciling.
- Timings come from the phase table that `scripts/up.sh` prints. The raw logs are attached to the PR.

## Serial heavy jobs

Heavy media jobs (Argo Workflows, from P1-05) run one at a time locally: the workflow controller's
parallelism is set to 1 in `envs/local` (P0-05 PR2).

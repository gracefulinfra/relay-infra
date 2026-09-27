# Follow-ups

Out-of-scope work noticed while implementing a slice. Add an entry instead of doing the work.
Format: `- [ ] (<prompt that found it>) <what> — <why it matters>`.

- [x] (P0-01) Validate Kustomize overlays and CRD-based resources (with the datreeio CRDs-catalog or generated schemas) in `scripts/validate.sh`. Replace `charts/relay-smoke`. Done in P0-05: schemas are generated from the charts' own CRDs, and `charts/relay-smoke` is removed.
- [ ] (P0-01) Enforce image signatures at admission (for example a Kyverno or sigstore policy-controller policy checking the cosign identity in relay-contracts/docs/ci.md). Owner: P1-19.
- [ ] (P0-01) Run actionlint (with shellcheck) in CI. It currently runs only locally. Candidate: a shared reusable workflow. Owner: P1-19 or earlier.
- [x] (P0-01) GHCR images are private (relay-contracts ADR-0004). Have the local secrets script create an `imagePullSecret` for ghcr.io from a `read:packages` token. Done in P0-05: `GHCR_TOKEN` → `ClusterExternalSecret/ghcr-pull` into namespaces labelled `relay.dev/ghcr-pull=true`.
- [ ] (P0-05) Label each app namespace `relay.dev/ghcr-pull=true` and set `imagePullSecrets: [{name: ghcr-pull}]` in every app chart. Owner: P1-01 (first app chart).
- [ ] (P0-05) Tighten the `platform` AppProject: per-service destination namespaces and a cluster-resource allow-list instead of `*`. Owner: P1-19.
- [ ] (P0-05) The Argo CD `admin` user and the Argo CD UI route are for local use only. Wire Argo CD SSO to Keycloak `relay-staff` and disable `admin` outside `local`. Owner: P1-02 / P1-19.
- [ ] (P0-05) Speed up `make up` after `make down` with a pull-through registry cache (k3d `registries.create.proxy` for docker.io, quay.io, ghcr.io, registry.k8s.io). Today only `make stop` → `make up` reuses images.
- [ ] (P0-05) Envoy Gateway was pinned to 1.9.1 rather than the 1.8.x baseline in `01-CONVENTIONS.md`, because 1.9.x is the current minor. Update the conventions baseline table.
- [ ] (P0-05) Run SeaweedFS as non-root with a read-only root filesystem (the upstream image runs as root). Owner: P1-19.
- [ ] (P0-05) Pin third-party chart images by digest (charts pin them by tag through the chart version), or enforce it at admission. Owner: P1-19.
- [ ] (P0-05) Add NetworkPolicies for the platform data plane (SeaweedFS, CNPG clusters, the Argo Workflows controller). Include the CNPG operator's instance-manager port and DNS. Keycloak and the local git server already have one. Owner: P1-19.
- [ ] (P0-05) Remove the Keycloak test users from any non-local environment (realm JSON `users` and `ExternalSecret/keycloak-test-users`). Owner: P0-07.
- [ ] (P0-05) Replace realm import (which skips realms that already exist) with declarative realm management (keycloak-config-cli or the admin API) so realm changes reconcile through GitOps. Owner: P1-02.

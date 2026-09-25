# Follow-ups

Out-of-scope work noticed while implementing a slice. Add an entry instead of doing the work.
Format: `- [ ] (<prompt that found it>) <what> — <why it matters>`.

- [ ] (P0-01) Validate Kustomize overlays and CRD-based resources (with the datreeio CRDs-catalog or generated schemas) in `scripts/validate.sh`. Replace `charts/relay-smoke`. Owner: P0-05.
- [ ] (P0-01) Enforce image signatures at admission (for example a Kyverno or sigstore policy-controller policy checking the cosign identity in relay-contracts/docs/ci.md). Owner: P1-19.
- [ ] (P0-01) Run actionlint (with shellcheck) in CI. It currently runs only locally. Candidate: a shared reusable workflow. Owner: P1-19 or earlier.
- [ ] (P0-01) GHCR images are private (relay-contracts ADR-0004). Have the local secrets script create an `imagePullSecret` for ghcr.io from a `read:packages` token, and wire it into every app chart. Owner: P0-05.

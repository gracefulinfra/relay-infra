#!/usr/bin/env bash
# Generates local secrets into the relay-secret-source namespace, where External Secrets Operator reads
# them (ClusterSecretStore relay-secrets, envs/local). Nothing here is ever committed.
#
# Idempotent: an existing Secret keeps its value, so re-running never rotates credentials by accident.
# Values that must outlive the cluster (the local CA you trust once) are kept in $RELAY_HOME.
#
# Optional input:
#   GHCR_TOKEN   a GitHub token with read:packages; creates the ghcr-pull source secret (ADR-0004).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require kubectl openssl

NS=relay-secret-source

kc get namespace "$NS" >/dev/null 2>&1 || kc create namespace "$NS" >/dev/null
kc label namespace "$NS" relay.dev/purpose=secret-source --overwrite >/dev/null

exists() { kc -n "$NS" get secret "$1" >/dev/null 2>&1; }

# put_literal <name> key=value...: creates a generic Secret from literals unless it already exists.
put_literal() {
  local name=$1
  shift
  if exists "$name"; then return 0; fi
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kc -n "$NS" create secret generic "$name" "${args[@]}" >/dev/null
  log "created secret $NS/$name"
}

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

# --- Local CA (cert-manager ClusterIssuer relay-issuer) ---------------------------------------------
ca_dir="$RELAY_HOME/ca"
if [ ! -s "$ca_dir/relay-local-ca.key" ]; then
  mkdir -p "$ca_dir"
  chmod 700 "$RELAY_HOME" "$ca_dir"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 \
    -subj "/O=Relay local development/CN=Relay Local CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$ca_dir/relay-local-ca.key" -out "$ca_dir/relay-local-ca.crt" 2>/dev/null
  chmod 600 "$ca_dir/relay-local-ca.key"
  log "generated local CA in $ca_dir (trust it once: see README 'Trusting the local CA')"
fi
if ! exists relay-local-ca; then
  kc -n "$NS" create secret generic relay-local-ca \
    --from-file=tls.crt="$ca_dir/relay-local-ca.crt" --from-file=tls.key="$ca_dir/relay-local-ca.key" >/dev/null
  log "created secret $NS/relay-local-ca"
fi

# --- GHCR pull secret (optional) ---------------------------------------------------------------------
if [ -n "${GHCR_TOKEN:-}" ] && ! exists ghcr-pull; then
  kc -n "$NS" create secret docker-registry ghcr-pull --docker-server=ghcr.io \
    --docker-username="${GHCR_USER:-relay}" --docker-password="$GHCR_TOKEN" >/dev/null
  log "created secret $NS/ghcr-pull"
elif ! exists ghcr-pull; then
  log "skipped ghcr-pull: set GHCR_TOKEN (read:packages) to pull private relay images"
fi

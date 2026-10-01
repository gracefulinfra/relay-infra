#!/usr/bin/env bash
# Generates local secrets into the relay-secret-source namespace, where External Secrets Operator reads
# them (ClusterSecretStore relay-secrets, envs/local). Nothing here is ever committed.
#
# Idempotent: an existing Secret keeps its value, so re-running never rotates credentials by accident.
# Values that must outlive the cluster (the local CA you trust once) are kept in $RELAY_HOME.
#
# S3 depends on S3_MODE (envs/<env>/env.sh): `in-cluster` generates the identities and the SeaweedFS IAM
# config; `external` copies the identities and CA of the external endpoint (scripts/external-s3.sh).
#
# Optional input:
#   GHCR_TOKEN   a GitHub token with read:packages; creates the ghcr-pull source secret (ADR-0004). Required.
#   RELAY_SECRETS_BUNDLE  an age-encrypted bundle written by scripts/portability/export.sh. Its Secrets
#                are imported first and replace existing ones, so carried values win over generated ones.
#   RELAY_AGE_KEY  the age identity that decrypts the bundle (default $RELAY_HOME/portability/age.key).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require kubectl openssl jq

NS=relay-secret-source

kc get namespace "$NS" >/dev/null 2>&1 || kc create namespace "$NS" >/dev/null
kc label namespace "$NS" relay.dev/purpose=secret-source --overwrite >/dev/null

exists() { kc -n "$NS" get secret "$1" >/dev/null 2>&1; }

# --- Carried secrets (portability restore) ----------------------------------------------------------
# The bundle is {"<secret name>": {"<key>": "<value>"}}; values never touch the disk unencrypted.
if [ -n "${RELAY_SECRETS_BUNDLE:-}" ]; then
  age_key=${RELAY_AGE_KEY:-$RELAY_HOME/portability/age.key}
  [ -s "$age_key" ] || die "no age identity at $age_key to decrypt $RELAY_SECRETS_BUNDLE"
  bundle=$(age -d -i "$age_key" "$RELAY_SECRETS_BUNDLE") || die "cannot decrypt $RELAY_SECRETS_BUNDLE"
  for name in $(jq -r 'keys[]' <<<"$bundle"); do
    jq --arg ns "$NS" --arg n "$name" '{apiVersion: "v1", kind: "Secret", type: "Opaque",
        metadata: {name: $n, namespace: $ns, labels: {"relay.dev/carried": "true"}},
        data: (.[$n] | map_values(@base64))}' <<<"$bundle" | kc apply -f - >/dev/null
    log "imported carried secret $NS/$name"
  done
  unset bundle
fi

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


# --- Local CA (cert-manager ClusterIssuer relay-issuer) ---------------------------------------------
ca_dir=${CA_DIR:?envs/$RELAY_ENV/env.sh sets no CA_DIR}
if [ ! -s "$ca_dir/relay-local-ca.key" ]; then
  mkdir -p "$ca_dir"
  chmod 700 "$RELAY_HOME" "$(dirname "$ca_dir")" "$ca_dir"
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

# --- S3 ---------------------------------------------------------------------------------------------
case ${S3_MODE:-in-cluster} in
in-cluster)
  for entry in "${S3_IDENTITIES[@]}"; do
    name=${entry%%|*}
    put_literal "s3-$name" "access_key_id=relay-$name-$(rand 12)" "secret_access_key=$(rand 40)"
  done
  # SeaweedFS IAM config, rebuilt from the identity Secrets above so it always matches them.
  s3_config=$(for entry in "${S3_IDENTITIES[@]}"; do
    name=${entry%%|*}
    kc -n "$NS" get secret "s3-$name" -o json | jq --arg n "$name" '{($n): (.data | map_values(@base64d))}'
  done | jq -s add | seaweedfs_iam_config)
  kc -n "$NS" create secret generic seaweedfs-s3-config --from-literal=seaweedfs_s3_config="$s3_config" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  ;;
external)
  # The endpoint's identities are the source of truth; the Secrets follow them.
  identities="${S3_STATE_DIR:?}/identities.json"
  [ -s "$identities" ] && [ -s "${S3_CA_FILE:?}" ] || die "no external S3 state in $S3_STATE_DIR: run scripts/external-s3.sh up"
  for entry in "${S3_IDENTITIES[@]}"; do
    name=${entry%%|*}
    jq -r --arg n "$name" '.[$n] | "access_key_id=\(.access_key_id)\nsecret_access_key=\(.secret_access_key)"' "$identities" |
      kc -n "$NS" create secret generic "s3-$name" --from-env-file=/dev/stdin --dry-run=client -o yaml | kc apply -f - >/dev/null
  done
  kc -n "$NS" create secret generic s3-ca --from-file=ca.crt="$S3_CA_FILE" --dry-run=client -o yaml | kc apply -f - >/dev/null
  ;;
*) die "unknown S3_MODE '$S3_MODE'" ;;
esac

# --- Keycloak ---------------------------------------------------------------------------------------
put_literal keycloak-admin "username=relay-admin" "password=$(rand 32)"
# Test users imported into the realms. The staff user has TOTP pre-enrolled: Keycloak stores the raw
# secret; authenticator apps get its base32 form (make keycloak-test-users prints the otpauth URI).
put_literal keycloak-test-users \
  "staff_username=staff.test" "staff_password=$(rand 24)" "staff_totp_secret=$(rand 20)" \
  "listener_username=listener.test" "listener_password=$(rand 24)"

# --- Grafana -----------------------------------------------------------------------------------------
put_literal grafana-admin "admin-user=relay-admin" "admin-password=$(rand 32)"

# --- GHCR pull secret ---------------------------------------------------------------------------------
# Required since P1-01: relay-api's image is private (ADR 0004). Any token with read:packages works, for
# example `gh auth refresh -s read:packages` then GHCR_TOKEN=$(gh auth token). CI uses GITHUB_TOKEN.
if [ -n "${GHCR_TOKEN:-}" ] && ! exists ghcr-pull; then
  kc -n "$NS" create secret docker-registry ghcr-pull --docker-server=ghcr.io \
    --docker-username="${GHCR_USER:-relay}" --docker-password="$GHCR_TOKEN" >/dev/null
  log "created secret $NS/ghcr-pull"
elif ! exists ghcr-pull; then
  die "GHCR_TOKEN is not set: relay-api's image is private. Run \`gh auth refresh -s read:packages\`, then GHCR_TOKEN=\$(gh auth token) make up"
fi

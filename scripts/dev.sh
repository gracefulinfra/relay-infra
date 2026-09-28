#!/usr/bin/env bash
# The Compose dev stack (compose/compose.yaml, ADR 0009): the backing services for app work, without
# Kubernetes. k3d (`make up`) stays the environment for GitOps, Argo Workflows, and the gates.
#
#   scripts/dev.sh up [observability]   generate secrets once, then start (and wait for) the stack
#   scripts/dev.sh down                 stop and remove the containers; keep the data volumes
#   scripts/dev.sh destroy              also delete the data volumes
#   scripts/dev.sh endpoints            print where each service listens (no secrets)
#   scripts/dev.sh env                  print connection settings with credentials (local dev values only)
#
# Secrets live in $RELAY_HOME/dev/.env (mode 600), never in the repository.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker openssl jq

DEV_DIR="$RELAY_HOME/dev"
ENV_FILE="$DEV_DIR/.env"
compose() { docker compose --project-directory "$REPO_ROOT/compose" -f "$REPO_ROOT/compose/compose.yaml" --env-file "$ENV_FILE" "$@"; }

# secrets: writes the .env once. Rerunning never rotates values the data volumes already depend on.
secrets() {
  mkdir -p "$DEV_DIR"
  chmod 700 "$DEV_DIR"
  if [ ! -s "$ENV_FILE" ]; then
    umask 077
    {
      echo "RELAY_DEV_DIR=$DEV_DIR"
      echo "POSTGRES_PASSWORD=$(rand 32)"
      echo "RELAY_DB_PASSWORD=$(rand 32)"
      echo "KEYCLOAK_DB_PASSWORD=$(rand 32)"
      echo "KEYCLOAK_ADMIN_PASSWORD=$(rand 32)"
      echo "GRAFANA_ADMIN_PASSWORD=$(rand 32)"
      echo "RELAY_STAFF_USERNAME=staff.test"
      echo "RELAY_STAFF_PASSWORD=$(rand 24)"
      echo "RELAY_STAFF_TOTP_SECRET=$(rand 20)"
      echo "RELAY_LISTENER_USERNAME=listener.test"
      echo "RELAY_LISTENER_PASSWORD=$(rand 24)"
      for entry in "${S3_IDENTITIES[@]}"; do
        name=$(tr '[:lower:]' '[:upper:]' <<<"${entry%%|*}")
        echo "S3_${name}_ACCESS_KEY_ID=relay-${entry%%|*}-$(rand 12)"
        echo "S3_${name}_SECRET_ACCESS_KEY=$(rand 40)"
      done
    } >"$ENV_FILE"
    log "generated dev secrets in $ENV_FILE"
  fi
  # The SeaweedFS IAM config: the same per-consumer identities and bucket scopes as the platform.
  # shellcheck disable=SC1090
  (set -a && source "$ENV_FILE" && for entry in "${S3_IDENTITIES[@]}"; do
    n=${entry%%|*} N=$(tr '[:lower:]' '[:upper:]' <<<"${entry%%|*}")
    k="S3_${N}_ACCESS_KEY_ID" s="S3_${N}_SECRET_ACCESS_KEY"
    jq -n --arg n "$n" --arg k "${!k}" --arg s "${!s}" '{($n): {access_key_id: $k, secret_access_key: $s}}'
  done) | jq -s add | seaweedfs_iam_config >"$DEV_DIR/s3.json"
  chmod 600 "$DEV_DIR/s3.json"
  seaweedfs_env_file "$DEV_DIR/seaweedfs.env" "$DEV_DIR/s3.json"
}

case ${1:-up} in
up)
  secrets
  profile=()
  [ "${2:-}" = observability ] && profile=(--profile observability)
  started=$SECONDS
  compose "${profile[@]}" up -d --wait --wait-timeout 300
  log "dev stack ready in $((SECONDS - started))s"
  "$0" endpoints
  ;;
endpoints)
  cat <<TXT
  PostgreSQL   127.0.0.1:15432   databases relay, keycloak
  S3           http://127.0.0.1:18333 (path-style)   buckets relay-media, relay-feeds, relay-backups, relay-logs
  Keycloak     http://localhost:18180   realms relay-staff (TOTP), relay-listeners
  OTLP         127.0.0.1:4317 (gRPC), http://127.0.0.1:4318   (PROFILE=observability)
  Grafana      http://localhost:13000   (PROFILE=observability)
  Credentials: make dev-env    Test users: make dev-users    Check: make dev-smoke
TXT
  ;;
down) compose --profile observability down ;;
destroy) compose --profile observability down -v && rm -f "$DEV_DIR/s3.json" "$DEV_DIR/seaweedfs.env" && log "volumes removed (secrets kept in $ENV_FILE)" ;;
env)
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  cat <<TXT
  DATABASE_URL          postgres://relay:$RELAY_DB_PASSWORD@127.0.0.1:15432/relay?sslmode=disable
  S3_ENDPOINT           http://127.0.0.1:18333   (path-style; buckets relay-media, relay-feeds, relay-backups, relay-logs)
  S3 admin              $S3_ADMIN_ACCESS_KEY_ID / $S3_ADMIN_SECRET_ACCESS_KEY
  OIDC issuer (staff)   http://localhost:18180/realms/relay-staff
  OIDC issuer (listen)  http://localhost:18180/realms/relay-listeners
  Keycloak admin        http://localhost:18180/admin/   relay-admin / $KEYCLOAK_ADMIN_PASSWORD
  Test users            make dev-users   (staff.test with its TOTP URI, listener.test)
  OTLP (observability)  http://127.0.0.1:4318  grpc 127.0.0.1:4317
  Grafana               http://localhost:13000  relay-admin / $GRAFANA_ADMIN_PASSWORD
TXT
  ;;
*) die "usage: scripts/dev.sh up [observability] | down | destroy | endpoints | env" ;;
esac

#!/usr/bin/env bash
# Smoke test for the Compose dev stack (scripts/dev.sh): the same guarantees the k3d smoke test makes
# for PostgreSQL, S3, and Keycloak, and, when the observability profile runs, the OTLP paths.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker curl jq openssl od gunzip

ENV_FILE="$RELAY_HOME/dev/.env"
[ -s "$ENV_FILE" ] || die "no $ENV_FILE: run make dev first"
# shellcheck disable=SC1090
source "$ENV_FILE"
S3=http://127.0.0.1:18333
KC=http://localhost:18180
GRAFANA=http://localhost:13000
failures=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31mFAIL\033[0m %s\n' "$*"
  failures=$((failures + 1))
}
check() {
  local name=$1
  shift
  if out=$("$@" 2>&1); then pass "$name"; else fail "$name: $(tail -1 <<<"$out")"; fi
}
compose() { docker compose --project-directory "$REPO_ROOT/compose" -f "$REPO_ROOT/compose/compose.yaml" --env-file "$ENV_FILE" "$@"; }
retry() { # retry <seconds> <cmd...>
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 3
  done
}

# --- PostgreSQL ---
pg_login() { compose exec -T -e PGPASSWORD="$RELAY_DB_PASSWORD" postgres psql -h 127.0.0.1 -U relay -d relay -tAc 'select 1' | grep -qx 1; }

# --- S3 ---
s3() { # s3 <identity|anonymous> <path> [curl args...]
  local who=$1 path=$2 auth=() k s
  shift 2
  if [ "$who" != anonymous ]; then
    k="S3_$(tr '[:lower:]' '[:upper:]' <<<"$who")_ACCESS_KEY_ID" s="S3_$(tr '[:lower:]' '[:upper:]' <<<"$who")_SECRET_ACCESS_KEY"
    auth=(--aws-sigv4 "aws:amz:us-east-1:s3" --user "${!k}:${!s}")
  fi
  curl -s --max-time 20 "${auth[@]}" "$@" "$S3$path"
}
expect_s3() { # expect_s3 <identity> <path> <status>
  local got
  got=$(s3 "$1" "$2" -o /dev/null -w '%{http_code}')
  [ "$got" = "$3" ] || {
    echo "$1 GET $2 -> $got, expected $3"
    return 1
  }
}
buckets_exist() {
  local list b missing=()
  list=$(s3 admin /)
  for b in relay-media relay-feeds relay-backups relay-logs; do grep -q "<Name>$b</Name>" <<<"$list" || missing+=("$b"); done
  [ ${#missing[@]} -eq 0 ] || {
    echo "missing buckets: ${missing[*]}"
    return 1
  }
}

# --- Keycloak ---
oidc_issuer() {
  local issuer
  issuer=$(curl -sS --max-time 10 "$KC/realms/$1/.well-known/openid-configuration" | jq -r .issuer)
  [ "$issuer" = "$KC/realms/$1" ] || {
    echo "issuer '$issuer'"
    return 1
  }
}
keycloak() { KEYCLOAK_URL=$KC KEYCLOAK_USERS_ENV=$ENV_FILE "$REPO_ROOT/scripts/keycloak.sh" "$@"; }

# --- Observability (profile) ---
ID="dev-smoke-$(date +%s)-$RANDOM"
TRACE_ID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
grafana_get() { curl -fsS --max-time 15 --user "relay-admin:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA$1"; }
otlp_send() {
  local now res span
  now="$(date +%s)000000000"
  span=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  res='{"attributes":[{"key":"service.name","value":{"stringValue":"relay-dev-smoke"}}]}'
  post() { curl -fsS --max-time 10 -o /dev/null -H 'Content-Type: application/json' "http://127.0.0.1:4318/v1/$1" -d "$2"; }
  post traces "{\"resourceSpans\":[{\"resource\":$res,\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$span\",\"name\":\"smoke\",\"kind\":1,\"startTimeUnixNano\":\"$now\",\"endTimeUnixNano\":\"$now\"}]}]}]}"
  post metrics "{\"resourceMetrics\":[{\"resource\":$res,\"scopeMetrics\":[{\"metrics\":[{\"name\":\"relay_smoke\",\"gauge\":{\"dataPoints\":[{\"asInt\":\"1\",\"timeUnixNano\":\"$now\",\"attributes\":[{\"key\":\"smoke_id\",\"value\":{\"stringValue\":\"$ID\"}}]}]}}]}]}]}"
  post logs "{\"resourceLogs\":[{\"resource\":$res,\"scopeLogs\":[{\"logRecords\":[{\"timeUnixNano\":\"$now\",\"body\":{\"stringValue\":\"otlp $ID\"}}]}]}]}"
}
datasource_healthy() { [ "$(grafana_get "/api/datasources/uid/$1/health" | jq -r .status)" = OK ]; }
# Tempo answers 200 with an empty trace for an unknown ID, so look for the span itself.
tempo_has_trace() { grafana_get "/api/datasources/proxy/uid/tempo/api/v2/traces/$TRACE_ID" 2>/dev/null | grep -q '"name":"smoke"'; }
prometheus_has_metric() {
  [ "$(grafana_get "/api/datasources/proxy/uid/prometheus/api/v1/query?query=relay_smoke%7Bsmoke_id%3D%22$ID%22%7D" | jq '.data.result | length')" -ge 1 ]
}
s3_has_log() {
  local key
  for key in $(s3 admin "/relay-logs?list-type=2&prefix=otel/" | grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g' | tail -20); do
    # Keys hold "=" (the partition format), which SigV4 needs percent-encoded in the path.
    s3 admin "/relay-logs/${key//=/%3D}" | gunzip 2>/dev/null | grep -q "otlp $ID" && return 0
  done
  return 1
}

log "PostgreSQL"
check "relay role logs in to the relay database over TCP" pg_login

log "Object storage (SeaweedFS S3 on $S3)"
check "buckets relay-media, relay-feeds, relay-backups, relay-logs exist" buckets_exist
check "anonymous bucket listing is denied" expect_s3 anonymous / 403
check "anonymous read of relay-media is denied" expect_s3 anonymous /relay-media 403
check "cnpg identity can list relay-backups" expect_s3 cnpg /relay-backups 200
check "cnpg identity cannot list relay-media" expect_s3 cnpg /relay-media 403
check "workflows identity can list relay-media" expect_s3 workflows /relay-media 200

log "Identity (Keycloak on $KC)"
check "relay-staff OIDC discovery" oidc_issuer relay-staff
check "relay-listeners OIDC discovery" oidc_issuer relay-listeners
check "relay-staff login stops at TOTP after the password" keycloak login-staff-without-otp
check "relay-staff rejects a wrong TOTP code" keycloak login-staff-bad-otp
check "relay-staff login with password + TOTP issues a code" keycloak login-staff

if [ -n "$(compose ps -q otel-collector 2>/dev/null)" ]; then
  log "Observability (profile)"
  check "Grafana datasource Prometheus is healthy" datasource_healthy prometheus
  check "Grafana datasource Tempo is healthy" datasource_healthy tempo
  check "OTLP trace, metric, and log accepted on 127.0.0.1:4318" otlp_send
  check "the trace reaches Tempo" retry 60 tempo_has_trace
  check "the metric reaches Prometheus (OTLP receiver)" retry 60 prometheus_has_metric
  check "the log record lands in s3://relay-logs/otel/" retry 90 s3_has_log
else
  log "Observability profile not running: skipped (make dev PROFILE=observability)"
fi

if [ "$failures" -gt 0 ]; then die "$failures dev smoke check(s) failed"; fi
log "all dev smoke checks passed"

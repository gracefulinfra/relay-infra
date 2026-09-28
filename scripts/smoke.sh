#!/usr/bin/env bash
# Smoke test for the local platform: every service is healthy, and every routed service answers through
# the Gateway over HTTPS with a certificate that chains to the local CA. Exits non-zero on the first
# failed section and prints a PASS/FAIL line per check.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require kubectl curl jq

DOMAIN=${DOMAIN:?envs/$RELAY_ENV/env.sh sets no DOMAIN}
CA_CERT=${CA_CERT:-$CA_DIR/relay-local-ca.crt}
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

# https_status <host> <path> <expected-status-regex>: GETs through the Gateway, verifying TLS against the local CA.
https_status() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CA_CERT" "https://$1.$DOMAIN$2")
  [[ $code =~ ^($3)$ ]] || {
    echo "HTTP $code from https://$1.$DOMAIN$2"
    return 1
  }
}

apps_healthy() {
  local bad
  bad=$(kc -n argocd get applications.argoproj.io -o json | jq -r '.items[]
    | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | .metadata.name')
  [ -z "$bad" ] || {
    echo "not Synced/Healthy: $bad"
    return 1
  }
}

condition_true() { # condition_true <kind> <name> [namespace] <condition>
  local kind=$1 name=$2 ns=$3 cond=$4 args=()
  [ -n "$ns" ] && args=(-n "$ns")
  kc wait "${args[@]}" --for=condition="$cond" "$kind/$name" --timeout=60s >/dev/null
}

http_redirects() {
  local loc
  loc=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "http://argocd.$DOMAIN/")
  [[ $loc == "301 https://argocd.$DOMAIN/" ]] || {
    echo "got '$loc'"
    return 1
  }
}

# --- S3 helpers ------------------------------------------------------------------------------------------
# The S3 endpoint is not routed through the Gateway. In-cluster SeaweedFS is reached from inside its pod;
# an external endpoint (S3_MODE=external) from here, over TLS with its CA. Credentials are the cluster's own.
s3_creds() { kc -n relay-secret-source get secret "s3-$1" -o json | jq -r '"\(.data.access_key_id | @base64d):\(.data.secret_access_key | @base64d)"'; }
s3_curl() { # s3_curl <identity|anonymous> <path> [curl args...]
  local who=$1 path=$2 auth=()
  shift 2
  [ "$who" = anonymous ] || auth=(--aws-sigv4 "aws:amz:us-east-1:s3" --user "$(s3_creds "$who")")
  if [ "${S3_MODE:-in-cluster}" = external ]; then
    curl -s --max-time 20 --cacert "$S3_CA_FILE" "${auth[@]}" "$@" "$S3_ENDPOINT$path"
  else
    kc -n "$S3_NAMESPACE" exec "deploy/$S3_SERVICE" -- curl -s "${auth[@]}" "$@" "http://localhost:$S3_SERVICE_PORT$path"
  fi
}
# s3_status <identity|anonymous> <path>: HTTP status of a GET against the S3 endpoint.
s3_status() { s3_curl "$1" "$2" -o /dev/null -w '%{http_code}'; }
expect_s3() { # expect_s3 <identity> <path> <status>
  local got
  got=$(s3_status "$1" "$2")
  [ "$got" = "$3" ] || {
    echo "$1 GET $2 -> $got, expected $3"
    return 1
  }
}
buckets_exist() {
  local list missing=()
  list=$(s3_curl admin /)
  for b in relay-media relay-feeds relay-backups relay-logs; do grep -q "<Name>$b</Name>" <<<"$list" || missing+=("$b"); done
  [ ${#missing[@]} -eq 0 ] || {
    echo "missing buckets: ${missing[*]}"
    return 1
  }
}
s3_list() { s3_curl admin "/$1?list-type=2&prefix=$2"; } # s3_list <bucket> <prefix>: ListObjectsV2 XML

cnpg_backup() {
  local name id dest prefix
  name="smoke-$(date +%s)"
  kc apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: {name: $name, namespace: relay-db, labels: {relay.dev/smoke: "true"}}
spec:
  cluster: {name: relay}
  method: plugin
  pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}
YAML
  kc -n relay-db wait --for=jsonpath='{.status.phase}'=completed "backup/$name" --timeout=300s >/dev/null || {
    echo "backup $name: $(kc -n relay-db get backup "$name" -o jsonpath='{.status.phase} {.status.error}')"
    return 1
  }
  id=$(kc -n relay-db get backup "$name" -o jsonpath='{.status.backupId}')
  # The env decides where backups go (envs/local-b archives next to the origin copy).
  dest=$(kc -n relay-db get objectstore relay-backups -o jsonpath='{.spec.configuration.destinationPath}')
  prefix=${dest#s3://relay-backups/}
  s3_list relay-backups "${prefix}relay/base/$id/" | grep -q "<Key>${prefix}relay/base/$id/" || {
    echo "backup $id completed but nothing under ${dest}relay/base/$id/"
    return 1
  }
  kc -n relay-db delete backup "$name" --wait=false >/dev/null
}

workflow_artifact() {
  local name
  name=$(kc -n relay-media create -o jsonpath='{.metadata.name}' -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {generateName: smoke-, labels: {relay.dev/smoke: "true"}}
spec:
  entrypoint: main
  serviceAccountName: argo-workflow
  ttlStrategy: {secondsAfterCompletion: 600}
  securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
  templates:
    - name: main
      container:
        image: docker.io/library/busybox:1.38.0@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e
        command: [sh, -c, "echo relay smoke > /tmp/out.txt"]
        resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
      outputs:
        artifacts: [{name: out, path: /tmp/out.txt}]
YAML
  )
  kc -n relay-media wait --for=jsonpath='{.status.phase}'=Succeeded "workflow/$name" --timeout=300s >/dev/null || {
    echo "workflow $name: $(kc -n relay-media get workflow "$name" -o jsonpath='{.status.phase} {.status.message}')"
    return 1
  }
  s3_list relay-media "argo-artifacts/" | grep -q "/$name/" || {
    echo "no artifact for $name under s3://relay-media/argo-artifacts/"
    return 1
  }
}

# --- Observability helpers -------------------------------------------------------------------------------
# Grafana is the one routed observability UI; Prometheus and Tempo are queried through its datasource
# proxy, so the checks also prove the datasources are wired.
BUSYBOX=docker.io/library/busybox:1.38.0@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e
grafana_creds() { kc -n relay-secret-source get secret grafana-admin -o json | jq -r '"\(.data["admin-user"] | @base64d):\(.data["admin-password"] | @base64d)"'; }
grafana_get() { curl -fsS --max-time 15 --cacert "$CA_CERT" --user "$(grafana_creds)" "https://grafana.$DOMAIN$1"; }

datasource_healthy() { # datasource_healthy <uid>
  local status
  status=$(grafana_get "/api/datasources/uid/$1/health" | jq -r .status)
  [ "$status" = OK ] || {
    echo "datasource $1: $status"
    return 1
  }
}

prometheus_targets_up() {
  local down
  down=$(grafana_get "/api/datasources/proxy/uid/prometheus/api/v1/query?query=up%3D%3D0" | jq -r '.data.result[].metric.job' | sort -u)
  [ -z "$down" ] || {
    echo "targets down: $(tr '\n' ' ' <<<"$down")"
    return 1
  }
}

# The IDs for the OTLP checks are made in the main shell, because check runs each step in a subshell.
SMOKE_ID="smoke-$(date +%s)-$RANDOM"
TRACE_ID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
SPAN_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
SMOKE_POD="otlp-$SMOKE_ID"

# otlp_send: from a pod, posts one trace, one metric, and one log record to the collector over OTLP/HTTP,
# and prints a marker to its own stdout for the filelog path.
otlp_send() {
  local now res
  now="$(date +%s)000000000"
  res='{"attributes":[{"key":"service.name","value":{"stringValue":"relay-smoke"}}]}'
  jq -n --arg pod "$SMOKE_POD" --arg image "$BUSYBOX" --arg id "$SMOKE_ID" --arg now "$now" \
    --arg trace "$TRACE_ID" --arg span "$SPAN_ID" --argjson res "$res" \
    --arg ep http://otel-collector.observability.svc:4318 '
    def env($k; $v): {name: $k, value: ($v | tojson)};
    {apiVersion: "v1", kind: "Pod",
     metadata: {name: $pod, namespace: "observability", labels: {"relay.dev/smoke": "true"}},
     spec: {restartPolicy: "Never",
       securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: "RuntimeDefault"}},
       containers: [{name: "otlp", image: $image,
         securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}, readOnlyRootFilesystem: true},
         resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {memory: "64Mi"}},
         command: ["sh", "-c", "set -e; echo \"stdout $ID\"; post() { wget -q -O /dev/null --header \"Content-Type: application/json\" --post-data \"$2\" \"$EP/v1/$1\"; }; post traces \"$traces\"; post metrics \"$metrics\"; post logs \"$logs\""],
         env: [{name: "ID", value: $id}, {name: "EP", value: $ep},
           env("traces"; {resourceSpans: [{resource: $res, scopeSpans: [{spans: [{traceId: $trace, spanId: $span, name: "smoke", kind: 1, startTimeUnixNano: $now, endTimeUnixNano: $now}]}]}]}),
           env("metrics"; {resourceMetrics: [{resource: $res, scopeMetrics: [{metrics: [{name: "relay_smoke", gauge: {dataPoints: [{asInt: "1", timeUnixNano: $now, attributes: [{key: "smoke_id", value: {stringValue: $id}}]}]}}]}]}]}),
           env("logs"; {resourceLogs: [{resource: $res, scopeLogs: [{logRecords: [{timeUnixNano: $now, severityText: "INFO", body: {stringValue: ("otlp " + $id)}}]}]}]})]}]}}' |
    kc create -f - >/dev/null
  kc -n observability wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$SMOKE_POD" --timeout=120s >/dev/null || {
    echo "pod $SMOKE_POD: $(kc -n observability get pod "$SMOKE_POD" -o jsonpath='{.status.phase}') $(kc -n observability logs "$SMOKE_POD" 2>&1 | tail -1)"
    return 1
  }
}

# retry <seconds> <cmd...>: reruns cmd every 5 s until it succeeds or the time is up.
retry() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# Tempo answers 200 with an empty trace for an unknown ID, so look for the span itself.
tempo_has_trace() { grafana_get "/api/datasources/proxy/uid/tempo/api/v2/traces/$TRACE_ID" 2>/dev/null | grep -q '"name":"smoke"'; }
prometheus_has_metric() {
  [ "$(grafana_get "/api/datasources/proxy/uid/prometheus/api/v1/query?query=relay_smoke%7Bsmoke_id%3D%22$SMOKE_ID%22%7D" |
    jq '.data.result | length')" -ge 1 ]
}
# s3_has_log <text>: the text is in one of today's newest gzipped OTLP JSON objects under s3://relay-logs/otel/.
s3_has_log() {
  local prefix key
  prefix="otel/year=$(date -u +%Y)/month=$(date -u +%m)/day=$(date -u +%d)/"
  for key in $(s3_list relay-logs "$prefix" | grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g' | tail -20); do
    # Keys hold "=" (the partition format), which SigV4 needs percent-encoded in the path.
    s3_curl admin "/relay-logs/${key//=/%3D}" | gunzip 2>/dev/null | grep -q "$1" && return 0
  done
  return 1
}

trace_in_tempo() { retry 90 tempo_has_trace || { echo "trace $TRACE_ID not found in Tempo" && return 1; }; }
metric_in_prometheus() {
  retry 90 prometheus_has_metric || { echo "relay_smoke{smoke_id=\"$SMOKE_ID\"} not in Prometheus" && return 1; }
}
log_in_s3() { retry 120 s3_has_log "$1" || { echo "'$1' not under s3://relay-logs/otel/ for today" && return 1; }; }

oidc_issuer() { # oidc_issuer <realm>
  local issuer
  issuer=$(curl -sS --max-time 10 --cacert "$CA_CERT" "https://auth.$DOMAIN/realms/$1/.well-known/openid-configuration" | jq -r .issuer)
  [ "$issuer" = "https://auth.$DOMAIN/realms/$1" ] || {
    echo "issuer '$issuer'"
    return 1
  }
}

log "GitOps"
check "every Argo CD Application is Synced/Healthy" apps_healthy

log "Secrets (External Secrets Operator)"
check "ClusterSecretStore relay-secrets is Ready" condition_true clustersecretstore relay-secrets "" Ready
check "ExternalSecret cert-manager/relay-local-ca is Ready" condition_true externalsecret relay-local-ca cert-manager Ready

log "TLS (cert-manager)"
check "ClusterIssuer relay-issuer is Ready" condition_true clusterissuer relay-issuer "" Ready
check "Gateway certificate relay-wildcard-tls is Ready" condition_true certificate relay-wildcard-tls relay-gateway Ready

log "Gateway (Envoy Gateway)"
check "GatewayClass relay is Accepted" condition_true gatewayclass relay "" Accepted
check "Gateway relay is Programmed" condition_true gateway relay relay-gateway Programmed
check "http:// redirects to https://" http_redirects
check "Argo CD UI via https://argocd.$DOMAIN" https_status argocd / 200

log "Object storage (S3, ${S3_MODE:-in-cluster})"
check "buckets relay-media, relay-feeds, relay-backups, relay-logs exist" buckets_exist
check "anonymous bucket listing is denied" expect_s3 anonymous / 403
check "anonymous read of relay-media is denied" expect_s3 anonymous /relay-media 403
check "anonymous read of relay-backups is denied" expect_s3 anonymous /relay-backups 403
check "cnpg identity can list relay-backups" expect_s3 cnpg /relay-backups 200
check "cnpg identity cannot list relay-media" expect_s3 cnpg /relay-media 403

log "PostgreSQL (CloudNativePG)"
check "Cluster relay-db/relay is Ready" condition_true cluster relay relay-db Ready
check "Cluster keycloak/keycloak-db is Ready" condition_true cluster keycloak-db keycloak Ready
check "relay WAL archiving to S3 works" condition_true cluster relay relay-db ContinuousArchiving
check "on-demand backup lands in s3://relay-backups" cnpg_backup

log "Identity (Keycloak)"
check "relay-staff OIDC discovery via https://auth.$DOMAIN" oidc_issuer relay-staff
check "relay-listeners OIDC discovery via https://auth.$DOMAIN" oidc_issuer relay-listeners
check "relay-staff login stops at TOTP after the password" "$REPO_ROOT/scripts/keycloak.sh" login-staff-without-otp
check "relay-staff rejects a wrong TOTP code" "$REPO_ROOT/scripts/keycloak.sh" login-staff-bad-otp
check "relay-staff login with password + TOTP issues a code" "$REPO_ROOT/scripts/keycloak.sh" login-staff

log "Workflows (Argo Workflows)"
check "a workflow runs in relay-media and stores its artifact in S3" workflow_artifact

log "Observability (Prometheus, Grafana, Tempo, OTel Collector)"
check "Grafana answers via https://grafana.$DOMAIN" https_status grafana /api/health 200
check "Grafana datasource Prometheus is healthy" datasource_healthy prometheus
check "Grafana datasource Tempo is healthy" datasource_healthy tempo
check "every Prometheus scrape target is up" prometheus_targets_up
check "otel identity can list relay-logs" expect_s3 otel /relay-logs 200
check "otel identity cannot list relay-media" expect_s3 otel /relay-media 403
if check "OTLP trace, metric, and log sent to the collector" otlp_send; then
  check "the trace reaches Tempo" trace_in_tempo
  check "the metric reaches Prometheus (OTLP receiver)" metric_in_prometheus
  check "the OTLP log record lands in s3://relay-logs/otel/" log_in_s3 "otlp $SMOKE_ID"
  check "the pod's stdout (filelog) lands in s3://relay-logs/otel/" log_in_s3 "stdout $SMOKE_ID"
  kc -n observability delete pod "$SMOKE_POD" --wait=false >/dev/null
fi

if [ "$failures" -gt 0 ]; then die "$failures smoke check(s) failed"; fi
log "all smoke checks passed"

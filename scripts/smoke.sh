#!/usr/bin/env bash
# Smoke test for the local platform: every service is healthy, and every routed service answers through
# the Gateway over HTTPS with a certificate that chains to the local CA. Exits non-zero on the first
# failed section and prints a PASS/FAIL line per check.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require kubectl curl jq

DOMAIN=${DOMAIN:-relay.localtest.me}
CA_CERT=${CA_CERT:-$RELAY_HOME/ca/relay-local-ca.crt}
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

# --- S3 helpers: requests run inside the SeaweedFS pod (the S3 endpoint is not routed). ----------------
S3_EXEC=(kc -n seaweedfs exec deploy/seaweedfs-all-in-one --)
s3_creds() { kc -n relay-secret-source get secret "s3-$1" -o json | jq -r '"\(.data.access_key_id | @base64d):\(.data.secret_access_key | @base64d)"'; }
# s3_status <identity|anonymous> <path>: HTTP status of a GET against the S3 gateway.
s3_status() {
  local auth=()
  [ "$1" = anonymous ] || auth=(--aws-sigv4 "aws:amz:us-east-1:s3" --user "$(s3_creds "$1")")
  "${S3_EXEC[@]}" curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "http://localhost:8333$2"
}
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
  list=$("${S3_EXEC[@]}" sh -c 'echo s3.bucket.list | weed shell' 2>/dev/null)
  for b in relay-media relay-feeds relay-backups relay-logs; do grep -q "^ *$b\b" <<<"$list" || missing+=("$b"); done
  [ ${#missing[@]} -eq 0 ] || {
    echo "missing buckets: ${missing[*]}"
    return 1
  }
}
s3_list() { # s3_list <bucket> <prefix>: ListObjectsV2 XML (admin identity)
  "${S3_EXEC[@]}" curl -s --aws-sigv4 "aws:amz:us-east-1:s3" --user "$(s3_creds admin)" \
    "http://localhost:8333/$1?list-type=2&prefix=$2"
}

cnpg_backup() {
  local name id
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
  s3_list relay-backups "cnpg/relay/base/$id/" | grep -q "<Key>cnpg/relay/base/$id/" || {
    echo "backup $id completed but nothing under s3://relay-backups/cnpg/relay/base/$id/"
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

log "Object storage (SeaweedFS S3)"
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

if [ "$failures" -gt 0 ]; then die "$failures smoke check(s) failed"; fi
log "all smoke checks passed"

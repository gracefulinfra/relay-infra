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

if [ "$failures" -gt 0 ]; then die "$failures smoke check(s) failed"; fi
log "all smoke checks passed"

#!/usr/bin/env bash
# Keycloak helpers for the local platform.
#   scripts/keycloak.sh test-users   print the test users and the staff TOTP enrolment URI
#   scripts/keycloak.sh login-staff  browser-style login to relay-staff with password + TOTP (exit 0 = got an auth code)
#   scripts/keycloak.sh login-staff-without-otp  expect login to stop at the OTP form (exit 0 = no code without TOTP)
#   scripts/keycloak.sh login-staff-bad-otp      expect a wrong TOTP code to be rejected (exit 0 = no code)
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
#
# Against the Compose dev stack instead of k3d: KEYCLOAK_URL=http://localhost:18180 and
# KEYCLOAK_USERS_ENV=$RELAY_HOME/dev/.env (scripts/dev-smoke.sh sets both).
require curl openssl jq od
[ -n "${KEYCLOAK_USERS_ENV:-}" ] || require kubectl

DOMAIN=${DOMAIN:?envs/$RELAY_ENV/env.sh sets no DOMAIN}
BASE=${KEYCLOAK_URL:-https://auth.$DOMAIN}
CA_CERT=${CA_CERT:-$CA_DIR/relay-local-ca.crt}

# secret_field <staff_username|staff_password|...>: from the k3d secret source, or from the dev .env
# (RELAY_STAFF_USERNAME, ...).
secret_field() {
  if [ -n "${KEYCLOAK_USERS_ENV:-}" ]; then
    sed -n "s/^RELAY_$(tr '[:lower:]' '[:upper:]' <<<"$1")=//p" "$KEYCLOAK_USERS_ENV"
    return
  fi
  kc -n relay-secret-source get secret keycloak-test-users -o jsonpath="{.data.$1}" | openssl base64 -d -A
}

hex() { od -An -tx1 | tr -d ' \n'; }

# totp <raw-secret>: RFC 6238 code (HMAC-SHA1, 30 s, 6 digits). Keycloak keys the HMAC with the raw
# secret's bytes; authenticator apps see the same bytes as base32.
totp() {
  local key counter mac offset code
  key=$(printf '%s' "$1" | hex)
  counter=$(printf '%016x' $(($(date +%s) / 30)))
  # shellcheck disable=SC2059,SC2001 # printf expands the \x escapes; bash 3.2 has no & in ${//}
  mac=$(printf "$(sed 's/../\\x&/g' <<<"$counter")" |
    openssl dgst -sha1 -mac HMAC -macopt "hexkey:$key" -binary | hex)
  offset=$((16#${mac:39:1} * 2))
  code=$(((16#${mac:offset:8} & 0x7fffffff) % 1000000))
  printf '%06d' "$code"
}

b32() { # RFC 4648 base32 without padding
  local bits="" out="" alphabet=ABCDEFGHIJKLMNOPQRSTUVWXYZ234567 byte i
  for byte in $(printf '%s' "$1" | od -An -tu1); do
    for ((i = 7; i >= 0; i--)); do bits+=$(((byte >> i) & 1)); done
  done
  while [ $((${#bits} % 5)) -ne 0 ]; do bits+="0"; done
  for ((i = 0; i < ${#bits}; i += 5)); do out+=${alphabet:$((2#${bits:i:5})):1}; done
  printf '%s' "$out"
}

form_action() { grep -o "id=\"$1\"[^>]*action=\"[^\"]*\"\|action=\"[^\"]*\"[^>]*id=\"$1\"" | grep -o 'action="[^"]*"' |
  head -1 | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g'; }

# login <with-otp: 1|0>: prints the final redirect Location on success.
login() {
  local with_otp=$1 jar page action verifier challenge redirect location
  jar=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$jar'" RETURN
  local c=(curl -sS -b "$jar" -c "$jar" --max-time 15)
  [ -f "$CA_CERT" ] && c+=(--cacert "$CA_CERT")
  verifier=$(openssl rand -hex 32)
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  redirect="$BASE/realms/relay-staff/account/"
  page=$("${c[@]}" -G "$BASE/realms/relay-staff/protocol/openid-connect/auth" \
    --data-urlencode client_id=account-console --data-urlencode "redirect_uri=$redirect" \
    --data-urlencode response_type=code --data-urlencode scope=openid \
    --data-urlencode "code_challenge=$challenge" --data-urlencode code_challenge_method=S256)
  action=$(form_action kc-form-login <<<"$page")
  [ -n "$action" ] || die "no login form at $BASE/realms/relay-staff"

  page=$("${c[@]}" "$action" --data-urlencode "username=$(secret_field staff_username)" \
    --data-urlencode "password=$(secret_field staff_password)" -w '\n%{redirect_url}')
  location=$(tail -1 <<<"$page")
  if [[ $location == *"code="* ]]; then die "logged in without being asked for TOTP"; fi
  action=$(form_action kc-otp-login-form <<<"$page")
  [ -n "$action" ] || die "password step did not lead to the OTP form"
  if [ "$with_otp" = 0 ]; then
    echo "stopped at the OTP form, as required"
    return 0
  fi

  # Keycloak refuses a code that was already used, so never reuse a 30 s time step.
  local code last_step_file="$RELAY_HOME/.last-totp-step"
  if [ "$with_otp" = 1 ] && [ "$(cat "$last_step_file" 2>/dev/null)" = $(($(date +%s) / 30)) ]; then
    sleep $((30 - $(date +%s) % 30 + 1))
  fi
  code=$(totp "$(secret_field staff_totp_secret)")
  if [ "$with_otp" = 1 ]; then echo $(($(date +%s) / 30)) >"$last_step_file"; fi
  if [ "$with_otp" = bad ]; then code=$(printf '%06d' $(((10#$code + 500000) % 1000000))); fi
  location=$("${c[@]}" -o /dev/null -w '%{redirect_url}' "$action" --data-urlencode "otp=$code")
  if [ "$with_otp" = bad ]; then
    [[ $location != *"code="* ]] || die "a wrong TOTP code was accepted"
    echo "wrong TOTP code rejected"
    return 0
  fi
  [[ $location == "$redirect"*"code="* ]] || die "TOTP step did not return an authorization code (got '${location:-no redirect}')"
  echo "authorization code issued after password + TOTP"
}

case ${1:-} in
  test-users)
    user=$(secret_field staff_username)
    secret=$(b32 "$(secret_field staff_totp_secret)")
    cat <<EOF
relay-staff    $BASE/realms/relay-staff/account/
  username     $user
  password     $(secret_field staff_password)
  TOTP         otpauth://totp/relay-staff:$user?secret=$secret&issuer=relay-staff&algorithm=SHA1&digits=6&period=30
               (or enter the key $secret in an authenticator app; current code $(totp "$(secret_field staff_totp_secret)"))
relay-listeners $BASE/realms/relay-listeners/account/
  username     $(secret_field listener_username)
  password     $(secret_field listener_password)
EOF
    ;;
  login-staff) login 1 ;;
  login-staff-without-otp) login 0 ;;
  login-staff-bad-otp) login bad ;;
  totp) totp "$(secret_field staff_totp_secret)" && echo ;;
  *) die "usage: $0 test-users|login-staff|login-staff-without-otp|totp" ;;
esac

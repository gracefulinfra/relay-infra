#!/usr/bin/env bash
# First start only: the app database (as CNPG's `relay` cluster provides) and Keycloak's database.
set -euo pipefail
psql -v ON_ERROR_STOP=1 -U postgres <<SQL
CREATE ROLE relay LOGIN PASSWORD '${RELAY_DB_PASSWORD}';
CREATE DATABASE relay OWNER relay;
CREATE ROLE keycloak LOGIN PASSWORD '${KEYCLOAK_DB_PASSWORD}';
CREATE DATABASE keycloak OWNER keycloak;
SQL

#!/usr/bin/env bash
# =============================================================================
# seal-secrets.sh — helper to generate SealedSecret manifests for an environment
# =============================================================================
# Requires: kubectl, kubeseal, and a running Sealed Secrets controller in eph-env.
# Reads plaintext values from environment variables (NEVER commit them).
#
# Usage:
#   ENV=dev \
#   PG_ADMIN_PW=... PG_USER=uffizzi-user PG_PW=... PG_DB=uffizzi-app \
#   REDIS_PW=... \
#   CTRL_USER=uffizzi-controller CTRL_PW=... \
#   ADMIN_EMAIL=admin@floci.dev.local ADMIN_PW=... \
#   ./scripts/seal-secrets.sh
# =============================================================================
set -euo pipefail

ENV="${ENV:?set ENV=dev|staging|prod}"
NS="eph-env"
OUT="environments/${ENV}/sealed-secrets"
CERT="${CERT:-pub-cert.pem}"

if [[ ! -f "$CERT" ]]; then
  echo "Fetching controller cert into $CERT ..."
  kubeseal --fetch-cert \
    --controller-name sealed-secrets --controller-namespace "$NS" \
    > "$CERT"
fi

seal() {  # name, then key=value pairs
  local name="$1"; shift
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl -n "$NS" create secret generic "$name" "${args[@]}" \
    --dry-run=client -o yaml \
  | kubeseal --cert "$CERT" -o yaml \
    > "${OUT}/${name}.yaml"
  echo "sealed -> ${OUT}/${name}.yaml"
}

mkdir -p "$OUT"

seal uffizzi-postgres \
  "postgres-password=${PG_ADMIN_PW:?}" \
  "username=${PG_USER:-uffizzi-user}" \
  "password=${PG_PW:?}" \
  "database=${PG_DB:-uffizzi-app}"

seal uffizzi-redis \
  "redis-password=${REDIS_PW:?}"

seal uffizzi-controller \
  "username=${CTRL_USER:-uffizzi-controller}" \
  "password=${CTRL_PW:?}"

seal uffizzi-first-user \
  "email=${ADMIN_EMAIL:?}" \
  "password=${ADMIN_PW:?}"

# Consolidated app env-secret consumed by the uffizzi-app web/sidekiq deployments
# via envFrom (Part B). Keys are named as the Rails ENV VARS the app reads, and
# override the chart-generated uffizzi-web-secret-envs + the ConfigMap's
# UFFIZZI_USER_PASSWORD. Reuses the same raw passwords as the secrets above so
# there is a single source of truth per credential.
REDIS_HOST="${REDIS_HOST:-uffizzi-app-${ENV}-redis-master}"
seal uffizzi-web-envs \
  "DATABASE_PASSWORD=${PG_PW:?}" \
  "REDIS_URL=redis://:${REDIS_PW:?}@${REDIS_HOST}" \
  "CONTROLLER_PASSWORD=${CTRL_PW:?}" \
  "VCLUSTER_CONTROLLER_PASSWORD=${CTRL_PW:?}" \
  "UFFIZZI_USER_PASSWORD=${ADMIN_PW:?}"

# Controller-side env-secret consumed by the standalone controller deployment via
# envFrom (Part B). Keys are the controller's ENV VAR names and MUST carry the same
# CTRL_PW as uffizzi-web-envs.CONTROLLER_PASSWORD so app<->controller auth matches.
seal uffizzi-controller-env \
  "CONTROLLER_LOGIN=${CTRL_USER:-uffizzi-controller}" \
  "CONTROLLER_PASSWORD=${CTRL_PW:?}"

echo "Done. Commit only the SealedSecret YAMLs under ${OUT} (encrypted)."

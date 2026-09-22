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

echo "Done. Commit only the SealedSecret YAMLs under ${OUT} (encrypted)."

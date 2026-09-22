# =============================================================================
# SEALED SECRETS — PROD  (HOW-TO, not committed secrets)
# =============================================================================
# This folder holds SealedSecret manifests (safe to commit). The encrypted
# manifests do NOT exist yet because sealing requires the live controller cert.
#
# Required secrets for the Uffizzi control plane (all in namespace eph-env):
#   1) uffizzi-postgres   keys: postgres-password, username, password, database
#   2) uffizzi-redis      keys: redis-password
#   3) uffizzi-controller keys: username, password   (MUST match app + controller values)
#   4) uffizzi-first-user keys: email, password       (first admin user)
#
# GENERATE (run against the running Sealed Secrets controller in eph-env):
#
#   # fetch controller public cert once
#   kubeseal --fetch-cert \
#     --controller-name sealed-secrets --controller-namespace eph-env \
#     > pub-cert.pem
#
#   # example: postgres secret
#   kubectl -n eph-env create secret generic uffizzi-postgres \
#     --from-literal=postgres-password='REDACTED' \
#     --from-literal=username='uffizzi-user' \
#     --from-literal=password='REDACTED' \
#     --from-literal=database='uffizzi-app' \
#     --dry-run=client -o yaml \
#     | kubeseal --cert pub-cert.pem -o yaml \
#     > environments/prod/sealed-secrets/uffizzi-postgres.yaml
#
#   # repeat for uffizzi-redis, uffizzi-controller, uffizzi-first-user
#
# Then reference these Secrets from the Helm values via the chart's
# existingSecret mechanism (verify exact keys with `helm show values`).
#
# See scripts/seal-secrets.sh for a helper.

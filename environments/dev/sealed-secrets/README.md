# =============================================================================
# SEALED SECRETS — DEV  (HOW-TO, not committed secrets)
# =============================================================================
# This folder holds SealedSecret manifests (safe to commit). The encrypted
# manifests do NOT exist yet because sealing requires the live controller cert.
#
# Required secrets for the Uffizzi control plane (all in namespace eph-env):
#   1) uffizzi-postgres   keys: postgres-password, username, password, database
#   2) uffizzi-redis      keys: redis-password
#   3) uffizzi-controller keys: username, password   (MUST match app + controller values)
#   4) uffizzi-first-user keys: email, password       (first admin user)
#   5) uffizzi-web-envs   keys: DATABASE_PASSWORD, REDIS_URL, CONTROLLER_PASSWORD,
#                               VCLUSTER_CONTROLLER_PASSWORD, UFFIZZI_USER_PASSWORD
#                         (consolidated app env-secret, consumed via envFrom — Part B)
#   6) uffizzi-controller-env keys: CONTROLLER_LOGIN, CONTROLLER_PASSWORD
#                         (controller-side env-secret, consumed via envFrom — Part B;
#                          CONTROLLER_PASSWORD MUST equal uffizzi-web-envs CONTROLLER_PASSWORD)
#
# WIRING STATUS:
#   * uffizzi-postgres / uffizzi-redis -> WIRED (Part A). Bitnami subcharts consume
#     them via existingSecret values in environments/<env>/app-values.yaml.
#   * uffizzi-web-envs  -> WIRED (Part B). The vendored uffizzi-app web/sidekiq
#     deployments layer this Secret as the LAST envFrom entry (app-values.yaml sets
#     `externalSecret: uffizzi-web-envs`), so its env-var-named keys OVERRIDE the
#     chart-generated uffizzi-web-secret-envs (DATABASE_PASSWORD, CONTROLLER_*),
#     the derived REDIS_URL, and the ConfigMap's UFFIZZI_USER_PASSWORD. This is how
#     the Rails app actually gets real (sealed) credentials.
#   * uffizzi-controller -> still used only as reference for the STANDALONE
#     controller (controller-values.yaml). The app side gets controller creds from
#     uffizzi-web-envs above.
#   * uffizzi-first-user -> the admin PASSWORD reaches the app via uffizzi-web-envs
#     (UFFIZZI_USER_PASSWORD). The separate uffizzi-first-user secret is optional
#     bookkeeping; the email is a non-secret value in app-values.yaml.
#
# scripts/seal-secrets.sh generates ALL of the above (including uffizzi-web-envs,
# whose REDIS_URL it derives as redis://:<REDIS_PW>@uffizzi-app-<ENV>-redis-master).
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
#     > environments/dev/sealed-secrets/uffizzi-postgres.yaml
#
#   # repeat for uffizzi-redis, uffizzi-controller, uffizzi-first-user
#
# Then the Bitnami postgres/redis subcharts consume uffizzi-postgres / uffizzi-redis
# via existingSecret (Part A), and the uffizzi-app web/sidekiq deployments consume
# uffizzi-web-envs via envFrom (Part B, app-values.yaml externalSecret). The app is
# then fully sealed-credential driven; no plaintext passwords live in Git or values.
#
# See scripts/seal-secrets.sh for a helper.

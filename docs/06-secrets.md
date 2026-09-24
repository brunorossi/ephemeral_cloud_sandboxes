# 06 — Secrets (Sealed Secrets)

No secret is ever committed in clear text. Plaintext `Secret` objects are encrypted
into `SealedSecret` manifests with `kubeseal`; only the encrypted form goes to Git.
The in-cluster controller (in `eph-env`) decrypts them back into `Secret` objects.

## Required secrets

All in namespace `eph-env`:

| SealedSecret name | Keys | Used by |
|---|---|---|
| `uffizzi-postgres` | `postgres-password`, `username`, `password`, `database` | PostgreSQL server (Bitnami `existingSecret`) |
| `uffizzi-redis` | `redis-password` | Redis server (Bitnami `existingSecret`) |
| `uffizzi-controller` | `username`, `password` | reference / bookkeeping (app+controller use the env-secrets below) |
| `uffizzi-first-user` | `email`, `password` | reference / bookkeeping (admin password reaches the app via `uffizzi-web-envs`) |
| `uffizzi-web-envs` | `DATABASE_PASSWORD`, `REDIS_URL`, `CONTROLLER_PASSWORD`, `VCLUSTER_CONTROLLER_PASSWORD`, `UFFIZZI_USER_PASSWORD` | uffizzi-app web/sidekiq via `envFrom` (overrides chart defaults) |
| `uffizzi-controller-env` | `CONTROLLER_LOGIN`, `CONTROLLER_PASSWORD` | standalone uffizzi-controller via `envFrom` (overrides chart defaults) |

> **Why the two `*-envs` secrets exist.** The `uffizzi-app` and `uffizzi-controller`
> charts do **not** expose a generic `existingSecret` hook for their application
> credentials — they bake them into chart-generated Secrets/ConfigMaps from Helm
> values. Our vendored charts therefore layer `uffizzi-web-envs` /
> `uffizzi-controller-env` as the **last `envFrom`** entry on the deployments, whose
> env-var-named keys override the chart defaults. Only the **Postgres/Redis servers**
> use the native Bitnami `existingSecret` mechanism (`uffizzi-postgres` /
> `uffizzi-redis`). `CONTROLLER_PASSWORD` must be identical in `uffizzi-web-envs` and
> `uffizzi-controller-env` (the helper enforces this by reusing `CTRL_PW`).

## One-time: fetch the controller certificate

The controller must be running (installed by `00-sealed-secrets`):
```bash
kubeseal --fetch-cert \
  --controller-name sealed-secrets --controller-namespace eph-env \
  > pub-cert.pem
```

## Option A — helper script (recommended)

```bash
ENV=dev CERT=pub-cert.pem \
  PG_ADMIN_PW='...' PG_USER='uffizzi-user' PG_PW='...' PG_DB='uffizzi-app' \
  REDIS_PW='...' \
  CTRL_USER='uffizzi-controller' CTRL_PW='...' \
  ADMIN_EMAIL='admin@floci.dev.local' ADMIN_PW='...' \
  ./scripts/seal-secrets.sh
```
This writes encrypted manifests to `environments/dev/sealed-secrets/`.

## Option B — manual (per secret)

```bash
kubectl -n eph-env create secret generic uffizzi-postgres \
  --from-literal=postgres-password='...' \
  --from-literal=username='uffizzi-user' \
  --from-literal=password='...' \
  --from-literal=database='uffizzi-app' \
  --dry-run=client -o yaml \
| kubeseal --cert pub-cert.pem -o yaml \
> environments/dev/sealed-secrets/uffizzi-postgres.yaml
```
Repeat for `uffizzi-redis`, `uffizzi-controller`, `uffizzi-first-user`,
`uffizzi-web-envs`, and `uffizzi-controller-env` (the helper script generates all of
them; the manual path is tedious for the two consolidated `*-envs` secrets).

## Commit and deploy

```bash
git add environments/dev/sealed-secrets/*.yaml
git commit -m "dev: sealed secrets"
git push
```
ArgoCD syncs them; the controller creates the `Secret` objects. Verify:
```bash
kubectl -n eph-env get sealedsecret
kubectl -n eph-env get secret uffizzi-postgres uffizzi-redis uffizzi-controller uffizzi-first-user uffizzi-web-envs uffizzi-controller-env
```

## Wiring secrets into the charts

The wiring is **already configured** in this repo — you only need to seal the
secrets with the names/keys above. Specifically:

- **Postgres/Redis servers** consume `uffizzi-postgres` / `uffizzi-redis` via the
  Bitnami `existingSecret` values in `app-values.yaml`
  (`global.postgresql.auth.existingSecret` + `secretKeys`, `redis.auth.existingSecret`).
- **uffizzi-app** (web + sidekiq) consumes `uffizzi-web-envs` via `envFrom`
  (`externalSecret: uffizzi-web-envs` in `app-values.yaml`), overriding the
  chart-generated `uffizzi-web-secret-envs` and the ConfigMap admin password.
- **uffizzi-controller** consumes `uffizzi-controller-env` via `envFrom`
  (`externalSecret: uffizzi-controller-env` in `controller-values.yaml`).

Keep the `CONTROLLER_PASSWORD` identical between `uffizzi-web-envs` and
`uffizzi-controller-env` (the helper reuses `CTRL_PW`, so re-seal both together).

## Rotation

1. Re-run the sealing step with the new value.
2. Commit + push; ArgoCD updates the `SealedSecret` → `Secret`.
3. Restart the consuming workloads:
   ```bash
   kubectl -n eph-env rollout restart deploy
   ```

## Rules

- **Never** commit plaintext `Secret` YAML. `.gitignore` blocks common patterns
  (`*.secret.yaml`, `*.dec.yaml`, `secrets-plain/`), but stay vigilant.
- SealedSecrets are tied to the controller's key; a controller reinstall with a new
  key invalidates old SealedSecrets (re-seal against the new cert).
- Back up the controller's sealing key if you need portability across reinstalls
  (see the Sealed Secrets project docs).

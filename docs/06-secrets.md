# 06 — Secrets (Sealed Secrets)

No secret is ever committed in clear text. Plaintext `Secret` objects are encrypted
into `SealedSecret` manifests with `kubeseal`; only the encrypted form goes to Git.
The in-cluster controller (in `eph-env`) decrypts them back into `Secret` objects.

## Required secrets

All in namespace `eph-env`:

| SealedSecret name | Keys | Used by |
|---|---|---|
| `uffizzi-postgres` | `postgres-password`, `username`, `password`, `database` | uffizzi-app / PostgreSQL |
| `uffizzi-redis` | `redis-password` | uffizzi-app / Redis |
| `uffizzi-controller` | `username`, `password` | app ↔ controller auth (must match) |
| `uffizzi-first-user` | `email`, `password` | first admin user |

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
Repeat for `uffizzi-redis`, `uffizzi-controller`, `uffizzi-first-user`.

## Commit and deploy

```bash
git add environments/dev/sealed-secrets/*.yaml
git commit -m "dev: sealed secrets"
git push
```
ArgoCD syncs them; the controller creates the `Secret` objects. Verify:
```bash
kubectl -n eph-env get sealedsecret
kubectl -n eph-env get secret uffizzi-postgres uffizzi-redis uffizzi-controller uffizzi-first-user
```

## Wiring secrets into the charts

Reference the created `Secret`s from the Helm values via each chart's `existingSecret`
(or equivalent) mechanism. Confirm the exact value keys with:
```bash
helm show values uffizzi-app/uffizzi-app | less
```
Keep the `uffizzi-controller` credentials identical between `app-values.yaml`,
`controller-values.yaml`, and the `uffizzi-controller` SealedSecret.

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

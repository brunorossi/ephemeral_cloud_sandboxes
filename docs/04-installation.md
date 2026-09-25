# 04 — Installation

This guide bootstraps the `dev` environment. Staging and prod follow the same steps
with their own root Application.

> Assumes the [Prerequisites](03-prerequisites.md) are met and placeholders are
> replaced.

## Step 1 — Point the manifests at your Git repo

Every ArgoCD `Application` (and the AppProject) references the Git repo that holds this
config. Out of the box they point at the reference fork
`https://github.com/brunorossi/ephemeral_cloud_sandboxes.git`. Replace that with your
own fork's URL everywhere it appears (`bootstrap/`, `apps/`, `projects/`):

```bash
OLD='https://github.com/brunorossi/ephemeral_cloud_sandboxes.git'
NEW='https://github.com/YOUR_ORG/YOUR_REPO.git'
grep -rl "$OLD" bootstrap apps projects \
  | xargs sed -i "s#${OLD}#${NEW}#g"

# verify none remain:
grep -rn 'brunorossi/ephemeral_cloud_sandboxes' bootstrap apps projects || echo "clean"
```

> The reference manifests carry a few `# <-- REPLACE` markers, but they are not on
> every occurrence — rely on the full-string replace above, not on the markers.
> Review the remaining placeholders (`*.local` hostnames; the `sealed-secrets` chart
> `targetRevision` in `apps/*/00-sealed-secrets.yaml` if you change it — the Uffizzi
> charts are vendored, so there is no version to pin). See
> [Configuration](05-configuration.md) for the full list.

Commit and push so ArgoCD can read the repo.

## Step 2 — Register the AppProject

```bash
kubectl apply -f projects/uffizzi-project.yaml
kubectl -n argocd get appproject uffizzi
```

## Step 3 — Apply the dev root Application

```bash
kubectl apply -f bootstrap/root-app-dev.yaml
```

ArgoCD now creates the child Applications from `apps/dev/` in sync-wave order.

> **Expected first-apply state (important).** The SealedSecret *manifests* do not exist
> in Git yet, so right after this `apply` the `uffizzi-controller-dev` and
> `uffizzi-app-dev` Applications will sync their manifests but their **pods stay
> pending** with `secret "uffizzi-controller-env" not found` /
> `secret "uffizzi-web-envs" not found` (the `envFrom` refs are `optional: false` by
> design — the platform is credential-driven and fail-closed). **This is not a
> failure.** Both root and child Applications have `selfHeal: true`, so once you seal
> the secrets in Step 5 and push, ArgoCD converges the control plane automatically —
> no re-`apply` needed. Steps 4–6 walk through this in order.

## Step 4 — Wait for the Sealed Secrets controller

The root app *applies* the child Applications in `sync-wave` order — `sealed-secrets`
(`-3`) first — but the waves order **creation**, not readiness: children then reconcile
in parallel and `selfHeal` drives convergence. **Wait for the controller before
creating secrets** — you need it running to seal against, and the uffizzi-controller/app
pods will not become Healthy until their secrets exist (their `envFrom` secret refs are
`optional: false`, so they intentionally wait). This is expected; a
`secret "uffizzi-controller-env" not found` (or `uffizzi-web-envs`) event on those pods
simply means Step 5 hasn't run yet. You may also briefly see
`sealed-secrets-resources-dev` (`00b`, wave `-2`) error with
`no matches for kind "SealedSecret"` until the CRD from `00` registers — it retries and
self-resolves (see [Troubleshooting](09-troubleshooting.md)).

```bash
argocd app get sealed-secrets-dev          # wait for Synced / Healthy
kubectl -n eph-env get deploy sealed-secrets
```

## Step 5 — Create the secrets (before the control plane can go Healthy)

> **Why this order is inherent (not just a manual convenience).** Sealing requires the
> controller's public cert (`kubeseal --fetch-cert`), and the cert only exists once the
> Sealed Secrets **controller is running** — which is why Step 4 (install controller)
> must precede Step 5 (seal). You cannot seal before the controller exists, so this
> bootstrap chicken-and-egg means the very first secrets are always created *after* the
> initial root-app apply. From then on it is pure GitOps: the sealed manifests live in
> Git, ArgoCD's `00b` app applies them, and `selfHeal` converges the control plane with
> no further manual steps. (Re-installs are seamless too, *if* you backed up the
> controller's sealing key — see [Operations](08-operations.md#backups); otherwise
> re-seal against the new cert.)

The control plane needs its credentials as SealedSecrets. See [Secrets](06-secrets.md).
The helper generates all six required secrets (`uffizzi-postgres`, `uffizzi-redis`,
`uffizzi-controller`, `uffizzi-first-user`, `uffizzi-web-envs`, `uffizzi-controller-env`):

```bash
kubeseal --fetch-cert \
  --controller-name sealed-secrets --controller-namespace eph-env > pub-cert.pem

ENV=dev CERT=pub-cert.pem \
  PG_ADMIN_PW=... PG_USER='uffizzi-user' PG_PW=... PG_DB='uffizzi-app' \
  REDIS_PW=... CTRL_USER='uffizzi-controller' CTRL_PW=... \
  ADMIN_EMAIL=admin@floci.dev.local ADMIN_PW=... \
  ./scripts/seal-secrets.sh

git add environments/dev/sealed-secrets/*.yaml && git commit -m "dev secrets" && git push
```

ArgoCD applies the SealedSecrets (via the `00b-sealed-secrets-resources` Application,
sync-wave `-2`, which watches `environments/<env>/sealed-secrets/`); the controller
emits the plain Secrets into `eph-env`, and the uffizzi-controller/app pods start.

## Step 6 — Watch the control plane converge

Now the remaining Applications can become Healthy:
```bash
argocd app list
argocd app get uffizzi-root-dev
```
Wait until all are `Synced` / `Healthy`: `sealed-secrets-dev`,
`sealed-secrets-resources-dev`, `uffizzi-cluster-operator-dev`,
`uffizzi-controller-dev`, `uffizzi-app-dev`.
```bash
kubectl -n eph-env get pods
kubectl get crd | grep -E 'uffizzicluster|sealedsecret'
```
If the app/controller started before the secrets and are stuck, restart them:
```bash
kubectl -n eph-env rollout restart deploy
```

## Step 7 — Verify the API over HTTP

```bash
curl -i http://api.dev.local/     # expect an HTTP response (no TLS)
```

## Step 8 — First login

```bash
uffizzi login --server http://api.dev.local
```
Use the first-user credentials you sealed in Step 5.

## Installing staging / prod

```bash
kubectl apply -f bootstrap/root-app-staging.yaml   # automated sync
kubectl apply -f bootstrap/root-app-prod.yaml      # MANUAL sync by default
```
For prod, trigger the first sync from the ArgoCD UI/CLI (or enable `automated` in
`bootstrap/root-app-prod.yaml`). Create each environment's secrets with `ENV=staging`
/ `ENV=prod`.

## Uninstall

```bash
# Remove the root app (prune removes children), then the project:
kubectl -n argocd delete application uffizzi-root-dev
kubectl -n argocd delete appproject uffizzi
# Optionally clean the namespace:
kubectl delete ns eph-env
```

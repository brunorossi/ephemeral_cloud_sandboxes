# 04 — Installation

This guide bootstraps the `dev` environment. Staging and prod follow the same steps
with their own root Application.

> Assumes the [Prerequisites](03-prerequisites.md) are met and placeholders are
> replaced.

## Step 1 — Replace placeholders

At minimum, set your Git repo URL everywhere `<ORG>` appears:

```bash
grep -rl "<ORG>" . --include='*.yaml' \
  | xargs sed -i 's#https://github.com/<ORG>/uffizzi-floci.git#https://github.com/YOUR_ORG/uffizzi-floci.git#g'
```

Review other placeholders (`*.local` hostnames, chart versions marked `# <-- verify`).
See [Configuration](05-configuration.md) for the full list.

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

## Step 4 — Watch the rollout

Via CLI:
```bash
argocd app list
argocd app get uffizzi-root-dev
```
Or in the ArgoCD UI. Wait until all of these are `Synced` / `Healthy`:
`sealed-secrets-dev`, `uffizzi-cluster-operator-dev`, `uffizzi-controller-dev`,
`uffizzi-app-dev`.

Confirm workloads landed in `eph-env`:
```bash
kubectl -n eph-env get pods
kubectl get crd | grep -E 'uffizzicluster|sealedsecret'
```

## Step 5 — Create the secrets

The control plane needs its credentials as SealedSecrets. See
[Secrets](06-secrets.md). In short:

```bash
kubeseal --fetch-cert \
  --controller-name sealed-secrets --controller-namespace eph-env > pub-cert.pem

ENV=dev CERT=pub-cert.pem \
  PG_ADMIN_PW=... PG_PW=... REDIS_PW=... CTRL_PW=... \
  ADMIN_EMAIL=admin@floci.dev.local ADMIN_PW=... \
  ./scripts/seal-secrets.sh

git add environments/dev/sealed-secrets/*.yaml && git commit -m "dev secrets" && git push
```

ArgoCD applies the SealedSecrets; the controller emits the plain Secrets into
`eph-env`. Restart the app/controller if they started before the secrets existed:
```bash
kubectl -n eph-env rollout restart deploy
```

## Step 6 — Verify the API over HTTP

```bash
curl -i http://api.dev.local/     # expect an HTTP response (no TLS)
```

## Step 7 — First login

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

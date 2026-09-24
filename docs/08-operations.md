# 08 — Operations (Day-2)

Admin/operator tasks for running the platform.

## Sync & reconciliation

- ArgoCD reconciles automatically for dev/staging (`automated` sync, `prune` +
  `selfHeal`). Prod is **manual** by default.
- Force a sync:
  ```bash
  argocd app sync uffizzi-root-dev
  argocd app sync uffizzi-app-dev
  ```
- Inspect state:
  ```bash
  argocd app get uffizzi-app-dev
  kubectl -n eph-env get pods,svc,ingress
  ```

## Validation (before pushing changes)

```bash
# YAML sanity
find . -name '*.yaml' -not -path './.kiro/*' -exec yq e '.' {} \; >/dev/null

# Render a vendored chart with its values and confirm HTTP-only (no TLS block/redirect)
helm template uffizzi-app charts/uffizzi-app \
  -f environments/dev/app-values.yaml | grep -iE 'ingress|tls|https' || true

# Dry-run the vcluster presets
kubectl apply --dry-run=client -f environments/dev/templates/floci-aws.yaml
```

## Adding or removing a component

Because the root app uses `directory.recurse`, GitOps is file-driven:
- **Add**: create `apps/<env>/NN-my-component.yaml` (set an appropriate `sync-wave`),
  commit, push. ArgoCD creates it.
- **Remove**: delete the file, commit, push. ArgoCD prunes it.

## Upgrading a chart

The operator/controller/app charts are **vendored** under `charts/`, so upgrades mean
**re-vendoring**, not bumping `targetRevision`:
1. Find the new version:
   ```bash
   helm repo add uffizzi-app https://uffizzicloud.github.io/uffizzi_app
   helm repo update
   helm search repo uffizzi-app --versions | head
   ```
2. Re-vendor and re-apply the patches per the "Re-vendoring on upgrade" steps in
   [`charts/README.md`](../charts/README.md) (pull `--untar`, delete `Chart.lock`/`*.tgz`,
   re-add the `condition:` lines and template patches).
3. Commit/push (dev/staging auto-sync; prod sync manually).
4. Watch rollout and verify health.

## Scaling

- API/workers: edit `web_replicas` / `sidekiq_replicas` in
  `environments/<env>/app-values.yaml`.
- Per-developer env size: adjust `resourceQuota` in the `floci-*` templates.

## Promotion (dev → staging → prod)

1. Validate in `dev`.
2. Mirror the change into `environments/staging/*` (and `apps/staging` if needed);
   push; verify.
3. Mirror into `environments/prod/*`; push; **manually sync** the prod root app (or
   enable automated sync once confident).

Keep the three environment trees intentionally similar — differences should be limited
to hostnames, replicas, and (optionally) datastore backing.

## Backups

- **Sealed Secrets key**: back up the controller's sealing key if you need to restore
  SealedSecrets after a controller reinstall.
- **PostgreSQL**: if you keep the in-cluster DB, schedule logical backups
  (`pg_dump`) or move to a managed DB for prod.

## Health checks

```bash
kubectl -n eph-env get pods
kubectl -n eph-env get uffizzicluster
curl -i http://api.dev.local/
argocd app list | grep uffizzi
```

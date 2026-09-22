# 09 — Troubleshooting

## ArgoCD

### Root app shows `Unknown` / `ComparisonError`
- Check `repoURL` is correct and reachable, and `<ORG>` was replaced.
- Ensure ArgoCD has credentials for a private repo.
```bash
argocd app get uffizzi-root-dev
kubectl -n argocd logs deploy/argocd-repo-server | tail
```

### A child app is `OutOfSync` and won't converge
- Look at the diff and events:
```bash
argocd app diff uffizzi-app-dev
argocd app get uffizzi-app-dev
```
- Multi-source value file not found → verify the `ref: values` source `repoURL`/branch
  and that the path `environments/<env>/...` exists on that branch.

### Sync ordering problems
- Confirm `sync-wave` annotations are present. Sealed Secrets (`-3`) must be healthy
  before app/controller need their secrets.

## Sealed Secrets

### `Secret` not created from a `SealedSecret`
```bash
kubectl -n eph-env get sealedsecret
kubectl -n eph-env describe sealedsecret <name>
kubectl -n eph-env logs deploy/sealed-secrets | tail
```
- "no key could decrypt" → the SealedSecret was sealed against a different controller
  key. Re-fetch the cert and re-seal:
  ```bash
  kubeseal --fetch-cert --controller-name sealed-secrets --controller-namespace eph-env > pub-cert.pem
  ```
- Namespace/name mismatch → SealedSecrets are scoped; the target namespace must match
  what you sealed for (`eph-env`).

## uffizzi-app / controller

### App pod crashloops on startup
- Usually missing/incorrect secrets. Confirm the four Secrets exist and keys match the
  chart's expectations:
```bash
kubectl -n eph-env get secret uffizzi-postgres uffizzi-redis uffizzi-controller uffizzi-first-user
kubectl -n eph-env logs deploy/uffizzi-app | tail
```
- If the app started before secrets existed:
```bash
kubectl -n eph-env rollout restart deploy
```

### App can't reach the controller
- Verify `controller_url` in `app-values.yaml` matches the in-cluster service:
  `http://uffizzi-controller.eph-env.svc.cluster.local:8080` (confirm the port).
- Verify controller credentials match on both sides and in the SealedSecret.

## Ingress / HTTP

### `api.<env>.local` not resolving
- Add a hosts entry or local DNS record → node IP (see Prerequisites).

### Getting redirected to HTTPS or connection refused on 443
- A chart default may enable TLS/redirect. Ensure the HTTP-only overrides in
  `controller-values.yaml` are applied and re-render:
```bash
helm template ... | grep -iE 'tls|https|redirect'
```
- Confirm Traefik is the ingress controller and `ingressClassName: traefik` is set.

## Virtual clusters (UffizziCluster)

### `UffizziCluster` stuck / not Ready
```bash
kubectl -n eph-env get uffizzicluster
kubectl -n eph-env describe uffizzicluster dev-<username>
kubectl -n eph-env logs deploy/uffizzi-cluster-operator | tail
```
- Check `resourceQuota` isn't larger than the node can satisfy (single node!). Lower
  the values in the template if pods stay Pending.

### CRD missing
```bash
kubectl get crd | grep uffizzicluster
```
- If absent, the cluster-operator app hasn't synced/installed CRDs yet. Sync it.

### floci emulator / DinD sidecar not starting
The vcluster runs a 2-container pod (`floci` + `dind`) in its `default` namespace.
Get a kubeconfig for the vcluster first (`uffizzi cluster kubeconfig dev-<username>`),
then:
```bash
kubectl get pods -l app=floci-aws        # or app=floci-azure
kubectl logs deploy/floci-aws -c floci   # emulator logs
kubectl logs deploy/floci-aws -c dind    # Docker daemon logs
```
- **Pod rejected / `dind` won't start:** the sidecar needs `privileged: true`. If the
  vcluster (or `eph-env`) enforces Pod Security admission `restricted`/`baseline`, the
  privileged container is denied. Relax the policy for that namespace, or drop the DinD
  sidecar (Docker-backed services will then be unavailable).
- **Docker-backed services fail (Lambda/RDS/Functions/etc.):** confirm the emulator
  points at the sidecar — `DOCKER_HOST=tcp://localhost:2375` (AWS) or
  `FLOCI_AZ_DOCKER_DOCKER_HOST=tcp://localhost:2375` (Azure) — and that `dind` is
  Ready. In-process services (S3/SQS/Blob/Queue/...) work without the sidecar.
- **`azurerm`/Cosmos Java SDK fail against floci-azure:** they require HTTPS. Ensure
  `FLOCI_AZ_TLS_ENABLED=true` and use `https://floci-azure.default.svc:4577`; fetch the
  cert from `GET /_floci/tls-cert`.
- **Cosmos Mongo/Postgres/Cassandra/Gremlin unavailable:** these engines are off by
  default; enable each with `FLOCI_AZ_SERVICES_COSMOS_ENGINES_<API>_ENABLED=true`.
- **Data disappeared after a restart:** expected — storage is `memory` and the DinD
  daemon uses an `emptyDir`, so emulator state and spawned containers are ephemeral.

## Quick diagnostics bundle
```bash
kubectl -n eph-env get pods,svc,ingress,uffizzicluster,sealedsecret,secret
argocd app list | grep uffizzi
kubectl get crd | grep -E 'uffizzi|sealed'
```

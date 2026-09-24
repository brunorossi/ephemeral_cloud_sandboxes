# 05 — Configuration

All configuration lives in Git. The `uffizzi-cluster-operator`, `uffizzi-controller`,
and `uffizzi-app` charts are **vendored** under `charts/` (patched for broken images,
HTTP-only/Traefik, and sealed credentials — see [`charts/README.md`](../charts/README.md));
their values and your presets live in this repo.

## Layout recap

```
apps/<env>/*.yaml                       ArgoCD Applications (what to install)
environments/<env>/
  ├── app-values.yaml                   uffizzi-app Helm values
  ├── controller-values.yaml            uffizzi-controller Helm values (HTTP-only)
  ├── cluster-operator-values.yaml      cluster-operator Helm values
  ├── sealed-secrets/                   encrypted secrets (see 06-secrets)
  └── templates/floci-{aws,azure}.yaml  vcluster + floci.io emulator presets
```

## Placeholders (replace before use)

| Placeholder | Files | Replace with |
|---|---|---|
| `<ORG>` | `bootstrap/*`, `projects/*`, `apps/*` | Your Git org/owner |
| `<username>` | `environments/*/templates/*.yaml` | Developer name |
| `api.<env>.local` | `environments/*`, `apps/*` | Real hostnames if any |
| `<env>.local` | `environments/*` (DNS zone) | Real domain if any |
| chart versions `# <-- verify` | `apps/*` | Pinned versions |
| resource quota / image tags | `environments/*/templates/*.yaml` | Agreed CPU/memory; pin `floci/floci`, `floci/floci-az`, `docker:*-dind` |

Find remaining placeholders:
```bash
grep -rnE "<ORG>|<username>|<-- verify|\.local" --include='*.yaml' .
```

## Per-environment differences

| Setting | dev | staging | prod |
|---|---|---|---|
| API host | `api.dev.local` | `api.staging.local` | `api.prod.local` |
| uffizzi-app `web_replicas` | 1 | 1 | 2 |
| uffizzi-app `sidekiq_replicas` | 1 | 1 | 2 |
| Root app sync | automated | automated | **manual** |
| DB/Redis | in-cluster subcharts | in-cluster | in-cluster (consider managed) |

## uffizzi-app values (`app-values.yaml`)

> **Values structure.** This chart reads app config keys at the **top level**
> (`app_url`, `webHostname`, `ingressClassName`, `controller_url`, `feature_*`,
> `web_replicas` / `sidekiq_replicas` — note **underscores**), **not** under an
> `uffizzi:` block. Credentials go under `global.uffizzi.*`. A nested `uffizzi:`
> block is silently ignored (chart falls back to its `uffizzi.example.com` defaults).

Key fields:
- `app_url` / `webHostname` — the HTTP API endpoint (host used by the web Ingress).
- `ingressClassName: traefik` — routes the API Ingress through Traefik.
- `controller_url` / `vcluster_controller_url` — the in-cluster **standalone**
  controller service in `eph-env`
  (`http://uffizzi-controller.eph-env.svc.cluster.local:8080`).
- `global.uffizzi.controller.username` — must match `controller-values.yaml` + the
  controller env-secret.
- `global.uffizzi.firstUser.email` — first admin (password arrives via the
  `uffizzi-web-envs` SealedSecret).
- `feature_*` flags — kept `false` for a minimal OSS setup.
- `postgresql.enabled` / `redis.enabled` — `true` for in-cluster datastores; both
  point at their sealed secret via `existingSecret`.
- `externalSecret: uffizzi-web-envs` — the sealed app env-secret layered over the
  chart defaults (see [Secrets](06-secrets.md)).
- `uffizzi-controller.enabled: false` — disables the redundant embedded controller
  stack (nginx/cert-manager/duplicate controller); the controller runs standalone.

> Passwords are **never** in this file; they come from SealedSecrets (`uffizzi-web-envs`
> for the app, `uffizzi-postgres`/`uffizzi-redis` for the datastores). See
> [Secrets](06-secrets.md).

## uffizzi-controller values (`controller-values.yaml`)

HTTP-only is enforced here:
- `ingress.hostname: api.<env>.local` + `ingress.className: traefik` — HTTP host via Traefik.
- `clusterIssuer: ""` and `certEmail: ""` — no ACME.
- `cert-manager.enabled: false` — no cert-manager (dependency disabled via the
  vendored chart's `condition`).
- `ingress-nginx.enabled: false` — no embedded nginx (floci is Traefik-only).
- `uffizzi-cluster-operator.enabled: false` — the operator runs standalone
  (`01-uffizzi-cluster-operator.yaml`); the embedded copy is disabled to avoid
  duplicate Flux resources.
- `externalSecret: uffizzi-controller-env` — sealed controller creds layered over
  the chart defaults (see [Secrets](06-secrets.md)).
- `podCidr` — set to the K3s pod CIDR (default `10.42.0.0/16`; verify on the node).

> These embedded-dependency disables require `condition:` lines added in the
> **vendored** `charts/uffizzi-controller/Chart.yaml` — see [`charts/README.md`](../charts/README.md).
> Validate the rendered ingress with `helm template` (see [Operations](08-operations.md#validation)).

## cluster-operator values (`cluster-operator-values.yaml`)

> **Note:** `uffizzi-cluster-operator` is deployed from the **vendored chart** at
> `charts/uffizzi-cluster-operator` (its `apps/<env>/01-uffizzi-cluster-operator.yaml`
> Application uses a single `path:` source, **not** this values file). The image
> fixes (ghcr.io Flux images + quay.io kube-rbac-proxy) are baked into the vendored
> chart's own `values.yaml`. This file is retained for reference / future
> env-specific tuning; to use it again, add a `helm.valueFiles` entry to the
> operator Application. See [`charts/README.md`](../charts/README.md).

Defaults are fine on a single node. No node selectors/labels are used (single node).

## Resource templates (`templates/floci-*.yaml`)

Two `UffizziCluster` presets. Each creates a vcluster and deploys a
[floci.io](https://floci.io) local cloud emulator **inside** it via
`spec.manifests` (a Deployment + Service in the vcluster's `default` namespace):

| Template | Emulator (image) | Endpoint (in-vcluster) | Ingress host | limits (cpu/mem) |
|---|---|---|---|---|
| `floci-aws` | AWS — `floci/floci` (+ DinD sidecar) | `http://floci-aws.default.svc:4566` | `floci-aws-<username>.<env>.local` | `3` / `4Gi` |
| `floci-azure` | Azure — `floci/floci-az` (+ DinD sidecar, TLS) | `http://floci-azure.default.svc:4577` (also HTTPS) | `floci-azure-<username>.<env>.local` | `3` / `4Gi` |

Each `spec.manifests` block deploys the emulator as a Deployment + Service + Ingress
in the vcluster's `default` namespace; Uffizzi exposes the Ingress through the host
cluster (plain HTTP). The two templates differ only by the **emulator** — quota,
distro, ingress class, and storage are identical.

- Change sizes by editing the `resourceQuota.requests` / `resourceQuota.limits` blocks.
- The emulator Deployment/Service live in the `spec.manifests` block. Pin the
  image tags (`floci/floci:x.y.z`, `floci/floci-az:x.y.z`, `docker:x.y.z-dind`)
  rather than `:latest` for reproducible environments.

### Docker-backed services (both templates)

Each template runs a **Docker-in-Docker (DinD) sidecar** alongside the emulator so
that floci's Docker-backed services work in addition to the in-process ones. The
emulator talks to the sidecar's private daemon (`tcp://localhost:2375`); the node's
own Docker/containerd socket is **not** mounted.

- **`floci-aws`** (`DOCKER_HOST=tcp://localhost:2375`):
  - In-process: S3, SQS, SNS, DynamoDB, IAM, STS, KMS, Secrets Manager, SSM,
    API Gateway, Cognito, EventBridge, Step Functions, CloudFormation, Kinesis,
    SES, Route53, CloudWatch, and more.
  - Docker-backed: Lambda, RDS, ElastiCache, MemoryDB, ECS, EC2, EKS, MSK,
    OpenSearch, Neptune, DocumentDB, CodeBuild, MWAA, Flink.
- **`floci-azure`** (`FLOCI_AZ_DOCKER_DOCKER_HOST=tcp://localhost:2375`):
  - In-process: Blob, Queue, Table, App Configuration, Key Vault, Cosmos DB
    NoSQL/SQL (embedded), API Management, Event Grid, Azure Monitor/Logs,
    Communication Email, Managed Identity, Entra ID, Microsoft Graph.
  - Docker-backed: Azure Functions, Event Hubs, Service Bus, Azure SQL, Azure DB
    for PostgreSQL/MySQL/MariaDB, AKS, Container Apps, Azure Cache for Redis,
    Container Registry, and the Cosmos multi-API engines.
  - **TLS is enabled** (`FLOCI_AZ_TLS_ENABLED=true`) — HTTP and HTTPS are served on
    the same port 4577. This is required by the Cosmos DB Java SDK and the
    Terraform/OpenTofu `azurerm` provider (which discovers the cloud over HTTPS).
    Fetch the runtime cert from `GET /_floci/tls-cert`.
  - The Cosmos multi-API engines (Mongo/Postgres/Cassandra/Gremlin) are **disabled
    by default** even with Docker; enable each with
    `FLOCI_AZ_SERVICES_COSMOS_ENGINES_<API>_ENABLED=true`.

> **Security & cost.** The DinD sidecar runs `privileged: true`. This is scoped to
> the pod (not the host) and isolated per developer vcluster, but a privileged
> container is a meaningfully larger attack surface than an in-process-only setup.
> It also consumes more resources — hence the raised quota (limits `3` CPU / `4Gi`).
> The DinD daemon uses an `emptyDir`, so containers it spawns and their data are
> **ephemeral** (lost on pod restart). Consider dropping the sidecar from `prod`
> if you don't need Docker-backed services there.

## Pinning / upgrading chart versions

The `uffizzi-cluster-operator`, `uffizzi-controller`, and `uffizzi-app` charts are
**vendored** under `charts/`, so there is no `targetRevision` to bump — the version is
whatever is committed. To move to a newer upstream version, re-vendor and re-apply the
patches following the per-chart "Re-vendoring on upgrade" steps in
[`charts/README.md`](../charts/README.md):
```bash
helm repo add uffizzi-app https://uffizzicloud.github.io/uffizzi_app
helm search repo uffizzi-app --versions | head   # find the target version
# then: helm pull ... --untar, copy into charts/, delete Chart.lock/*.tgz, re-apply patches
```

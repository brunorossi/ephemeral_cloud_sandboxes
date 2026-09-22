# 05 — Configuration

All configuration lives in Git. Charts come from upstream Helm repos; their values and
your presets live in this repo.

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
| uffizzi-app `web-replicas` | 1 | 1 | 3 |
| uffizzi-app `sidekiq-replicas` | 1 | 1 | 2 |
| Root app sync | automated | automated | **manual** |
| DB/Redis | in-cluster subcharts | in-cluster | in-cluster (consider managed) |

## uffizzi-app values (`app-values.yaml`)

Key fields:
- `uffizzi.app_url` / `uffizzi.webHostname` — the HTTP API endpoint.
- `uffizzi.controller_url` — in-cluster controller service in `eph-env`.
- `uffizzi.controller.username` — must match `controller-values.yaml` + the
  `uffizzi-controller` SealedSecret.
- `uffizzi.firstUser.email` — first admin (password comes from a SealedSecret).
- `feature_*` flags — kept `false` for a minimal OSS setup.
- `postgresql.enabled` / `redis.enabled` — `true` for in-cluster datastores.

> Passwords are **never** in this file; they come from SealedSecrets. Wire them via
> the chart's `existingSecret` mechanism (confirm exact keys with
> `helm show values uffizzi-app/uffizzi-app`).

## uffizzi-controller values (`controller-values.yaml`)

HTTP-only is enforced here:
- `clusterIssuer: ""` and `certEmail: ""` — no ACME.
- `cert-manager.enabled: false`, `cert-manager.installCRDs: false` — no cert-manager.
- `ingress.hostname: api.<env>.local` — HTTP host via Traefik.
- `podCidr` — set to the K3s pod CIDR (default `10.42.0.0/16`; verify on the node).

> If a chart version defaults to HTTPS or an HTTP→HTTPS redirect, override it here.
> Validate the rendered ingress with `helm template` (see [Operations](08-operations.md#validation)).

## cluster-operator values (`cluster-operator-values.yaml`)

Defaults are fine on a single node. Pin the image tag and chart version. No node
selectors/labels are used (single node).

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

## Pinning chart versions

Replace `"*"` / `# <-- verify` in `apps/<env>/*.yaml` with explicit versions:
```bash
helm repo add uffizzi-app https://uffizzicloud.github.io/uffizzi_app
helm search repo uffizzi-app --versions | head
```
Pin the chosen version in the Application `targetRevision`.

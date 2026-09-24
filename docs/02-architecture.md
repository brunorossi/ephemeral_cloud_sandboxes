# 02 — Architecture

## High-level picture

```
                         ┌──────────────────────────────────────────────┐
                         │                Single-node K3s                │
                         │                                               │
  Developer ──CLI──HTTP──▶  Traefik ingress (HTTP)                       │
                         │        │                                       │
                         │        ▼                                       │
                         │   uffizzi-app (Rails API + Sidekiq)  ns:eph-env│
                         │        │           │                          │
                         │        │           ├─ PostgreSQL (subchart)    │
                         │        │           └─ Redis (subchart)         │
                         │        ▼                                       │
                         │   uffizzi-controller  ──────▶  Kubernetes API  │
                         │        ▼                                       │
                         │   uffizzi-cluster-operator                     │
                         │        ▼                                       │
                         │   UffizziCluster (vcluster) = 1 per developer  │
                         │        profile: floci-aws | floci-azure        │
                         └──────────────────────────────────────────────┘
```

## GitOps control flow (app-of-apps)

```
ArgoCD (pre-installed, ns: argocd)
 └─ AppProject "uffizzi"                (added by this repo, into ns argocd)
     └─ Root Application per env         (bootstrap/root-app-<env>.yaml)
         │  watches apps/<env>/ (recurse)
         ├─ 00-sealed-secrets            sync-wave -3   → ns eph-env
         ├─ 01-uffizzi-cluster-operator  sync-wave -1   → ns eph-env
         ├─ 02-uffizzi-controller        sync-wave  0   → ns eph-env
         └─ 03-uffizzi-app               sync-wave  1   → ns eph-env
         # (no floci-templates Application: the floci-aws/floci-azure presets
         #  contain <username> placeholders and are created per-developer via
         #  the Uffizzi CLI / sed-substitution, not managed by ArgoCD.)
```

- **Root Application** points at `apps/<env>` with `directory.recurse: true`, so every
  Application YAML there becomes a managed child. Add/remove a file → add/remove a
  component.
- **sync-wave** annotations guarantee ordering: Sealed Secrets first (so other
  components' secrets can be decrypted), then operator, controller, app.
- Child Applications read their values file from this Git repo via a `ref: values`
  source. **All three Uffizzi charts are served from vendored copies in this repo**
  (`charts/uffizzi-cluster-operator`, `charts/uffizzi-controller`, `charts/uffizzi-app`,
  referenced by `path:`) because the upstream charts ship broken image references and
  nginx/cert-manager/TLS defaults that cannot be overridden via values, and embed
  redundant sub-stacks. `uffizzi-cluster-operator` is single-source (`path:` only);
  `uffizzi-controller` and `uffizzi-app` are multi-source (`path:` chart + `ref: values`).
  See [Repository reference](10-repository-reference.md) and
  [`charts/README.md`](../charts/README.md).

## Components

| Component | Kind | Purpose |
|---|---|---|
| Sealed Secrets controller | Helm release | Decrypts `SealedSecret` → `Secret` in `eph-env` |
| uffizzi-cluster-operator | Helm release (vendored chart) | Reconciles `UffizziCluster` CRs into vclusters |
| uffizzi-controller | Helm release | Proxies Uffizzi API calls to the Kubernetes API |
| uffizzi-app | Helm release | REST API (Rails) + Sidekiq workers; CLI endpoint |
| PostgreSQL | subchart | Primary datastore for uffizzi-app |
| Redis | subchart | Cache / Sidekiq queue backend |

## Namespaces

| Namespace | Contents | Managed by this repo? |
|---|---|---|
| `argocd` | AppProject, root + child Applications | Objects yes; namespace no (pre-exists) |
| `eph-env` | Control plane + all developer vclusters | Yes (auto-created) |

## Data model

- **`UffizziCluster`** (`uffizzi.com/v1alpha1`): one per developer. Resource sizing is
  set under `spec.resourceQuota.{requests,limits}` (cpu, memory, ephemeralStorage,
  storage). Each template also carries a `spec.manifests` block that deploys a
  [floci.io](https://floci.io) emulator plus a DinD sidecar inside the vcluster (AWS
  for `floci-aws`, Azure for `floci-azure`). The **emulator** is the only thing that
  differs between the two templates — quota and everything else are identical.
- **`SealedSecret`** (bitnami): encrypted; the controller emits the plain `Secret` at
  runtime in `eph-env`. Only the SealedSecret is committed.

## Network / ingress

- K3s bundles **Traefik**; all ingress uses `ingressClassName: traefik`.
- **No TLS at the ingress**: the API is reachable at `http://api.<env>.local`.
  Ephemeral env hosts follow `http://dev-<username>.<env>.local`. Each vcluster also
  publishes its emulator via an in-vcluster Ingress that Uffizzi exposes through the
  host cluster: `http://floci-aws-<username>.<env>.local` /
  `http://floci-azure-<username>.<env>.local` (plain HTTP).
- `.local` names must resolve to the node IP (hosts file or local DNS) — see
  [Installation](04-installation.md#dns).

## What the templates deploy

Each template creates a *virtual* control plane whose workloads schedule onto the
host node, and deploys a [floci.io](https://floci.io) local cloud emulator inside it
via `spec.manifests` (Deployment + Service + Ingress in the vcluster's `default`
namespace):

- `floci-aws` → AWS emulator (`floci/floci`, port 4566) + a privileged
  Docker-in-Docker sidecar.
- `floci-azure` → Azure emulator (`floci/floci-az`, port 4577, HTTP+HTTPS) + a
  privileged DinD sidecar.

Both share the same quota (limits `3` CPU / `4Gi`). With a single node there is
exactly one place for pods to run, so a genuine "AWS vs Azure" *placement* is not
possible. The distinction is therefore just the **emulator** each template runs,
while distro, ingress, storage, and quota stay identical. This keeps the developer
UX (`floci-aws` / `floci-azure`) stable and forward-compatible if real nodes are
added later.

Each template includes a DinD sidecar (no host socket mounted), so both in-process
and Docker-backed services work: `floci-aws` via `DOCKER_HOST=tcp://localhost:2375`,
`floci-azure` via `FLOCI_AZ_DOCKER_DOCKER_HOST=tcp://localhost:2375`. floci-azure also
sets `FLOCI_AZ_TLS_ENABLED=true` (Cosmos Java SDK / azurerm need HTTPS). The sidecars
run `privileged: true`, scoped to the pod.

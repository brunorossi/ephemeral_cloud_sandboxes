# Design — Uffizzi self-hosted on floci (single-node K3s)

## Overview

A GitOps repository that installs Uffizzi Open Source on a **single-node K3s**
cluster via **ArgoCD** (app-of-apps), serving everything over **HTTP** through
Traefik, with secrets managed by **Sealed Secrets**. Developers use the Uffizzi CLI
to create **one virtual cluster each**, choosing between two resource-size templates:
`floci-aws` and `floci-azure`.

### Environment / prerequisites
- **ArgoCD is already installed** in the cluster in its own namespace. This repo
  does **not** install ArgoCD nor manage the `argocd` namespace. It only adds an
  `AppProject` and the root Applications into the existing `argocd` namespace.
- All Uffizzi control-plane workloads and per-developer virtual clusters live in the
  **`eph-env`** namespace.

### Key facts grounding the design (verified)
- Uffizzi OSS components: `uffizzi-app` (Rails API + Sidekiq), `uffizzi-controller`
  (proxy to k8s API), `uffizzi-cluster-operator` (manages `UffizziCluster` → vcluster),
  plus PostgreSQL + Redis. The Dashboard is not open source (excluded).
- A vcluster is a virtual control plane running as pods in a host namespace; its
  workloads schedule onto the host node. On a single node, all vclusters share it.
- Consequence: `floci-aws`/`floci-azure` can only differ by **resource size** here.

### Items to confirm during implementation (could not fully verify)
- Exact `UffizziCluster` CRD fields for resource sizing in the current
  `uffizzi-cluster-operator` chart.
- Whether the CLI exposes template selection directly, or creation uses an
  `UffizziCluster` manifest carrying the chosen resource profile.
- Exact ingress values keys per chart to force HTTP-only.

## Architecture

```
Developer ── Uffizzi CLI ──HTTP──▶ uffizzi-app (API)  ──▶ uffizzi-controller ──▶ K3s API
                                        │                                          │
                                   PostgreSQL, Redis                    uffizzi-cluster-operator
                                     (ns: eph-env)                          (ns: eph-env)
                                                                                   │
                                                                        UffizziCluster (vcluster)
                                                                        = one per developer
                                                                        profile: floci-aws | floci-azure
```

GitOps control flow:
```
ArgoCD (existing, ns: argocd)
 └─ AppProject: uffizzi   (created by this repo, in ns argocd)
     └─ root Application (per env)  ── watches apps/<env>/ (recurse)
          ├─ 00-sealed-secrets           (sync-wave -3)  → ns eph-env  (controller)
          ├─ 00b-sealed-secrets-resources(sync-wave -2)  → ns eph-env  (SealedSecret CRs)
          ├─ 01-uffizzi-cluster-operator (sync-wave -1)  → ns eph-env
          ├─ 02-uffizzi-controller       (sync-wave  0)  → ns eph-env
          └─ 03-uffizzi-app              (sync-wave  1)  → ns eph-env
          # NOTE (superseded): the original design included a
          # 04-floci-templates Application at sync-wave 2. It was dropped —
          # the floci-* presets contain <username> placeholders (not valid
          # RFC 1123 names) and are applied per-developer via the Uffizzi CLI,
          # not managed by ArgoCD. See docs/10-repository-reference.md.
```

## Repository structure

```
uffizzi-floci/
├── PROJECT.md
├── README.md
├── .gitignore
├── bootstrap/
│   ├── root-app-dev.yaml            # NOTE: no argocd-namespace.yaml (ArgoCD pre-exists)
│   ├── root-app-staging.yaml
│   └── root-app-prod.yaml
├── projects/
│   └── uffizzi-project.yaml         # ArgoCD AppProject "uffizzi" (into existing ns argocd)
├── apps/
│   ├── dev/ | staging/ | prod/
│   │   ├── 00-sealed-secrets.yaml
│   │   ├── 00b-sealed-secrets-resources.yaml   # syncs the SealedSecret CRs
│   │   ├── 01-uffizzi-cluster-operator.yaml
│   │   ├── 02-uffizzi-controller.yaml
│   │   └── 03-uffizzi-app.yaml
│   │   # (no 04-floci-templates.yaml — superseded; presets applied per-developer)
└── environments/
    ├── dev/ | staging/ | prod/
    │   ├── app-values.yaml
    │   ├── controller-values.yaml
    │   ├── cluster-operator-values.yaml
    │   ├── sealed-secrets/          # SealedSecret manifests (encrypted)
    │   └── templates/               # floci-aws / floci-azure UffizziCluster presets
    │       ├── floci-aws.yaml
    │       └── floci-azure.yaml
```

## Components and design decisions

### 1. ArgoCD app-of-apps (into existing ArgoCD)
- This repo adds an `AppProject` (`uffizzi`) and root Applications into the existing
  `argocd` namespace. It does not touch the ArgoCD installation.
- The `AppProject` restricts source repos and allowed destination namespaces
  (`argocd`, `eph-env`).
- One root Application per environment watches `apps/<env>` with `directory.recurse`.
- Child Applications use ArgoCD **multi-source**: chart from the Helm repo + values
  read from this Git repo via a `ref: values` source.
- Ordering via `sync-wave` (see diagram).

### 2. HTTP-only via Traefik (no TLS)
- No cert-manager, no ClusterIssuer (Requirement 3).
- Ingress uses `ingressClassName: traefik`; chart HTTPS/redirect defaults overridden
  in per-env values to serve plain HTTP at `api.<env>.local`.
- `.local` names resolve via hosts file / local DNS (documented).

### 3. Uffizzi control plane (ns: eph-env)
- `uffizzi-app` values: `env`, `app_url: http://api.<env>.local`, `webHostname`,
  replica counts (dev=1, prod higher), `controller_url` at the in-cluster controller
  service in `eph-env`, feature flags off for a minimal OSS setup.
- PostgreSQL and Redis as subcharts in dev/staging; prod may use managed data stores
  (documented, optional).
- Controller ↔ app shared credentials from Sealed Secrets.

### 4. One virtual cluster per developer
- Naming convention `dev-<username>` enforces uniqueness in `eph-env`.
- Single-per-developer invariant enforced operationally (naming + optional quota);
  documented in PROJECT.md and TASKS.
- Developer obtains a kubeconfig from the CLI to reach their vcluster.

### 5. floci-aws / floci-azure templates (resource size only)
- Two `UffizziCluster` preset manifests, identical except the resources block.
  Illustrative (exact CRD field names verified against the chart during impl):

  ```yaml
  # floci-aws.yaml (smaller)
  # resources:
  #   requests: { cpu: "500m", memory: "1Gi" }
  #   limits:   { cpu: "1",    memory: "2Gi" }

  # floci-azure.yaml (larger)
  # resources:
  #   requests: { cpu: "1",    memory: "2Gi" }
  #   limits:   { cpu: "2",    memory: "4Gi" }
  ```
- Everything else identical (k8s version, add-ons, networking) — Requirement 5.5.
- Selected by the developer at create time; applied to their single `UffizziCluster`.

### 6. Sealed Secrets
- Controller deployed first (sync-wave -3).
- All credentials (`postgres`, `redis`, controller creds, first admin user) stored as
  `SealedSecret` under `environments/<env>/sealed-secrets/`, decrypted into `eph-env`.
- No plaintext secrets in Git. `kubeseal` workflow documented in TASKS.

## Data model
- `UffizziCluster` (CRD): one per developer, carries chosen resource profile.
- `SealedSecret` → decrypted to `Secret` in `eph-env` at runtime.

## Error handling
- ArgoCD self-heal + prune keep the cluster converged; failures surface in the UI.
- HTTP override in values is the single source of truth if a chart defaults to HTTPS;
  verified via `helm template`.
- Missing decrypted `Secret` indicates a sealing/key mismatch; recovery = re-seal
  with the controller's public cert.

## Testing strategy
- **Static**: YAML validation (`yq`), `helm template` render per chart+values,
  `kubectl apply --dry-run=client` on rendered manifests and on `UffizziCluster` presets.
- **Bootstrap**: apply `AppProject` + root app into existing ArgoCD; verify all child
  apps reach `Synced/Healthy` and land in `eph-env`.
- **Functional**: create a developer vcluster with `floci-aws`, then `floci-azure`;
  verify exactly one vcluster per developer and that specs differ only in resource size.
- **HTTP**: confirm `api.<env>.local` responds over HTTP (no TLS) via Traefik.

## Placeholders (single source of truth)
| Placeholder | Where | Replace with |
|---|---|---|
| `<ORG>` | bootstrap/, projects/, apps/* | Git org/owner |
| `*.dev.local` / `*.staging.local` / `*.prod.local` | environments/*, apps/* | real hostnames if any |
| chart versions (`<-- verify`) | apps/* | pinned versions |
| resource sizes | environments/*/templates | agreed CPU/memory |

## Out of scope
- Uffizzi Dashboard UI (not open source).
- TLS/HTTPS and certificate management.
- Installing/managing ArgoCD (pre-existing).
- Real AWS/Azure infrastructure or node placement; multi-node topologies.

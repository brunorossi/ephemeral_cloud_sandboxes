# 10 — Repository Reference

Every file and folder in the repo, with its purpose.

## Tree

```
uffizzi-floci/
├── README.md                         # Repo quickstart
├── PROJECT.md                        # Project summary & decisions
├── .gitignore                        # Ignores rendered output, kubeconfigs, plaintext secrets
├── docs/                             # This documentation set
│   ├── README.md                     # Docs index
│   ├── 01-overview.md
│   ├── 02-architecture.md
│   ├── 03-prerequisites.md
│   ├── 04-installation.md
│   ├── 05-configuration.md
│   ├── 06-secrets.md
│   ├── 07-developer-guide.md
│   ├── 08-operations.md
│   ├── 09-troubleshooting.md
│   └── 10-repository-reference.md
├── scripts/
│   └── seal-secrets.sh               # kubeseal helper to generate SealedSecrets
├── projects/
│   └── uffizzi-project.yaml          # ArgoCD AppProject "uffizzi" (into existing argocd ns)
├── bootstrap/
│   ├── root-app-dev.yaml             # app-of-apps root (dev, automated sync)
│   ├── root-app-staging.yaml         # app-of-apps root (staging, automated sync)
│   └── root-app-prod.yaml            # app-of-apps root (prod, MANUAL sync)
├── apps/                             # ArgoCD child Applications, per environment
│   ├── dev/ | staging/ | prod/
│   │   ├── 00-sealed-secrets.yaml            # sync-wave -3
│   │   ├── 01-uffizzi-cluster-operator.yaml  # sync-wave -1
│   │   ├── 02-uffizzi-controller.yaml        # sync-wave  0 (HTTP-only)
│   │   └── 03-uffizzi-app.yaml               # sync-wave  1
│   │   # NOTE: no floci-templates Application. The floci-aws/floci-azure
│   │   # presets under environments/<env>/templates/ contain <username>
│   │   # placeholders and are NOT managed by ArgoCD (a literal "<username>"
│   │   # name is not a valid RFC 1123 object name). Create per-developer
│   │   # vclusters via the Uffizzi CLI or by sed-substituting <username> and
│   │   # applying a copy. See docs/07-developer-guide.md.
└── environments/                     # Helm values + presets + secrets, per environment
    ├── dev/ | staging/ | prod/
    │   ├── app-values.yaml                   # uffizzi-app values
    │   ├── controller-values.yaml            # uffizzi-controller values (HTTP-only)
    │   ├── cluster-operator-values.yaml      # cluster-operator values
    │   ├── sealed-secrets/
    │   │   └── README.md                     # what to seal (+ generated SealedSecrets)
    │   └── templates/
    │       ├── floci-aws.yaml                # AWS emulator (floci/floci:4566) + DinD sidecar
    │       └── floci-azure.yaml              # Azure emulator (floci/floci-az:4577, TLS) + DinD sidecar
├── charts/                            # Vendored Helm charts (patched)
│   ├── README.md                      # why vendored + re-vendoring steps
│   └── uffizzi-cluster-operator/      # patched operator chart (image fixes)
├── scripts/
│   └── seal-secrets.sh               # generate SealedSecrets from env vars
└── .kiro/specs/uffizzi-floci/         # Formal spec (requirements/design/tasks)
```

## File-by-file

### Top level
| File | Purpose |
|---|---|
| `README.md` | Fast quickstart and placeholder table |
| `PROJECT.md` | Decisions, components, per-dev model |
| `.gitignore` | Prevents committing rendered output and plaintext secrets |

### `projects/`
| File | Purpose |
|---|---|
| `uffizzi-project.yaml` | ArgoCD `AppProject` restricting source repos and destination namespaces (`argocd`, `eph-env`) |

### `bootstrap/`
| File | Purpose |
|---|---|
| `root-app-dev.yaml` | Root Application watching `apps/dev` (automated sync) |
| `root-app-staging.yaml` | Same for staging |
| `root-app-prod.yaml` | Same for prod, but manual sync by default |

### `apps/<env>/`
Each file is an ArgoCD `Application`. Numeric prefix hints the intended order and maps
to a `sync-wave`. Most Applications are multi-source (chart from a Helm repo, values
from this Git repo via `ref: values`). **`01-uffizzi-cluster-operator.yaml` is the
exception:** it is single-source and points at the **vendored chart** at
`charts/uffizzi-cluster-operator` (`path:`), because the upstream chart ships broken
image references that values cannot override (see [`charts/README.md`](../charts/README.md)).
All deploy into `eph-env`.

### `environments/<env>/`
| File/Dir | Purpose |
|---|---|
| `app-values.yaml` | uffizzi-app Helm values (HTTP endpoint, replicas, feature flags) |
| `controller-values.yaml` | uffizzi-controller values; disables TLS/cert-manager |
| `cluster-operator-values.yaml` | cluster-operator values (defaults on single node) |
| `sealed-secrets/` | Encrypted `SealedSecret` manifests + a how-to README |
| `templates/floci-aws.yaml` | `UffizziCluster` preset: AWS emulator (`floci/floci`) + DinD sidecar + Ingress (`floci-aws-<username>.<env>.local`) |
| `templates/floci-azure.yaml` | `UffizziCluster` preset: Azure emulator (`floci/floci-az`, TLS) + DinD sidecar + Ingress (`floci-azure-<username>.<env>.local`); differs from floci-aws only by the emulator |

### `scripts/`
| File | Purpose |
|---|---|
| `seal-secrets.sh` | Generates the four required SealedSecrets from env vars via `kubeseal` |

### `charts/`
| File/Dir | Purpose |
|---|---|
| `README.md` | Why charts are vendored and how to re-vendor on upgrade |
| `uffizzi-cluster-operator/` | Vendored operator chart (1.6.5) patched to fix retired `gcr.io/kubebuilder/kube-rbac-proxy` and deleted `bitnami/fluxcd-*` images |

### `.kiro/specs/uffizzi-floci/`
| File | Purpose |
|---|---|
| `requirements.md` | EARS-format requirements |
| `design.md` | Architecture and design decisions |
| `tasks.md` | Implementation checklist with requirement mapping |

## Naming & conventions
- Child Application names: `<component>-<env>` (e.g. `uffizzi-app-dev`).
- Virtual cluster names: `dev-<username>` (one per developer).
- Environment hosts: `api.<env>.local`, env apps at `dev-<username>.<env>.local`.
- Sync-waves: `-3` secrets, `-1` operator, `0` controller, `1` app, `2` templates.

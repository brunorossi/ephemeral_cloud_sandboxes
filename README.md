# uffizzi-floci

Uffizzi Open Source on a **single-node K3s** cluster, deployed via **ArgoCD**
(app-of-apps), **HTTP-only** through Traefik, secrets via **Sealed Secrets**.
Developers create **one virtual cluster each**, choosing between two resource-size
templates: **`floci-aws`** and **`floci-azure`**.

> The Uffizzi web Dashboard is **not** open source and is **excluded**. Management is
> via the Uffizzi CLI against the self-hosted API.

Full spec: [`.kiro/specs/uffizzi-floci/`](.kiro/specs/uffizzi-floci/)
(`requirements.md`, `design.md`, `tasks.md`).

**📖 Full documentation:** [`docs/`](docs/README.md) — overview, architecture,
installation, configuration, secrets, developer & operations guides, troubleshooting,
and a repository reference.

## Prerequisites
- Single-node **K3s** with the bundled **Traefik** ingress.
- **ArgoCD already installed** in the cluster (its own namespace). This repo does
  **not** install or manage ArgoCD.
- CLI tools: `kubectl`, `helm`, `kubeseal`, and the `uffizzi` CLI.
- Uffizzi workloads run in the **`eph-env`** namespace.

## Quickstart
```bash
# 1) Register the AppProject and the dev root app into the existing ArgoCD
kubectl apply -f projects/uffizzi-project.yaml
kubectl apply -f bootstrap/root-app-dev.yaml

# 2) ArgoCD reconciles apps/dev/* in order (Sealed Secrets → operator → controller → app → templates)

# 3) Resolve the API hostname locally (HTTP, no TLS), e.g. add to /etc/hosts:
#    <node-ip>  api.dev.local

# 4) Log in with the Uffizzi CLI and create a personal vcluster
uffizzi login --server http://api.dev.local
uffizzi cluster create dev-<username>   # choose floci-aws or floci-azure
```

## Sealed Secrets workflow
```bash
# Fetch the controller's public cert (once the controller is running)
kubeseal --fetch-cert \
  --controller-name sealed-secrets --controller-namespace eph-env \
  > pub-cert.pem

# Create a plaintext Secret locally (DO NOT COMMIT), then seal it
kubectl -n eph-env create secret generic uffizzi-db \
  --from-literal=password='REDACTED' --dry-run=client -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml \
  > environments/dev/sealed-secrets/uffizzi-db.yaml   # this IS safe to commit
```

## Repository layout
```
bootstrap/       root Applications (app-of-apps) per environment
projects/        ArgoCD AppProject "uffizzi" (into existing argocd ns)
apps/<env>/      one ArgoCD Application per component (sync-wave ordered)
environments/<env>/
  ├── *-values.yaml        Helm values per component
  ├── sealed-secrets/      encrypted SealedSecret manifests (safe to commit)
  └── templates/           floci-aws.yaml / floci-azure.yaml (vcluster + floci.io emulator presets)
```

## Placeholders to replace
| Placeholder | Where | Replace with |
|---|---|---|
| `<ORG>` | bootstrap/, projects/, apps/* | your Git org/owner |
| `*.dev.local` / `*.staging.local` / `*.prod.local` | environments/*, apps/* | real hostnames if any |
| chart versions marked `# <-- verify` | apps/* | pinned versions |
| resource quota / image tags | environments/*/templates/*.yaml | agreed CPU/memory; pin `floci/floci`, `floci/floci-az`, `docker:*-dind` |

## Environments
| Env | API host | Notes |
|---|---|---|
| dev | `api.dev.local` | 1 replica, in-cluster DB/Redis |
| staging | `api.staging.local` | pre-prod |
| prod | `api.prod.local` | higher replicas; consider managed DB |

## Notes
- **No TLS/HTTPS**: all ingress is plain HTTP via Traefik (`ingressClassName: traefik`).
- **One vcluster per developer**: naming convention `dev-<username>`.
- **floci-aws vs floci-azure**: each deploys a [floci.io](https://floci.io) emulator
  inside the vcluster — **AWS** (`floci/floci`, port 4566) for `floci-aws`, **Azure**
  (`floci/floci-az`, port 4577, TLS) for `floci-azure`. Both include a privileged
  Docker-in-Docker sidecar (so Docker-backed services work) and share the same
  quota. The emulator is the only difference.
# ephemeral_cloud_sandboxes
# ephemeral_cloud_sandboxes

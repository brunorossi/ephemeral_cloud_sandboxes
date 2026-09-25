# 01 — Overview

## What this project is

`uffizzi-floci` is a GitOps repository that installs and operates **Uffizzi Open
Source** on a single-node K3s cluster. It lets developers spin up isolated,
ephemeral Kubernetes environments ("virtual clusters") on demand, each sized by a
named template.

The entire stack is declarative: ArgoCD reconciles the desired state from Git, so the
cluster always matches what is committed.

## Goals

- One-command-ish, reproducible install of the Uffizzi control plane.
- **One virtual cluster per developer**, self-service via the Uffizzi CLI.
- A simple **cloud selector**: `floci-aws` (AWS emulator) or `floci-azure` (Azure emulator).
- Multi-environment layout (`dev`, `staging`, `prod`) from a single repo.
- No secrets in clear text (Sealed Secrets).

## Key decisions

| Decision | Value | Rationale |
|---|---|---|
| Orchestration | ArgoCD app-of-apps | Declarative GitOps, easy component add/remove |
| Platform | Single-node K3s | Target environment; Traefik ships built-in |
| Ingress | Traefik, **HTTP-only** | No certificate management required |
| Namespace | `eph-env` | All Uffizzi workloads + vclusters live here |
| Secrets | Sealed Secrets | Encrypted-at-rest, safe to commit |
| ArgoCD | **Pre-installed** | This repo only adds an AppProject + root apps |
| Dashboard | **Excluded** | Not open source (see Scope) |
| `floci-aws` vs `floci-azure` | **Emulator only** | AWS vs Azure emulator; identical quota; single node → no real placement difference |

## Scope

### In scope
- Uffizzi control plane: `uffizzi-cluster-operator`, `uffizzi-controller`,
  `uffizzi-app` (+ PostgreSQL, Redis).
- Sealed Secrets controller.
- Two vcluster templates (`floci-aws`, `floci-azure`), each deploying a
  [floci.io](https://floci.io) local cloud emulator (AWS / Azure) inside the vcluster.
- dev / staging / prod environments.

### Out of scope
- **Uffizzi web Dashboard** — it is not distributed as open source. There is no
  public chart or image; the UI is served by Uffizzi Cloud (Business/Enterprise).
  Management here is via the **Uffizzi CLI**.
- **TLS/HTTPS** — intentionally disabled; all traffic is plain HTTP.
- **Real AWS/Azure infrastructure** — Uffizzi OSS creates *virtual* clusters that
  run on the host node. It does not provision cloud VMs. On a single node the two
  templates therefore differ only by the floci.io **emulator** they deploy (AWS vs
  Azure); quota and everything else are identical. If you later add labeled
  AWS/Azure worker nodes to this cluster, node placement can be introduced without
  changing the developer-facing template names.
- **Multi-node / multi-cluster** topologies.

## How developers use it (at a glance)

```bash
uffizzi login --server http://api.dev.local
uffizzi cluster create dev-<username>     # pick floci-aws or floci-azure
kubectl get ns                            # against the returned kubeconfig
```

See the [Developer Guide](07-developer-guide.md) for the full flow.

## Sources
- Uffizzi Open Source (included/excluded features): docs.uffizzi.com/open-source
- `uffizzi-app` Helm values: github.com/UffizziCloud/uffizzi_app
- `UffizziCluster` CRD: github.com/UffizziCloud/uffizzi-cluster-operator

_Content paraphrased from official sources for compliance._

# PROJECT — Uffizzi self-hosted on floci (single-node K3s)

## Goal
Install Uffizzi Open Source on a **single-node K3s** cluster, managed by **ArgoCD**
(app-of-apps), **HTTP-only** via Traefik, secrets via **Sealed Secrets**. Each
developer gets **one virtual cluster** and chooses a template: **`floci-aws`**
(AWS emulator) or **`floci-azure`** (Azure emulator).

Spec: `.kiro/specs/uffizzi-floci/` (requirements, design, tasks).

## Confirmed decisions
- Git repo URL: placeholder `https://github.com/<ORG>/uffizzi-floci.git`.
- Domains: `*.dev.local`, `*.staging.local`, `*.prod.local`.
- **No TLS/HTTPS** — HTTP-only via Traefik. No cert-manager.
- **ArgoCD pre-installed** (own namespace); this repo only adds an `AppProject` +
  root Applications. It does not install/manage ArgoCD.
- Uffizzi workloads + vclusters run in the **`eph-env`** namespace.
- Secrets via **Sealed Secrets**.
- **Dashboard excluded** (not open source; served by Uffizzi Cloud).
- `floci-aws` vs `floci-azure`: each deploys a floci.io emulator (AWS `floci/floci`
  :4566, or Azure `floci/floci-az` :4577 with TLS) plus a privileged DinD sidecar
  inside the vcluster. The **emulator is the only difference**; quota is identical.

## Components (namespace: eph-env)
| Component | Role | Source |
|---|---|---|
| sealed-secrets | Decrypts SealedSecrets → Secrets | Helm (bitnami-labs) |
| uffizzi-cluster-operator | Manages `UffizziCluster` → vclusters | Helm (vendored under `charts/`) |
| uffizzi-controller | Proxy Uffizzi API ↔ Kubernetes API (HTTP) | Helm (vendored under `charts/`) |
| uffizzi-app | REST API (Rails) + Sidekiq; CLI endpoint | Helm (vendored under `charts/`) |
| postgresql, redis | Data dependencies of uffizzi-app | subcharts |

## Sync order (ArgoCD sync-waves)
`-3` sealed-secrets controller → `-2` sealed-secret resources → `-1` cluster-operator
→ `0` controller → `1` app.

> There is **no** `floci-templates` Application. The `floci-aws`/`floci-azure` presets
> under `environments/<env>/templates/` carry `<username>` placeholders (not valid
> RFC 1123 object names), so they are created per-developer via the Uffizzi CLI or by
> substituting `<username>` and applying a copy — not managed by ArgoCD.

## One virtual cluster per developer
- **Naming convention:** `dev-<username>` (unique per developer in `eph-env`).
- **Invariant:** exactly one vcluster per developer. Enforced by naming + optional
  `ResourceQuota` guardrails; operators should reject/replace a second cluster.
- **Access:** the developer receives a kubeconfig (via the Uffizzi CLI) to reach
  their vcluster.

### Developer CLI flow
```bash
uffizzi login --server http://api.dev.local
# choose ONE template at create time:
uffizzi cluster create dev-<username>            # (map to floci-aws preset)
#   or apply the preset manifest directly:
kubectl apply -f environments/dev/templates/floci-azure.yaml   # after setting name/host
```
The two presets (`environments/<env>/templates/floci-aws.yaml`,
`floci-azure.yaml`) differ only in the floci.io emulator they deploy inside the
vcluster.

## floci-aws / floci-azure (emulator + shared quota)
| Template | Emulator | Endpoint | requests cpu/mem | limits cpu/mem |
|---|---|---|---|---|
| floci-aws | AWS `floci/floci` (+ DinD) | `floci-aws.default.svc:4566` | 1 / 2Gi | 3 / 4Gi |
| floci-azure | Azure `floci/floci-az` (+ DinD, TLS) | `floci-azure.default.svc:4577` | 1 / 2Gi | 3 / 4Gi |
Adjust in `environments/<env>/templates/*.yaml`. Everything else is identical.

## Security / Secrets
No plaintext secrets in Git. Use `scripts/seal-secrets.sh` (or `kubeseal` manually)
to produce `SealedSecret` manifests under `environments/<env>/sealed-secrets/`.
Required secrets: `uffizzi-postgres`, `uffizzi-redis`, `uffizzi-controller`,
`uffizzi-first-user`.

## Placeholders to replace
| Placeholder | Where | Replace with |
|---|---|---|
| `<ORG>` | bootstrap/, projects/, apps/* | Git org/owner |
| `<username>` | environments/*/templates/*.yaml | developer name |
| `*.<env>.local` | environments/*, apps/* | real hostnames if any |
| chart versions `# <-- verify` | apps/* | pinned versions |
| resource quota / image tags | environments/*/templates/*.yaml | agreed CPU/memory; pin `floci/floci`, `floci/floci-az`, `docker:*-dind` |

## Verified during implementation
- `UffizziCluster` CRD is `uffizzi.com/v1alpha1`; resource sizing lives under
  `spec.resourceQuota.{requests,limits}` (cpu, memory, ephemeralStorage, storage).
- Controller/app HTTP-only achieved by disabling cert-manager and omitting TLS in
  ingress values; confirm exact chart keys with `helm show values` at install.

## Out of scope
Dashboard UI, TLS/HTTPS, real AWS/Azure infra or node placement, multi-node topologies.

## Sources
- Uffizzi Open Source (included/excluded features) — docs.uffizzi.com/open-source
- `uffizzi-app` chart values — github.com/UffizziCloud/uffizzi_app
- `UffizziCluster` CRD — github.com/UffizziCloud/uffizzi-cluster-operator

_Content paraphrased from official sources for compliance._

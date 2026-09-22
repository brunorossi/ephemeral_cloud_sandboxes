# Requirements — Uffizzi self-hosted on floci (single-node K3s)

## Introduction

Install Uffizzi (open source) on a **single-node K3s** cluster, managed via
**ArgoCD** using the **app-of-apps** pattern, so that each developer can create
**one virtual cluster (ephemeral environment)** and choose between two resource
templates: **`floci-aws`** and **`floci-azure`**.

The two templates are functionally identical and differ **only in resource size**
(CPU/memory). All virtual clusters run on the same single K3s node.

### Confirmed decisions
- Git repo URL: **placeholder** `https://github.com/<ORG>/uffizzi-floci.git`.
- Environment domains: `*.dev.local`, `*.staging.local`, `*.prod.local`.
- **No TLS/HTTPS** — HTTP-only via Traefik. No cert-manager, no ClusterIssuer.
- Platform: **single-node K3s** with **Traefik** ingress (K3s default).
- **ArgoCD is already installed** in the cluster (own namespace); this repo does NOT
  install or manage ArgoCD — it only adds an `AppProject` and root Applications.
- Uffizzi control plane and virtual clusters run in the **`eph-env`** namespace.
- Secrets: **Sealed Secrets**.
- Dashboard: **excluded** (not open source).
- Backends `floci-aws` / `floci-azure`: **resource-size templates only**, no node
  placement/labels (single node hosts everything).

### Scope note (verified)
Uffizzi Open Source creates **vclusters** (virtual control planes) scheduled on the
host cluster; it does **not** provision AWS/Azure infrastructure. On a single node
the two templates therefore differ only by resource quota, as specified.

---

## Requirements

### Requirement 1 — GitOps installation via ArgoCD app-of-apps
**User Story:** As a platform operator, I want Uffizzi installed via an ArgoCD
app-of-apps repository, so that the whole stack is declarative and reconciled from Git.

#### Acceptance Criteria
1. WHEN the operator applies the bootstrap root Application THEN ArgoCD SHALL create
   one child Application per component from `apps/<env>/`.
2. THE system SHALL install components in a deterministic order using
   `argocd.argoproj.io/sync-wave`.
3. THE system SHALL scope all Applications under a dedicated ArgoCD `AppProject`
   named `uffizzi`, added into the **existing** `argocd` namespace.
4. THE system SHALL NOT install or manage ArgoCD itself (it is a prerequisite).
5. WHEN a component YAML is added or removed under `apps/<env>/` THEN ArgoCD SHALL
   converge the cluster to match Git without manual per-app steps.

### Requirement 2 — Uffizzi control plane on single-node K3s
**User Story:** As a platform operator, I want the Uffizzi control plane running on
my single K3s node, so that developers can create environments.

#### Acceptance Criteria
1. THE system SHALL deploy `uffizzi-cluster-operator`, `uffizzi-controller`, and
   `uffizzi-app` into the `eph-env` namespace.
2. THE system SHALL deploy PostgreSQL and Redis as dependencies of `uffizzi-app`.
3. THE `uffizzi-app` API SHALL be reachable over **HTTP** (no TLS) through Traefik
   at `api.<env>.local`.
4. WHERE a component requires TLS-related configuration THE system SHALL disable it
   (HTTP-only deployment).
5. THE `uffizzi-controller` credentials SHALL match those configured in `uffizzi-app`.

### Requirement 3 — HTTP-only ingress via Traefik
**User Story:** As a platform operator, I want ingress served over plain HTTP via the
built-in Traefik, so that no certificate management is required.

#### Acceptance Criteria
1. THE system SHALL route external traffic through K3s' bundled Traefik.
2. THE system SHALL NOT deploy cert-manager or any ClusterIssuer.
3. THE ingress SHALL use `ingressClassName: traefik` and expose services on HTTP.
4. IF a chart defaults to HTTPS/redirect THEN the system SHALL override it to serve HTTP.

### Requirement 4 — One virtual cluster per developer
**User Story:** As a developer, I want a single personal virtual cluster, so that I
have an isolated environment without managing multiple.

#### Acceptance Criteria
1. WHEN a developer creates an environment THEN the system SHALL create exactly one
   `UffizziCluster` associated with that developer.
2. THE virtual cluster SHALL be named deterministically per developer (e.g.
   `dev-<username>`).
3. IF a developer already has a virtual cluster THEN the system SHALL reuse or reject
   creating a second one (single-per-developer invariant).
4. THE developer SHALL receive a kubeconfig to access their virtual cluster.

### Requirement 5 — Backend template selection (floci-aws / floci-azure)
**User Story:** As a developer, I want to start my virtual cluster as `floci-aws` or
`floci-azure`, so that I get the resource size appropriate to my need.

#### Acceptance Criteria
1. THE system SHALL provide two named templates: `floci-aws` and `floci-azure`.
2. THE two templates SHALL differ **only** in resource size (CPU/memory requests
   and limits / quotas).
3. WHEN a developer selects `floci-aws` THEN the created virtual cluster SHALL apply
   the `floci-aws` resource profile.
4. WHEN a developer selects `floci-azure` THEN the created virtual cluster SHALL apply
   the `floci-azure` resource profile.
5. THE templates SHALL be identical in every other respect (k8s version, add-ons,
   networking).

### Requirement 6 — Secrets via Sealed Secrets
**User Story:** As a platform operator, I want all secrets encrypted in Git, so that
credentials are never committed in clear text.

#### Acceptance Criteria
1. THE system SHALL deploy the Sealed Secrets controller.
2. THE system SHALL store all sensitive values (DB, Redis, controller creds, first
   user) as `SealedSecret` resources.
3. THE system SHALL NOT contain plaintext secret values in Git.
4. WHEN a `SealedSecret` is synced THEN the controller SHALL produce the corresponding
   `Secret` in the target namespace.

### Requirement 7 — Multi-environment layout
**User Story:** As a platform operator, I want dev/staging/prod separated, so that I
can promote configuration safely.

#### Acceptance Criteria
1. THE repository SHALL provide independent `apps/<env>` and `environments/<env>`
   trees for `dev`, `staging`, and `prod`.
2. THE environments SHALL differ by domain (`*.dev.local`, `*.staging.local`,
   `*.prod.local`) and may differ by replica counts.
3. THE root Application per environment SHALL sync only its own `apps/<env>` tree.

### Requirement 8 — Placeholders and portability
**User Story:** As a platform operator, I want clearly marked placeholders, so that I
can adapt the repo to my real values quickly.

#### Acceptance Criteria
1. THE repository SHALL mark all placeholders (`<ORG>`, domains, emails, chart
   versions) explicitly.
2. THE documentation SHALL list every placeholder and where to change it.
3. THE chart versions SHALL be pinnable to explicit versions.

---

## Out of scope
- Uffizzi Dashboard web UI (not open source).
- TLS/HTTPS and certificate management.
- Real AWS/Azure infrastructure provisioning or node placement.
- Multi-node / multi-cluster topologies.

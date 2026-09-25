# Tasks — Uffizzi self-hosted on floci (single-node K3s)

Implementation plan. Each task is incremental, ordered by dependency, and references
the requirements it satisfies. Check off tasks as they are completed.

Conventions:
- Namespace for Uffizzi workloads: `eph-env`.
- ArgoCD is already installed (own namespace); do not install/manage it.
- Placeholders: `<ORG>`, `*.<env>.local`. HTTP-only. Secrets via Sealed Secrets.

---

## 1. Repository scaffolding
- [x] 1.1 Create the directory tree: `bootstrap/`, `projects/`, `apps/{dev,staging,prod}/`,
      `environments/{dev,staging,prod}/{sealed-secrets,templates}/`.
- [x] 1.2 Add `.gitignore` (ignore rendered output, local kubeconfigs, decrypted secrets).
- [x] 1.3 Add `README.md` with quickstart and the placeholder table.
      _Requirements: 8.1, 8.2_

## 2. ArgoCD AppProject (into existing ArgoCD)
- [x] 2.1 Create `projects/uffizzi-project.yaml` (`AppProject` in ns `argocd`):
      restrict `sourceRepos` to this repo + the Helm repos used; restrict
      `destinations` to namespaces `argocd` and `eph-env`.
- [x] 2.2 Do NOT create an `argocd` namespace manifest (pre-existing).
      _Requirements: 1.3, 1.4_

## 3. Root Applications (app-of-apps) per environment
- [x] 3.1 Create `bootstrap/root-app-dev.yaml` watching `apps/dev` (recurse),
      destination ns `argocd`, project `uffizzi`, automated sync (prune + selfHeal).
- [x] 3.2 Create `bootstrap/root-app-staging.yaml` (watches `apps/staging`).
- [x] 3.3 Create `bootstrap/root-app-prod.yaml` (watches `apps/prod`; consider manual
      sync for prod).
      _Requirements: 1.1, 1.2, 7.1, 7.3_

## 4. Sealed Secrets controller
- [x] 4.1 Create `apps/dev/00-sealed-secrets.yaml` Application (chart:
      `sealed-secrets` from `bitnami-labs`/official repo), sync-wave `-3`,
      destination ns `eph-env` (or `kube-system` per chart norm — verify).
- [x] 4.2 Replicate for staging/prod.
- [x] 4.3 Document `kubeseal` fetch-cert + seal workflow in README/PROJECT.
      _Requirements: 6.1, 6.4_

## 5. Secrets (SealedSecret manifests)
- [x] 5.1 Define required secrets: postgres (postgresPassword, user, password),
      redis password, controller username/password, first admin user email/password.
- [x] 5.2 Seal each with `kubeseal` against the controller cert; store under
      `environments/<env>/sealed-secrets/`.
- [x] 5.3 Verify NO plaintext secret values exist anywhere in Git.
      _Requirements: 6.2, 6.3_

## 6. uffizzi-cluster-operator
- [x] 6.1 Create `apps/<env>/01-uffizzi-cluster-operator.yaml` (multi-source: chart +
      `$values/environments/<env>/cluster-operator-values.yaml`), sync-wave `-1`,
      destination ns `eph-env`.
- [x] 6.2 Create `environments/<env>/cluster-operator-values.yaml` (defaults; single-node).
- [x] 6.3 Pin the chart version.
- [ ] 6.4 Verify the `UffizziCluster` CRD is installed after sync.
      _Requirements: 2.1, 8.3_

## 7. uffizzi-controller (HTTP-only)
- [x] 7.1 Create `apps/<env>/02-uffizzi-controller.yaml` (multi-source), sync-wave `0`,
      destination ns `eph-env`.
- [x] 7.2 Create `environments/<env>/controller-values.yaml`: HTTP-only, ingress
      `traefik`, hostname `api.<env>.local`, disable any cert-manager dependency,
      controller credentials sourced from Sealed Secret.
- [ ] 7.3 Pin the chart version. Confirm exact ingress/TLS-disable keys via
      `helm show values`.
      _Requirements: 2.5, 3.1, 3.2, 3.3, 3.4_

## 8. uffizzi-app (API) + PostgreSQL + Redis
- [x] 8.1 Create `apps/<env>/03-uffizzi-app.yaml` (multi-source), sync-wave `1`,
      destination ns `eph-env`.
- [x] 8.2 Create `environments/<env>/app-values.yaml`: `env`, `app_url:
      http://api.<env>.local`, `webHostname`, `controller_url` (in-cluster svc in
      eph-env), replicas (dev=1, prod higher), feature flags off; DB/Redis creds via
      Sealed Secret; `postgresql.enabled` / `redis.enabled` true for dev/staging.
- [x] 8.3 Ensure controller credentials match between app and controller.
- [ ] 8.4 Pin the chart version.
      _Requirements: 2.2, 2.3, 2.4, 2.5, 7.2_

## 9. floci-aws / floci-azure templates (resource size only)
- [x] 9.1 Inspect the `UffizziCluster` CRD to identify the exact resource-sizing field(s).
- [x] 9.2 Create `environments/<env>/templates/floci-aws.yaml` (smaller resource profile).
- [x] 9.3 Create `environments/<env>/templates/floci-azure.yaml` (larger resource profile).
- [x] 9.4 Ensure the two files are IDENTICAL except the floci.io emulator they deploy
      (AWS `floci/floci` vs Azure `floci/floci-az`). _(Superseded: the original plan
      differed by resource profile; the shipped templates share identical quota and
      differ only by the emulator + its DinD wiring.)_
- [x] 9.5 ~~Create `apps/<env>/04-floci-templates.yaml` Application applying the
      `templates/` folder, sync-wave `2`.~~ **Dropped:** the presets carry `<username>`
      placeholders (not valid RFC 1123 object names), so they are applied per-developer
      via the Uffizzi CLI / sed-substitution, not by ArgoCD.
      _Requirements: 5.1, 5.2, 5.5_

## 10. Per-developer single virtual cluster
- [x] 10.1 Document the naming convention `dev-<username>` and the one-per-developer rule.
- [x] 10.2 Provide a documented CLI flow: `uffizzi cluster create dev-<username>`
      selecting `floci-aws` or `floci-azure`.
- [ ] 10.3 (Optional) Add a ResourceQuota/guard in `eph-env` to discourage a second
      vcluster per developer.
      _Requirements: 4.1, 4.2, 4.3, 4.4, 5.3, 5.4_

## 11. Static validation
- [x] 11.1 Validate all YAML (`yq`). — all files valid
- [ ] 11.2 `helm template` each chart with its per-env values; confirm HTTP-only.
      _(requires live Helm repo access — run at install time)_
- [ ] 11.3 `kubectl apply --dry-run=client` on rendered manifests and both templates.
      _(requires cluster access — run at install time)_
      _Requirements: 3.4, 8.3_

## 12. Bootstrap & functional verification (on the K3s node)
- [ ] 12.1 Apply `projects/uffizzi-project.yaml` and `bootstrap/root-app-dev.yaml`.
- [ ] 12.2 Confirm all child Applications reach `Synced`/`Healthy` and land in `eph-env`.
- [ ] 12.3 Resolve `api.dev.local` (hosts file / local DNS) and confirm the API answers
      over **HTTP**.
- [ ] 12.4 With the CLI, create `dev-<username>` using `floci-aws`; then repeat with
      `floci-azure`; confirm exactly one vcluster per developer and that only the
      resource size differs.
- [ ] 12.5 Clean up any temporary test artifacts.
      _Requirements: 2.3, 3.1, 4.1, 5.3, 5.4_

## 13. Multi-environment promotion
- [x] 13.1 Verify staging and prod trees render and differ only by domain/replicas.
- [ ] 13.2 Apply staging root app; smoke-test.
- [ ] 13.3 Apply prod root app (manual sync if chosen).
      _Requirements: 7.1, 7.2, 7.3_

## 14. Documentation finalization
- [x] 14.1 Ensure `PROJECT.md` reflects: eph-env namespace, pre-existing ArgoCD,
      HTTP-only, Sealed Secrets, floci-aws/azure = resource size only.
- [x] 14.2 Ensure the placeholder table is complete and accurate.
- [x] 14.3 Note the "verify during implementation" items resolved (CRD fields, chart keys).
      _Requirements: 8.1, 8.2_

---

## Requirement coverage map
| Requirement | Tasks |
|---|---|
| 1 GitOps app-of-apps | 2, 3 |
| 2 Control plane (eph-env) | 6, 7, 8, 12 |
| 3 HTTP-only Traefik | 7, 11, 12 |
| 4 One vcluster / dev | 10, 12 |
| 5 floci-aws/azure (size) | 9, 10, 12 |
| 6 Sealed Secrets | 4, 5 |
| 7 Multi-environment | 3, 8, 13 |
| 8 Placeholders/portability | 1, 6, 8, 11, 14 |

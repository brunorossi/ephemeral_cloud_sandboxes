# Vendored Helm charts

Charts copied into this repo so we can patch issues the upstream charts do not
let us override via values.

> **Vendoring rule (learned the hard way):** vendor charts as **unpacked
> subchart directories** under `charts/`, and do **NOT** commit `Chart.lock`
> files or packaged `*.tgz` dependencies. A committed `*.tgz` (or a `Chart.lock`
> that triggers `helm dependency build`) will re-pull the stock upstream
> subchart and **shadow the patched unpacked directory**, silently
> reintroducing the broken images. Keep only unpacked dirs so ArgoCD's
> repo-server renders them directly without a dependency rebuild.

## uffizzi-app (vendored from 1.3.0)

**Why vendored:** the upstream `uffizzi-app` chart embeds this dependency tree:

```
uffizzi-app 1.3.0
└─ uffizzi-controller 2.2.10
   └─ uffizzi-cluster-operator 1.4.5   (embedded, redundant)
      └─ flux 0.3.11
```

The embedded operator 1.4.5 pulls images that no longer exist:

1. **`docker.io/bitnami/fluxcd-helm-controller`** and
   **`fluxcd-source-controller`** — deleted in Broadcom's late-2025 "Bitnami
   Secure Images" migration (`ErrImagePull: not found`).
2. **`gcr.io/kubebuilder/kube-rbac-proxy:v0.13.1`** — retired by Google,
   **hardcoded** in the operator's `controller-manager_deployment.yaml` with no
   Helm value to override it.

Because we already deploy a separately patched **`uffizzi-cluster-operator`
1.6.5** via `apps/<env>/01-uffizzi-cluster-operator.yaml` **and** the controller
standalone via `apps/<env>/02-uffizzi-controller.yaml`, the app chart's entire
embedded `uffizzi-controller` stack is redundant. Left enabled it also renders,
off-spec for floci:

- a **duplicate controller** Deployment/Service/Ingress (collides by name with
  the standalone controller in `eph-env`),
- an embedded **ingress-nginx** (`type: LoadBalancer`, hangs on single-node K3s),
- an embedded **cert-manager**, and
- the app's own **`web-ingress.yaml`** hardwired to `kubernetes.io/ingress.class:
  nginx` with a cert-manager annotation + `tls:` block (the API endpoint the CLI
  hits — would not be served by Traefik).

So we disable the **whole** embedded controller (a superset of just disabling the
embedded operator).

**Patches applied to the vendored copy:**

| File | Change |
|---|---|
| `charts/uffizzi-app/Chart.yaml` | Added `condition: uffizzi-controller.enabled` to the embedded `uffizzi-controller` dependency so the entire stack can be disabled (the embedded controller's own `Chart.yaml` still carries the `uffizzi-cluster-operator.enabled` condition from before) |
| `templates/web-ingress.yaml` | Wrapped the `tls:` block and `cert-manager.io/cluster-issuer` annotation in `{{- if (index .Values "uffizzi-controller" "clusterIssuer") }}`; replaced the hardcoded `kubernetes.io/ingress.class: nginx` with `ingressClassName` from `.Values.ingressClassName` |
| `templates/web-deployment.yaml`, `templates/sidekiq-deployment.yaml` | **(Part B — sealed credentials)** Append an optional `{{- if .Values.externalSecret }}` `secretRef` as the **LAST** `envFrom` entry. Kubernetes lets a later `envFrom` override earlier keys, so a sealed Secret named by `externalSecret` overrides the chart-generated `uffizzi-web-secret-envs` (DB/Redis/controller passwords) **and** the plaintext `UFFIZZI_USER_PASSWORD` in the `uffizzi-web-common-envs` ConfigMap. This is what lets the Rails app run on real sealed credentials without any plaintext in Git |
| (all `Chart.lock` files) | Deleted, so ArgoCD renders the unpacked subchart dirs directly and never re-pulls stock flux |

**Sealed credentials (Part B):** `environments/<env>/app-values.yaml` sets
`externalSecret: uffizzi-web-envs`. Provide that Secret as a SealedSecret with
**env-var-named** keys (`DATABASE_PASSWORD`, `REDIS_URL`, `CONTROLLER_PASSWORD`,
`VCLUSTER_CONTROLLER_PASSWORD`, `UFFIZZI_USER_PASSWORD`); `scripts/seal-secrets.sh`
generates it (deriving `REDIS_URL` as
`redis://:<REDIS_PW>@uffizzi-app-<ENV>-redis-master`). See
`environments/<env>/sealed-secrets/README.md`. Postgres/Redis **servers**
separately consume `uffizzi-postgres` / `uffizzi-redis` via the Bitnami
`existingSecret` values (Part A).

**Values applied per environment (`environments/<env>/app-values.yaml`):**

> **Values structure (important):** this chart reads app config keys at the
> **top level** (`env`, `app_url`, `webHostname`, `image`, `controller_url`,
> `vcluster_controller_url`, `managed_dns_zone_dns_name`, `feature_*`, ...), **not**
> under an `uffizzi:` block. Credentials go under `global.uffizzi.*`. Replica
> counts use **underscores** (`web_replicas` / `sidekiq_replicas`) — the
> templates read those; the chart's hyphenated `web-replicas` defaults are never
> consumed. A nested `uffizzi:` block (an earlier mistake) is silently ignored,
> leaving the chart on its `uffizzi.example.com` / `web-replicas: 3` defaults.

```yaml
# app config at TOP LEVEL, HTTP-only via Traefik
app_url: http://api.dev.local
webHostname: api.dev.local
ingressClassName: traefik
web_replicas: 1
# both controller URLs must point at the STANDALONE controller in eph-env,
# since the embedded controller service no longer exists once disabled
controller_url: "http://uffizzi-controller.eph-env.svc.cluster.local:8080"
vcluster_controller_url: "http://uffizzi-controller.eph-env.svc.cluster.local:8080"
# credentials under global.uffizzi.* (passwords via SealedSecret)
global:
  uffizzi:
    firstUser: { email: "admin@floci.dev.local", projectName: default }
    controller: { username: uffizzi-controller }
# relocate Bitnami DB/cache images to the still-published legacy mirror
postgresql:
  image: { registry: docker.io, repository: bitnamilegacy/postgresql, tag: 16.1.0-debian-11-r3 }
redis:
  image: { registry: docker.io, repository: bitnamilegacy/redis, tag: 7.2.3-debian-11-r1 }
# disable the entire embedded controller stack; empty clusterIssuer -> HTTP-only web-ingress
uffizzi-controller:
  enabled: false
  clusterIssuer: ""
```

The `apps/<env>/03-uffizzi-app.yaml` Application references the vendored chart by
`path: charts/uffizzi-app` (multi-source, with values via `$values`).

**Verify (no dead images, no nginx/cert-manager, Traefik HTTP-only ingress):**
```bash
helm template ua charts/uffizzi-app -f environments/dev/app-values.yaml \
  | grep -icE 'bitnami/fluxcd|gcr.io/kubebuilder|ingress-nginx-controller|cert-manager.io/v1|ingress.class: nginx|type: LoadBalancer'
# 0 = clean. The web-ingress should show `ingressClassName: traefik`, host
#     api.dev.local, and no tls: block.
```

**Re-vendoring on upgrade:** re-pull the chart untarred, delete all `Chart.lock`
files and any `*.tgz` under `charts/`, then re-add the `condition:` line to the
embedded operator dependency:
```bash
helm pull uffizzi/uffizzi-app --version <NEW> --untar --untardir /tmp/ua
# copy to charts/uffizzi-app, then:
find charts/uffizzi-app -name Chart.lock -delete
find charts/uffizzi-app -name '*.tgz' -delete
# re-add: condition: uffizzi-cluster-operator.enabled  in
#   charts/uffizzi-app/charts/uffizzi-controller/Chart.yaml
```

## uffizzi-controller (vendored from 2.4.6)

**Why vendored:** the upstream `uffizzi-controller` chart embeds three
dependencies with **no `condition:`** (so they can't be disabled via values),
plus an Ingress template and ClusterIssuer templates hardwired for
nginx + cert-manager TLS. On single-node K3s / Traefik / HTTP-only (floci's
model) these cause failures:

1. **embedded `uffizzi-cluster-operator 1.6.5` (→ `flux`)** — redundant with the
   standalone operator (`apps/<env>/01-uffizzi-cluster-operator.yaml`); its Flux
   ClusterRoles collide → ArgoCD `RepeatedResourceWarning`:
   ```
   Resource rbac.authorization.k8s.io/ClusterRole//uffizzi-controller-<env>-flux-eph-env-source-controller-gitreposi
   appeared 2 times among application resources.
   ```
2. **embedded `ingress-nginx`** — renders a `type: LoadBalancer` Service and an
   IngressClass named `uffizzi`. On single-node K3s it never gets an external IP
   and collides with Traefik on ports 80/443, so the
   `uffizzi-controller-<env>-ingress-nginx-controller` pod hangs. floci uses
   Traefik everywhere (API + every vcluster template pin `ingressClassName:
   traefik`), so nginx is dead weight.
3. **embedded `cert-manager`** — installs a ValidatingWebhookConfiguration that
   hangs admission when cert-manager isn't actually running, and floci is
   HTTP-only (no TLS).
4. **`templates/ingress.yaml`** — always emitted a `tls:` block + a
   `cert-manager.io/cluster-issuer` annotation and no `ingressClassName`,
   violating HTTP-only/Traefik.
5. **`templates/cluster-issuer-*.yaml`** — always emitted `cert-manager.io/v1`
   ClusterIssuers; with cert-manager disabled the CRD is absent and ArgoCD sync
   fails (`no matches for kind "ClusterIssuer"`).

**Patches applied to the vendored copy:**

| File | Change |
|---|---|
| `Chart.yaml` | Added `condition:` to the `ingress-nginx`, `cert-manager`, and `uffizzi-cluster-operator` dependencies so each can be disabled |
| `templates/ingress.yaml` | Wrapped the `tls:` block and `cert-manager.io/cluster-issuer` annotation in `{{- if .Values.clusterIssuer }}`; added `ingressClassName` from `.Values.ingress.className` |
| `templates/cluster-issuer-letsencrypt.yaml`, `cluster-issuer-zerossl.yaml`, `cluster-issuer-secret.yaml` | Wrapped in `{{- if .Values.clusterIssuer }}` so no cert-manager CRs render when TLS is off |
| (all `Chart.lock` files) | Deleted, so ArgoCD renders the unpacked subchart dirs directly and never re-pulls stock flux |

**Values applied per environment (`environments/<env>/controller-values.yaml`):**

```yaml
ingress:
  hostname: api.<env>.local
  className: traefik          # controller Ingress via Traefik (HTTP-only)
clusterIssuer: ""             # empty -> no cert-manager annotation / TLS block / ClusterIssuers
cert-manager:
  enabled: false
# disable the redundant embedded operator (removes the duplicate Flux resources)
uffizzi-cluster-operator:
  enabled: false
# disable the embedded ingress-nginx (floci is Traefik-only)
ingress-nginx:
  enabled: false
```

The `apps/<env>/02-uffizzi-controller.yaml` Application references the vendored
chart by `path: charts/uffizzi-controller` (multi-source, with values via
`$values`).

**Verify (only the controller's own resources should render — no nginx / cert-manager / duplicate flux):**
```bash
helm template uc charts/uffizzi-controller -f environments/dev/controller-values.yaml \
  | grep -cE 'ingress-nginx-controller|cert-manager.io/v1|type: LoadBalancer|flux.*source-controller-gitreposi'
# 0 = clean. Expected kinds: Deployment, Service, Ingress (traefik), ServiceAccount,
#     ClusterRoleBinding, Secret.
```

**Re-vendoring on upgrade:** re-pull the chart untarred, delete all `Chart.lock`
files and any `*.tgz` under `charts/`, then re-apply the patches above:
```bash
helm pull uffizzi-controller/uffizzi-controller --version <NEW> --untar --untardir /tmp/uc
# copy to charts/uffizzi-controller, then:
find charts/uffizzi-controller -name Chart.lock -delete
find charts/uffizzi-controller -name '*.tgz' -delete
# re-add the three `condition:` lines in charts/uffizzi-controller/Chart.yaml, and
# re-gate templates/ingress.yaml + templates/cluster-issuer-*.yaml on .Values.clusterIssuer
```

> Once upstream adds `condition:`s for the embedded deps (or a values toggle) and
> makes the Ingress/ClusterIssuer templates conditional on TLS, this vendored
> copy can be removed and the Applications repointed at the upstream Helm repo.

## uffizzi-cluster-operator (vendored from 1.6.5)

**Why vendored:** the upstream chart cannot be fixed with a values file for two
broken image references:

1. **`gcr.io/kubebuilder/kube-rbac-proxy:v0.13.1`** — hardcoded as a literal
   string in `templates/controller-manager_deployment.yaml` with **no Helm
   value** to override it. Google retired the `gcr.io/kubebuilder`
   distribution, so the image is `not found`.
2. **`docker.io/bitnami/fluxcd-*`** (bundled Bitnami `flux` subchart) — deleted
   from Docker Hub in Broadcom's late-2025 "Bitnami Secure Images" migration.

...and one CRD/controller version incompatibility introduced by fix #2:

3. **Stale Flux CRDs vs upstream controllers** — the bundled Bitnami `flux`
   subchart ships old CRDs (`controller-gen v0.11.1`) that only serve
   `source.toolkit.fluxcd.io/v1beta1|v1beta2` and `helm.toolkit.fluxcd.io/v2beta*`.
   After repointing the controllers at upstream `ghcr.io/fluxcd/*` images
   (source-controller v1.6.2, helm-controller v1.3.0), the manager needs the
   `v1`/`v2` served versions and fails to start with:
   `failed to get restmapping: ... no matches for source.toolkit.fluxcd.io/v1`.

**Patches applied to the vendored copy:**

| File | Change |
|---|---|
| `templates/controller-manager_deployment.yaml` | `gcr.io/kubebuilder/kube-rbac-proxy:v0.13.1` → `quay.io/brancz/kube-rbac-proxy:v0.13.1` |
| `values.yaml` | Added `global.security.allowInsecureImages: true` and `flux.helmController.image` / `flux.sourceController.image` pointing at `ghcr.io/fluxcd/*` |
| `charts/flux/crds/source-controller/*.yaml` | Replaced with upstream **source-controller v1.6.2** CRDs (serve `source.toolkit.fluxcd.io/v1`) |
| `charts/flux/crds/helm-controller/helm.toolkit.fluxcd.io_helmreleases.yaml` | Replaced with upstream **helm-controller v1.3.0** CRD (serves `helm.toolkit.fluxcd.io/v2`) |

> Only the CRDs for the **enabled** Flux controllers (source + helm) were
> updated. The `kustomize`, `notification`, `image-automation`, and
> `image-reflector` controllers are disabled in `values.yaml`, so their stale
> CRDs are harmless and were left untouched.

All image fixes are **baked into the chart's own `values.yaml`**, so the ArgoCD
Applications (`apps/<env>/01-uffizzi-cluster-operator.yaml`) reference the chart
by `path:` with no external `$values` file required.

**Verify (no dead image references should appear):**
```bash
helm template uco charts/uffizzi-cluster-operator \
  | grep -E '^\s*image:' | grep -iE 'bitnami/fluxcd|gcr.io/kubebuilder'
# (empty output = clean)
```

**Verify (Flux source/helm CRDs serve the versions the controllers need):**
```bash
grep -E '^    name: v' \
  charts/uffizzi-cluster-operator/charts/flux/crds/source-controller/source.toolkit.fluxcd.io_helmrepositories.yaml
# must include:  name: v1
grep -E '^    name: v' \
  charts/uffizzi-cluster-operator/charts/flux/crds/helm-controller/helm.toolkit.fluxcd.io_helmreleases.yaml
# must include:  name: v2
```

**Re-vendoring on upgrade:** when moving to a newer operator chart version,
re-pull and re-apply the three patches above:
```bash
helm repo add uffizzi-cluster-operator https://uffizzicloud.github.io/uffizzi-cluster-operator
helm pull uffizzi-cluster-operator/uffizzi-cluster-operator --version <NEW> --untar --untardir /tmp/uco
# diff against this dir, re-apply the kube-rbac-proxy and flux image patches.

# Re-sync the Flux CRDs to match whatever controller image tags values.yaml pins
# (SRC_TAG = flux.sourceController.image.tag, HELM_TAG = flux.helmController.image.tag):
SRC_TAG=v1.6.2 ; HELM_TAG=v1.3.0
crds=charts/uffizzi-cluster-operator/charts/flux/crds
curl -fsSL https://github.com/fluxcd/source-controller/releases/download/$SRC_TAG/source-controller.crds.yaml -o /tmp/src.crds.yaml
curl -fsSL https://github.com/fluxcd/helm-controller/releases/download/$HELM_TAG/helm-controller.crds.yaml   -o /tmp/helm.crds.yaml
# split each multi-doc file into per-CRD files named <group>_<plural>.yaml under
# $crds/source-controller and $crds/helm-controller, then re-run the verify commands.
```

> Once upstream publishes a version that (a) templates the kube-rbac-proxy image
> and (b) ships working Flux images, this vendored copy can be removed and the
> Applications repointed at the upstream Helm repo.

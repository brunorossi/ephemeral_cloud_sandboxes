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
1.6.5** via `apps/<env>/01-uffizzi-cluster-operator.yaml`, the embedded 1.4.5
operator is redundant (and running two operators risks fighting over the same
Flux CRDs / HelmReleases).

**Patches applied to the vendored copy:**

| File | Change |
|---|---|
| `charts/uffizzi-controller/Chart.yaml` | Added `condition: uffizzi-cluster-operator.enabled` to the embedded operator dependency so it can be disabled |
| (all `Chart.lock` files) | Deleted, so ArgoCD renders the unpacked subchart dirs directly and never re-pulls stock flux |

**Values applied per environment (`environments/<env>/app-values.yaml`):**

```yaml
# disable the redundant embedded operator (removes flux + kube-rbac-proxy)
uffizzi-controller:
  uffizzi-cluster-operator:
    enabled: false
# relocate Bitnami DB/cache images to the still-published legacy mirror
postgresql:
  image: { registry: docker.io, repository: bitnamilegacy/postgresql, tag: 16.1.0-debian-11-r3 }
redis:
  image: { registry: docker.io, repository: bitnamilegacy/redis, tag: 7.2.3-debian-11-r1 }
```

The `apps/<env>/03-uffizzi-app.yaml` Application references the vendored chart by
`path: charts/uffizzi-app` (multi-source, with values via `$values`).

**Verify (no dead image references should appear):**
```bash
helm template ua charts/uffizzi-app -f environments/dev/app-values.yaml \
  | grep -E '^\s*image:' \
  | grep -iE 'bitnami/fluxcd|gcr.io/kubebuilder|docker.io/bitnami/postgresql|docker.io/bitnami/redis'
# (empty output = clean)
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

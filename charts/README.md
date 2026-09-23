# Vendored Helm charts

Charts copied into this repo so we can patch issues the upstream charts do not
let us override via values.

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

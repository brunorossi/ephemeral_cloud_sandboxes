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

**Patches applied to the vendored copy:**

| File | Change |
|---|---|
| `templates/controller-manager_deployment.yaml` | `gcr.io/kubebuilder/kube-rbac-proxy:v0.13.1` → `quay.io/brancz/kube-rbac-proxy:v0.13.1` |
| `values.yaml` | Added `global.security.allowInsecureImages: true` and `flux.helmController.image` / `flux.sourceController.image` pointing at `ghcr.io/fluxcd/*` |

All image fixes are **baked into the chart's own `values.yaml`**, so the ArgoCD
Applications (`apps/<env>/01-uffizzi-cluster-operator.yaml`) reference the chart
by `path:` with no external `$values` file required.

**Verify (no dead image references should appear):**
```bash
helm template uco charts/uffizzi-cluster-operator \
  | grep -E '^\s*image:' | grep -iE 'bitnami/fluxcd|gcr.io/kubebuilder'
# (empty output = clean)
```

**Re-vendoring on upgrade:** when moving to a newer operator chart version,
re-pull and re-apply the two patches above:
```bash
helm repo add uffizzi-cluster-operator https://uffizzicloud.github.io/uffizzi-cluster-operator
helm pull uffizzi-cluster-operator/uffizzi-cluster-operator --version <NEW> --untar --untardir /tmp/uco
# diff against this dir, re-apply the kube-rbac-proxy and flux image patches,
# then re-run the verify command above.
```

> Once upstream publishes a version that (a) templates the kube-rbac-proxy image
> and (b) ships working Flux images, this vendored copy can be removed and the
> Applications repointed at the upstream Helm repo.

# Ephemeral Stacks GitOps

Automated GitOps platform that provisions, updates, and tears down isolated
ephemeral emulator stacks (`ministack`, `floci-az`, `floci-gcp`, `floci-oci`) per
user and environment on Kubernetes, using **Kustomize** (base/overlay) and an
**ArgoCD ApplicationSet** driven by a Git file generator.

## Platform foundation

This project is designed to run on top of
[brunorossi/oci_k3s_always_free](https://github.com/brunorossi/oci_k3s_always_free),
which provisions a **K3s** cluster (on Oracle Cloud Always Free resources) with
**ArgoCD** already installed locally. That repository provides the cluster and the
GitOps control plane; this repository provides the workloads ArgoCD deploys onto
it. In other words, stand up the cluster with `oci_k3s_always_free` first, then
point the ArgoCD instance it ships with at this repository (see
"Required setup before use").

## Naming conventions

Every stack instance is identified by three values — `id`, `env`, `tech` — and
follows these rules strictly:

- **Namespace**: `{id}-{env}-{tech}` (one isolated namespace per stack).
- **Resource names**: every resource is prefixed with the namespace name, with a
  canonical suffix per kind:
  - `PersistentVolumeClaim` -> `{id}-{env}-{tech}-data-pvc`
  - `Deployment`            -> `{id}-{env}-{tech}-deployment`
  - `Service`               -> `{id}-{env}-{tech}-service`
  - `Ingress`               -> `{id}-{env}-{tech}-ingress`
- **Ingress hosts**: each Ingress exposes both
  `{id}.{env}.{tech}.local` and the wildcard `*.{id}.{env}.{tech}.local`.

These are produced mechanically: the base resources carry bare canonical names
(`data-pvc`, `deployment`, `service`, `ingress`) and the overlay applies
`namePrefix: {id}-{env}-{tech}-`, which also rewrites internal references
(PVC `claimName`, ingress backend service name).

## How it works

1. `config/stacks.json` lists every stack instance (`id`, `tech`, `env`, `path`).
2. The ApplicationSet (`argocd/ephemeral-stacks-appset.yaml`) reads that file via a
   Git generator and creates one ArgoCD `Application` per entry, named
   `{{tech}}-{{id}}-{{env}}`.
3. Each Application syncs the Kustomize overlay at `{{path}}` into namespace
   `{{id}}-{{env}}-{{tech}}` (auto-created). Adding/removing a JSON entry
   provisions/prunes the corresponding cluster resources automatically
   (`prune: true`, `selfHeal: true`).

```
config/stacks.json  ->  ApplicationSet  ->  Application (per entry)
  ->  overlays/<env>/<id>-<env>-<tech>  ->  bases/<tech>
  ->  namespace <id>-<env>-<tech>
```

## Repository layout

```
bases/            Generic, reusable manifests per tech (no namespace, bare names)
  ministack/      pvc, deployment (ministack + DinD sidecar), service, ingress
  floci-az/       pvc, deployment (floci-az + DinD sidecar), service, ingress
  floci-gcp/      pvc, deployment (floci-gcp + DinD sidecar), service, ingress
  floci-oci/      pvc, deployment (floci-oci + DinD sidecar), service, ingress
overlays/         Per-instance customizations (namePrefix, labels, ingress hosts)
  <env>/<id>-<env>-<tech>/
config/stacks.json                    Central registry of stack instances
argocd/ephemeral-stacks-appset.yaml   The ApplicationSet
examples/         Standalone single-file manifests (reference, not GitOps-managed)
                  see examples/README.md
scripts/          Per-cloud end-to-end demo scripts; see scripts/README.md
```

## Ports per tech

| Tech       | Container port | Emulator            |
|------------|----------------|---------------------|
| ministack  | 4566           | AWS                 |
| floci-az   | 4577           | Azure               |
| floci-gcp  | 4588           | GCP                 |
| floci-oci  | 4599           | Oracle Cloud (OCI)  |

## Required setup before use

Set your real Git repository URL in **both** `repoURL` fields of
`argocd/ephemeral-stacks-appset.yaml` (currently `<REPLACE_ME_REPO_URL>`), then
apply it:

```bash
kubectl apply -f argocd/ephemeral-stacks-appset.yaml
```

## Provisioning a stack instance

1. Create an overlay directory `overlays/<env>/<id>-<env>-<tech>/` with:
   - `kustomization.yaml` referencing `../../../bases/<tech>`, with
     `namePrefix: <id>-<env>-<tech>-` and `labels` (`owner`, `env`, `tech`).
   - `ingress-patch.yaml` replacing `spec.rules` with the two hosts
     `<id>.<env>.<tech>.local` and `*.<id>.<env>.<tech>.local`.
2. Append an entry to `config/stacks.json`:
   ```json
   { "id": "<id>", "tech": "<tech>", "env": "<env>", "path": "overlays/<env>/<id>-<env>-<tech>" }
   ```
3. Commit and push. ArgoCD provisions the stack automatically. Removing the entry
   prunes it.

## Onboarding a new technology

Create `bases/<tech-name>/` with `pvc.yaml`, `deployment.yaml`, `service.yaml`,
`ingress.yaml`, and a `kustomization.yaml` listing them. Use **bare canonical
names** (`data-pvc`, `deployment`, `service`, `ingress`) and **do not** set a
`namespace` — overlays and ArgoCD own the namespace. `namePrefix` in overlays
rewrites names and all internal linkages (service selectors are matched within the
isolated namespace, PVC `claimName`, ingress backends).

## Notes

- **DinD privileged sidecar**: every tech runs a `docker:24.0.7-dind` sidecar with
  `securityContext.privileged: true`, exposed over TCP `localhost:2375`. The
  emulators reach it via `DOCKER_HOST=tcp://localhost:2375`. The cluster must permit
  privileged pods for the `*-*-*` stack namespaces.
- **Embedded DNS / root**: the floci emulators start an embedded DNS server on a
  privileged port when running inside Docker, so their main container runs as
  `runAsUser: 0` with `NET_BIND_SERVICE`.
- **arm64 caveat (floci-az Functions)**: Azure Functions uses a fixed amd64-only
  Microsoft runtime image. On an arm64 node it requires QEMU emulation (binfmt +
  pre-pull) and the .NET host may still crash; prefer scheduling Functions-using
  stacks on an amd64 node. floci-gcp Cloud Run and floci-oci Functions/OKE run
  user- or multi-arch images and are not affected.
- **Ingress**: all stacks use `ingressClassName: traefik`.

## Local validation (no standalone kustomize required)

`kubectl` ships with Kustomize built in, so you can render any overlay to verify
name prefixing, label propagation, and ingress host patching:

```bash
kubectl kustomize overlays/dev/brossi-dev-ministack
kubectl kustomize overlays/dev/brossi-dev-floci-az
kubectl kustomize overlays/dev/brossi-dev-floci-gcp
kubectl kustomize overlays/dev/brossi-dev-floci-oci
```

ArgoCD also renders Kustomize server-side, so a local binary is optional.

## Examples and demo scripts

Two companion guides cover standalone usage without the full GitOps flow:

- **[examples/README.md](examples/README.md)** — standalone single-file manifests
  (`examples/<tech>.yaml`) you can `kubectl apply` directly to stand up one
  isolated stack, with prerequisites, ingress/DNS setup, and the OCI Functions
  fnserver wiring explained.
- **[scripts/README.md](scripts/README.md)** — per-cloud end-to-end demo scripts
  that create and invoke a resource on each emulator (AWS Lambda / SQS / API
  Gateway, GCP Cloud Run, OCI Functions). `floci-az` has an example manifest but
  no demo script yet.

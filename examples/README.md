# Standalone example manifests & demo scripts

This directory contains **standalone, single-file** Kubernetes manifests for each
emulator tech, plus pointers to the per-cloud demo scripts under
[`../scripts/`](../scripts). They are a **reference / quick-start**: unlike the
GitOps path (ArgoCD + Kustomize overlays, see the [root README](../README.md)),
these manifests are self-contained and applied directly with `kubectl apply`.

- **GitOps path** (recommended for real use): edit `config/stacks.json`, commit,
  ArgoCD renders `overlays/<env>/<id>-<env>-<tech>` over `bases/<tech>` and syncs.
- **Example path** (this directory): `kubectl apply -f examples/<tech>.yaml` to
  stand up one isolated stack without ArgoCD or Kustomize.

Each example is the `kubectl kustomize` render of the matching
`overlays/dev/brossi-dev-<tech>` overlay for the instance `id=brossi`, `env=dev`,
plus a `Namespace` object and explicit per-resource `namespace:` injection (which,
in the GitOps path, ArgoCD applies rather than the overlay).

## Contents

| Example manifest | Tech | Emulator | Port | Ingress host |
|------------------|------|----------|------|--------------|
| [`ministack.yaml`](ministack.yaml) | ministack | AWS       | 4566 | `brossi.dev.ministack.local` |
| [`floci-az.yaml`](floci-az.yaml)   | floci-az  | Azure     | 4577 | `brossi.dev.floci-az.local`  |
| [`floci-gcp.yaml`](floci-gcp.yaml) | floci-gcp | GCP       | 4588 | `brossi.dev.floci-gcp.local` |
| [`floci-oci.yaml`](floci-oci.yaml) | floci-oci | OCI       | 4599 | `brossi.dev.floci-oci.local` |

Each manifest contains a `Namespace`, `Service`, `PersistentVolumeClaim`,
`Deployment` (emulator container + a `docker:24.0.7-dind` sidecar), and an
`Ingress` exposing both `brossi.dev.<tech>.local` and `*.brossi.dev.<tech>.local`.

## Prerequisites

- A Kubernetes cluster that permits **privileged pods** (the DinD sidecar needs
  `securityContext.privileged: true`). See the platform notes in the
  [root README](../README.md#notes).
- An ingress controller on `ingressClassName: traefik` (default on K3s).
- DNS/hosts resolution for the `*.local` ingress hosts pointing at the ingress.
  For local testing, add entries to `/etc/hosts`, e.g.:
  ```
  <ingress-ip>  brossi.dev.ministack.local brossi.dev.floci-az.local brossi.dev.floci-gcp.local brossi.dev.floci-oci.local
  ```
- The relevant cloud CLI for the demo scripts (`aws`, `az`, `oci`) and `curl`.

## Deploy an example

```bash
# AWS (ministack)
kubectl apply -f examples/ministack.yaml

# Azure (floci-az)
kubectl apply -f examples/floci-az.yaml

# GCP (floci-gcp)
kubectl apply -f examples/floci-gcp.yaml

# OCI (floci-oci)
kubectl apply -f examples/floci-oci.yaml
```

Tear down by deleting the namespace (which removes every resource in it):

```bash
kubectl delete namespace brossi-dev-ministack   # or brossi-dev-floci-az, etc.
```

## Demo scripts

The scripts under [`../scripts/`](../scripts) exercise each emulator end-to-end
(create a resource, then invoke/trigger it over HTTP). They default to the
`brossi.dev.<tech>.local` ingress hosts above and accept overrides as positional
arguments. All scripts use **mock credentials** — the emulators parse but never
verify them.

### AWS — `scripts/aws/`

| Script | What it does |
|--------|--------------|
| [`deploy-lambda.sh`](../scripts/aws/deploy-lambda.sh) | Creates a Python Lambda, exposes a Function URL, and invokes it via both the AWS CLI and a direct HTTP `curl`. |
| [`deploy-sqs-lambda.sh`](../scripts/aws/deploy-sqs-lambda.sh) | Creates an SQS queue + Lambda, wires an event-source mapping, and sends a test message to trigger the function. |
| [`deploy-apig-lambda.sh`](../scripts/aws/deploy-apig-lambda.sh) | Creates a Lambda behind an API Gateway (HTTP API v2) with a `GET /test` route and invokes it. |
| [`deploy-apig-lambda-dynamodb.sh`](../scripts/aws/deploy-apig-lambda-dynamodb.sh) | Creates a DynamoDB table + a Lambda that writes to it, fronts it with an API Gateway (HTTP API v2) `POST /items` route, invokes it via `curl`, and scans the table to verify the item was persisted. |

```bash
./scripts/aws/deploy-lambda.sh                       # defaults
./scripts/aws/deploy-lambda.sh http://brossi.dev.ministack.local my-func
```

### Azure — `scripts/azure/`

_No demo scripts are currently provided for `floci-az`._ You can still deploy the
[`floci-az.yaml`](floci-az.yaml) example and drive it with the Azure CLI (`az`)
pointed at `http://brossi.dev.floci-az.local`.

### GCP — `scripts/gcp/`

| Script | What it does |
|--------|--------------|
| [`deploy-cloud-run.sh`](../scripts/gcp/deploy-cloud-run.sh) | Creates a Cloud Run service (real container via the DinD sidecar) and invokes it through the ingress using the legacy front-door path. |

```bash
./scripts/gcp/deploy-cloud-run.sh                    # defaults
./scripts/gcp/deploy-cloud-run.sh http://brossi.dev.floci-gcp.local floci-local europe-west1 my-svc
```

### OCI — `scripts/oci/`

| Script | What it does |
|--------|--------------|
| [`deploy-function.sh`](../scripts/oci/deploy-function.sh) | Creates an OCI Functions **Application** and image-based **Function**, then invokes it over HTTP with `oci raw-request`. See the OCI notes below. |

```bash
./scripts/oci/deploy-function.sh                     # defaults
./scripts/oci/deploy-function.sh http://brossi.dev.floci-oci.local my-app my-fn fnproject/fdk-go-hello:latest
```

Arguments: `$1` endpoint URL, `$2` application name, `$3` function name,
`$4` function image.

## OCI Functions: how it works and the fnserver wiring

floci-oci implements the OCI Functions control plane (`/20181201`) and performs
**real invocation** by running the function image in an `fnproject/fnserver`
container that it starts inside the DinD sidecar. This has three consequences the
example manifest and script account for:

1. **Function images must be real FDK images.** fnserver can only run images that
   implement the Fn FDK http-stream contract. A plain image (e.g.
   `fnproject/hello`) fails with *"Container failed to initialize ... latest
   fdk"*. The script defaults to `fnproject/fdk-go-hello:latest`, a prebuilt
   public FDK function. (It is amd64-only; on an arm64 node it needs QEMU/binfmt.)

2. **Invoke must be routed at the ingress.** The high-level `oci fn function
   invoke` follows the function's self-reported invoke endpoint, which floci-oci
   reports as its internal `http://localhost:4599` — unreachable from the client.
   The script instead issues the data-plane invoke with `oci raw-request` against
   `http://brossi.dev.floci-oci.local/20181201/functions/{id}/actions/invoke`.

3. **fnserver reachability (the `hostAliases` wiring).** floci-oci reaches
   fnserver by container name (`http://floci-oci-fnserver:8080`), which only
   resolves via Docker's embedded DNS. Because floci-oci runs as the pod's main
   container (outside the Docker network) it cannot resolve that name, but it
   shares the pod network namespace and can reach fnserver by IP. The
   `floci-oci.yaml` manifest therefore:
   - has the DinD sidecar pre-create a dedicated network `floci-oci-net`
     (`172.28.0.0/24`),
   - sets `FLOCI_OCI_SERVICES_DOCKER_NETWORK=floci-oci-net` so floci-oci attaches
     fnserver to it (fnserver deterministically gets `172.28.0.2`),
   - adds a `hostAliases` entry mapping `floci-oci-fnserver -> 172.28.0.2`.

   If `172.28.0.0/24` collides with an existing Docker network on your node,
   change the subnet in both the dind `command` and the `hostAliases` entry.

## Relationship to the GitOps manifests

These examples are **generated from** the overlays and kept in sync by hand; they
are not applied by ArgoCD. For anything beyond a quick demo, use the GitOps path
in the [root README](../README.md) so changes are versioned and reconciled.

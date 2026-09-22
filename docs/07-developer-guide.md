# 07 — Developer Guide

How to create and use your personal ephemeral environment (virtual cluster).

## Concepts

- You get **one** virtual cluster, named `dev-<username>`.
- You choose a **template** at creation time. Each deploys a
  [floci.io](https://floci.io) local cloud emulator inside your vcluster:
  - **`floci-aws`** — AWS emulator (`floci/floci`, reachable at
    `http://floci-aws.default.svc:4566`); includes a Docker-in-Docker sidecar so
    Docker-backed services (Lambda, RDS, ECS, ...) work too.
  - **`floci-azure`** — Azure emulator (`floci/floci-az`, reachable at
    `http://floci-azure.default.svc:4577`, HTTP+HTTPS); also includes a DinD
    sidecar so Docker-backed services (Functions, Event Hubs, Azure SQL, AKS, ...)
    work too.
  - Both share the same quota (limits `3` CPU / `4Gi`).
- The two differ **only** by the emulator deployed (AWS vs Azure); quota, distro,
  ingress, and storage are identical.
- Access is over **HTTP**; your env is reachable at `http://dev-<username>.<env>.local`.

## 1. Log in

```bash
uffizzi login --server http://api.dev.local
```
Use the credentials your platform admin provisioned (the first-user / your account).

## 2. Create your virtual cluster

Using the CLI:
```bash
uffizzi cluster create dev-<username>
# select the floci-aws or floci-azure profile when prompted / via flag
```

Or apply a preset manifest directly (set your name and host first):
```bash
# copy a preset and fill placeholders
cp environments/dev/templates/floci-azure.yaml /tmp/my-cluster.yaml
sed -i 's/<username>/alice/g' /tmp/my-cluster.yaml
kubectl apply -f /tmp/my-cluster.yaml
```

## 3. Get your kubeconfig

The CLI returns/updates a kubeconfig for your vcluster:
```bash
uffizzi cluster list
uffizzi cluster kubeconfig dev-<username> > ~/.kube/dev-<username>.yaml
export KUBECONFIG=~/.kube/dev-<username>.yaml
kubectl get ns
```

## 4. Deploy into your env

Your vcluster comes pre-loaded with the floci emulator (a `floci-aws` or
`floci-azure` pod in the `default` namespace) — that's expected. Deploy your own
workloads alongside it and point them at the emulator endpoint from step "How do I
reach the emulator?" below. Treat it like a normal cluster:
```bash
kubectl apply -f my-app.yaml
kubectl get pods
```
Expose an HTTP service through the env host `http://dev-<username>.<env>.local`
(ensure the name resolves to the node IP — see [Prerequisites](03-prerequisites.md#dns)).

## 5. Choosing a template

- `floci-aws` gives you an AWS emulator; `floci-azure` gives you an Azure emulator.
  Both have the same quota and DinD sidecar — pick based on the cloud you're
  targeting.
- To switch template, recreate with the other one (there is one vcluster per
  developer, so delete the old one first):
  ```bash
  uffizzi cluster delete dev-<username>
  uffizzi cluster create dev-<username>   # pick the other profile
  ```

## 6. Clean up

Ephemeral means disposable — delete when done:
```bash
uffizzi cluster delete dev-<username>
```

## FAQ

**Can I have two clusters?**
No — the model is one per developer (`dev-<username>`). Delete and recreate to change.

**Is there a web dashboard?**
No. The open-source setup is CLI-only; the Uffizzi Dashboard is not included.

**Why HTTP and not HTTPS?**
The **Traefik ingress** (how you reach the API and your env host
`http://dev-<username>.<env>.local`) is intentionally HTTP-only — no certificate
management at the ingress layer. Do not rely on it for transport security.

This is separate from the floci emulator **inside** the vcluster: `floci-azure`
serves HTTPS on its in-cluster service (`floci-azure.default.svc:4577`) with a
self-signed cert, because the Cosmos DB Java SDK and Terraform `azurerm` require it.
That TLS is internal to the vcluster and unrelated to the ingress.

**What's actually different between floci-aws and floci-azure?**
Only the [floci.io](https://floci.io) emulator deployed inside the vcluster:
AWS `floci/floci` on `:4566` vs Azure `floci/floci-az` on `:4577`. Both run a DinD
sidecar and share the same quota. Everything else — distro, ingress, storage — is
identical. (floci-azure additionally serves HTTPS, required by the Cosmos Java SDK
and Terraform azurerm.)

**How do I reach the emulator?**
Three ways, depending on where your client runs:

1. **From inside your vcluster** (workloads you deploy there) — use the in-cluster
   Service DNS:
   - AWS: `http://floci-aws.default.svc:4566`
   - Azure: `http://floci-azure.default.svc:4577` (also HTTPS on the same port)
2. **From your laptop, via the env host** — each emulator has its own Ingress that
   Uffizzi exposes through the host cluster (HTTP):
   - AWS: `http://floci-aws-<username>.<env>.local`
   - Azure: `http://floci-azure-<username>.<env>.local`

   These `.local` names must resolve to the node IP (hosts file or local DNS), same
   as your env host — see [Prerequisites](03-prerequisites.md#dns).
3. **From your laptop, via port-forward** (no DNS needed):
   ```bash
   kubectl port-forward svc/floci-aws 4566:4566   # then use http://localhost:4566
   ```

Point your AWS/Azure SDK, CLI, or Terraform provider at whichever endpoint applies.
Note the Ingress routes plain **HTTP**; for the Azure TLS paths (Cosmos Java SDK,
Terraform `azurerm`) use the in-cluster HTTPS endpoint or port-forward instead.

- `floci-aws` runs a Docker-in-Docker sidecar, so both in-process services (S3,
  SQS, DynamoDB, IAM, ...) **and** Docker-backed ones (Lambda, RDS, ECS, EKS, ...)
  are available. Containers it spawns are ephemeral (lost on pod restart).
- `floci-azure` also runs a DinD sidecar, so both in-process services (Blob, Queue,
  Table, Key Vault, Cosmos NoSQL, ...) **and** Docker-backed ones (Functions,
  Event Hubs, Azure SQL, AKS, Redis, ...) are available. The Cosmos multi-API
  engines (Mongo/Postgres/Cassandra/Gremlin) are off by default — enable each with
  `FLOCI_AZ_SERVICES_COSMOS_ENGINES_<API>_ENABLED=true`.

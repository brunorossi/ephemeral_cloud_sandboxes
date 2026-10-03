# Demo scripts

End-to-end demo scripts that exercise each emulator stack over HTTP: they create a
resource (function, queue, service, …) and then invoke or trigger it. They are
meant to be run **after** a stack is up (via the GitOps path or an
[`examples/`](../examples) manifest).

Full usage, arguments, and the OCI Functions wiring notes are documented in
[`examples/README.md`](../examples/README.md#demo-scripts). Quick index:

| Cloud | Directory | Scripts |
|-------|-----------|---------|
| AWS   | [`aws/`](aws)     | `deploy-lambda.sh`, `deploy-sqs-lambda.sh`, `deploy-apig-lambda.sh`, `deploy-apig-lambda-dynamodb.sh` |
| GCP   | [`gcp/`](gcp)     | `deploy-cloud-run.sh` |
| OCI   | [`oci/`](oci)     | `deploy-function.sh` |

> `floci-az` (Azure) has no demo script yet; deploy
> [`examples/floci-az.yaml`](../examples/floci-az.yaml) and drive it with the
> `az` CLI against `http://brossi.dev.floci-az.local`.

Common properties:

- Each script defaults to the `brossi.dev.<tech>.local` ingress host and accepts
  overrides as positional arguments (see the per-script header comments).
- Credentials are **mock** values; the emulators parse but never verify them.
- They require the matching cloud CLI (`aws`, `az`, `oci`) and `curl` on `PATH`.

```bash
# Examples
./scripts/aws/deploy-lambda.sh
./scripts/gcp/deploy-cloud-run.sh
./scripts/oci/deploy-function.sh
```

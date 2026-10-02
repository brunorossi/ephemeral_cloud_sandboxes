#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# ============================================================================
# Deploy & invoke a serverless Function on a floci-oci emulator over HTTP,
# mirroring the AWS Lambda example (scripts/aws/deploy-lambda.sh) but using the
# OCI model (Application -> image-based Function -> invoke).
#
# HOW floci-oci Functions works:
#   floci-oci implements the OCI Functions control plane (API version
#   /20181201) and performs REAL invocation: it proxies the call to a shared
#   fnproject/fnserver sidecar that runs your function image as a sibling
#   container and speaks the Fn FDK http-stream contract. In THIS repo that
#   sidecar is the `dind-sidecar` container in the floci-oci pod (see
#   bases/floci-oci/deployment.yaml); floci-oci reaches it via
#   DOCKER_HOST=tcp://localhost:2375.
#
#   The official OCI CLI works unchanged against the emulator: point every call
#   at the ingress host with `--endpoint`. Any locally generated API key works
#   because floci-oci parses the request signature for tenancy/user context but
#   never verifies it. For a no-key run we rely on floci-oci's unsigned-request
#   fallback to FLOCI_OCI_DEFAULT_TENANCY_ID.
#
# FLOW (all via `oci fn ...` + raw-request, like `aws lambda ...` in the AWS script):
#   1. Create an Application   -> oci fn application create
#   2. Create an image-based Function in it -> oci fn function create --image ...
#   3. Invoke it over HTTP     -> oci raw-request POST to the Functions
#                                 data-plane invoke path, forced at the ingress
#                                 host (the high-level `oci fn function invoke`
#                                 would instead follow the function's advertised
#                                 invoke endpoint, which floci-oci reports as its
#                                 internal http://localhost:4599 and is not
#                                 reachable from the client). Starts the real
#                                 container on first call.
#
# IMAGE NOTE:
#   fnserver can only run images that implement the Fn FDK http-stream contract.
#   The default below, fnproject/fdk-go-hello, is a PREBUILT public FDK function
#   (Go, entrypoint ./func) that fnserver pulls and runs directly -- no local
#   build and no registry push needed. It returns a JSON greeting and echoes any
#   request body. A plain image (e.g. fnproject/hello) is NOT an FDK function and
#   fails with "Container failed to initialize ... latest fdk".
#
#   ARCH CAVEAT: fdk-go-hello is amd64-only. On an amd64 node it runs natively;
#   on an arm64 node the DinD daemon needs QEMU/binfmt to run it (same situation
#   as floci-az Functions). Override with $4 to use a different FDK image.
# ============================================================================

# --- 1. CONFIGURATION PARAMETERS (Arguments or Defaults) ---
# $1 Endpoint URL (the ingress host fronting the floci-oci service; see
#    examples/floci-oci.yaml). $2 Application name. $3 Function name.
#    $4 Function image (must be a valid FDK image pullable by the cluster).
ENDPOINT_URL="${1:-http://brossi.dev.floci-oci.local}"
APP_NAME="${2:-brossi-fn-app-9}"
FUNCTION_NAME="${3:-brossi-hello-fn-9}"
IMAGE="${4:-fnproject/fdk-go-hello:latest}"
MEMORY_MB="128"

# floci-oci default local tenancy OCID (used as compartment id for the demo).
# This matches FLOCI_OCI_DEFAULT_TENANCY_ID in the emulator. Note the canonical
# OCID shape (ocid1.<type>.oc1..aaaa<unique>): the OCI CLI validates OCID format
# locally before sending, so the unique part must start with 'aaaa'.
COMPARTMENT_ID="ocid1.tenancy.oc1..aaaaaaaaflocilocaltenancy000000000000000000000000000000000"
USER_ID="ocid1.user.oc1..aaaaaaaaflocilocaluser00000000000000000000000000000000000000"
# floci-oci does not validate networking; a placeholder subnet id satisfies the
# required --subnet-ids parameter of `oci fn application create`.
SUBNET_ID="ocid1.subnet.oc1.phx.aaaaaaaaflocilocalsubnet0000000000000000000000000000000000"

# Body sent to the function on invocation (parsed by the hello FDK image).
PAYLOAD_INPUT='{"name": "Brossi"}'

echo "📌 Using Endpoint URL : $ENDPOINT_URL"
echo "📌 Application Name   : $APP_NAME"
echo "📌 Function Name      : $FUNCTION_NAME"
echo "📌 Image              : $IMAGE (${MEMORY_MB} MiB)"
echo "--------------------------------------------------"

# The OCI CLI is required (it drives every call, like the AWS CLI does for AWS).
if ! command -v oci >/dev/null 2>&1; then
  echo "❌ Error: the 'oci' CLI is required. Install it from:"
  echo "   https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
  exit 1
fi

# --- 2. SET UP A THROWAWAY OCI CONFIG / KEY (mock credentials) ---
# Equivalent to exporting mock AWS_* vars in the AWS script. floci-oci never
# verifies the signature, so a freshly generated local key is enough.
echo "🔑 Preparing throwaway OCI credentials..."
# Silence the OCI CLI "increase security of your API key" label warning; the
# key is a throwaway generated below.
export SUPPRESS_LABEL_WARNING=True
OCI_TMP_DIR="$(mktemp -d)"
# Ensure every temp artifact is removed on exit (incl. errors).
cleanup() { rm -rf "$OCI_TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

KEY_FILE="$OCI_TMP_DIR/floci_key.pem"
CONFIG_FILE="$OCI_TMP_DIR/config"

# Generate an unencrypted RSA key (any local key works with floci-oci).
openssl genrsa -out "$KEY_FILE" 2048 >/dev/null 2>&1

cat > "$CONFIG_FILE" <<EOF
[DEFAULT]
user=$USER_ID
fingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99
tenancy=$COMPARTMENT_ID
region=us-ashburn-1
key_file=$KEY_FILE
EOF
chmod 600 "$CONFIG_FILE"

# Control-plane oci calls share these flags: throwaway config + emulator
# endpoint. (raw-request below must NOT use --endpoint; it rejects that flag and
# takes the full URL via --target-uri instead.)
OCI="oci --config-file $CONFIG_FILE --endpoint $ENDPOINT_URL"
# For raw-request: same throwaway config, but no --endpoint flag.
OCI_RAW="oci --config-file $CONFIG_FILE"

# --- 3. CREATE (OR REUSE) THE APPLICATION ---
# Idempotent: if an application with this name already exists (409 Conflict on
# re-run), look up its OCID instead of failing.
echo "☁️  Ensuring Function Application '$APP_NAME' exists on floci-oci..."
APP_OUTPUT=$($OCI fn application create \
  --compartment-id "$COMPARTMENT_ID" \
  --display-name "$APP_NAME" \
  --subnet-ids "[\"$SUBNET_ID\"]" 2>/dev/null || true)
APP_ID=$(echo "$APP_OUTPUT" | grep -o '"id": *"[^"]*' | head -n 1 | grep -o 'ocid1[^"]*' || true)

if [ -z "$APP_ID" ]; then
  # Already exists (or create returned nothing): resolve by display name.
  APP_ID=$($OCI fn application list \
    --compartment-id "$COMPARTMENT_ID" \
    --display-name "$APP_NAME" 2>/dev/null \
    | grep -o '"id": *"ocid1.fnapp[^"]*' | grep -o 'ocid1[^"]*' | head -n 1 || true)
fi

if [ -z "$APP_ID" ]; then
  echo "❌ Could not create or find application '$APP_NAME'."
  exit 1
fi
echo "✅ Application OCID: $APP_ID"

# --- 4. CREATE (OR REUSE) THE IMAGE-BASED FUNCTION ---
echo "🚀 Ensuring Function '$FUNCTION_NAME' exists (image=$IMAGE)..."
FN_OUTPUT=$($OCI fn function create \
  --application-id "$APP_ID" \
  --display-name "$FUNCTION_NAME" \
  --image "$IMAGE" \
  --memory-in-mbs "$MEMORY_MB" 2>/dev/null || true)
FUNCTION_ID=$(echo "$FN_OUTPUT" | grep -o '"id": *"[^"]*' | head -n 1 | grep -o 'ocid1[^"]*' || true)

if [ -z "$FUNCTION_ID" ]; then
  # Already exists: resolve by display name within the application.
  FUNCTION_ID=$($OCI fn function list \
    --application-id "$APP_ID" \
    --display-name "$FUNCTION_NAME" 2>/dev/null \
    | grep -o '"id": *"ocid1.fnfunc[^"]*' | grep -o 'ocid1[^"]*' | head -n 1 || true)
fi

if [ -z "$FUNCTION_ID" ]; then
  echo "❌ Could not create or find function '$FUNCTION_NAME'."
  exit 1
fi
echo "✅ Function OCID: $FUNCTION_ID"

# --- 5. INVOKE THE FUNCTION OVER HTTP (raw request against the ingress) ---
# NOTE: `oci fn function invoke` sends the call to the function's self-reported
# invoke endpoint, which floci-oci returns as its internal base URL
# (http://localhost:4599). That host does not exist on the client side, so the
# high-level invoke never reaches the emulator through the ingress.
#
# Instead we issue the OCI Functions data-plane invoke directly with
# `oci raw-request`, forcing the target URI at the ingress host so the request
# is routed to floci-oci regardless of the function's advertised endpoint:
#
#   POST {ENDPOINT}/20181201/functions/{functionId}/actions/invoke
#
# floci-oci starts the real container on first call, so this can take 10-30s
# while the image is pulled/started by the fnserver sidecar; a 503
# "fnserver sidecar did not become ready" during that window is retried.
INVOKE_URI="$ENDPOINT_URL/20181201/functions/$FUNCTION_ID/actions/invoke"

echo "--------------------------------------------------"
echo "🎯 Invoking the Function via oci raw-request..."
echo "➡️  POST $INVOKE_URI"
echo "ℹ️  First invoke spins up a real container; it may take 10-30s."

for attempt in 1 2 3 4 5 6; do
  echo "   attempt $attempt..."
  # Capture body+status; raw-request prints a JSON envelope with "data",
  # "headers" and "status". On a cold start floci-oci replies 503 with a
  # "fnserver sidecar did not become ready" body, so we retry on that.
  RAW_RESP=$($OCI_RAW raw-request \
    --http-method POST \
    --target-uri "$INVOKE_URI" \
    --request-body "$PAYLOAD_INPUT" 2>/dev/null || true)

  # Non-retryable: the image is not a valid FDK function (shouldn't happen with
  # the image we build, but surface it clearly instead of looping).
  if printf '%s' "$RAW_RESP" | grep -qi 'Container failed to initialize'; then
    echo "❌ The function image failed to initialize under the FDK contract:"
    printf '%s\n' "$RAW_RESP"
    exit 1
  fi

  if [ -n "$RAW_RESP" ] \
     && ! printf '%s' "$RAW_RESP" | grep -q '"status": *"5' \
     && ! printf '%s' "$RAW_RESP" | grep -qi 'did not become ready'; then
    echo "📄 Function response:"
    printf '%s\n' "$RAW_RESP"
    echo "--------------------------------------------------"
    echo "✅ Function responded successfully!"
    echo "--------------------------------------------------"
    exit 0
  fi
  sleep 5
done

echo
echo "⚠️  Function did not respond after retries. Last response:"
printf '%s\n' "$RAW_RESP"
echo "Inspect the floci-oci pod logs:"
echo "    kubectl logs -n brossi-dev-floci-oci deploy/brossi-dev-floci-oci-deployment -c floci-oci"
echo "    kubectl logs -n brossi-dev-floci-oci deploy/brossi-dev-floci-oci-deployment -c dind-sidecar"
exit 1

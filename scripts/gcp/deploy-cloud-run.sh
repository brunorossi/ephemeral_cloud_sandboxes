#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# ============================================================================
# Deploy a Cloud Run service to a floci-gcp emulator and reach it over HTTP.
#
# WHY CLOUD RUN (not Cloud Functions):
#   floci-gcp implements Cloud Functions as CONTROL PLANE ONLY — it can create
#   the resource but never executes your code. Cloud Run, by contrast, performs
#   real image-based execution: it spawns a Docker container for the service and
#   proxies HTTP requests to it. So Cloud Run is the way to get a working HTTP
#   endpoint on floci-gcp.
#
# HOW floci-gcp Cloud Run works (Admin API v2, REST JSON):
#   Create : POST   /v2/projects/{project}/locations/{location}/services?serviceId={svc}
#            -> returns a long-running operation (LRO); execution starts a real
#               container and the LRO completes once its TCP port is reachable.
#   Poll   : GET    /v2/projects/{project}/locations/{location}/operations/{op}
#   Invoke : floci-gcp generates a host-routed URL
#            (http://{svc}-{token}.{loc}.run.<suffix>:4588) whose token is a
#            SHA-256 derivation we cannot easily precompute. It ALSO accepts a
#            deterministic legacy front-door path that needs no special DNS:
#               /run/v2/projects/{project}/locations/{location}/services/{svc}
#            We use the legacy path for a reliable demo, and also print the
#            generated uri read back from the service.
#
# IMAGE / ARCH NOTE:
#   The container runs on YOUR node's Docker (the DinD sidecar). On an arm64
#   node use an arm64 or multi-arch image. hashicorp/http-echo is multi-arch and
#   needs no app code, so it runs natively on arm64 with no QEMU emulation.
# ============================================================================

# --- 1. CONFIGURATION ---
# The ingress host fronting the floci-gcp service (see examples/floci-gcp.yaml).
BASE_ENDPOINT="${1:-http://brossi.dev.floci-gcp.local}"

# Must match FLOCI_GCP_DEFAULT_PROJECT_ID in the manifest (default: floci-local).
PROJECT="${2:-floci-local}"
LOCATION="${3:-europe-west1}"
SERVICE="${4:-brossi-http-run}"

# Multi-arch demo image; serves a fixed body on its listen port.
IMAGE="hashicorp/http-echo:1.0"
CONTAINER_PORT="5678"
ECHO_TEXT="Hello Brossi! Served by Cloud Run on floci-gcp."

API="$BASE_ENDPOINT/v2/projects/$PROJECT/locations/$LOCATION"

echo "📌 Base endpoint : $BASE_ENDPOINT"
echo "📌 Project/Loc   : $PROJECT / $LOCATION"
echo "📌 Service       : $SERVICE"
echo "📌 Image         : $IMAGE (port $CONTAINER_PORT)"
echo "--------------------------------------------------"

for tool in curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "❌ Error: '$tool' is required."; exit 1
  fi
done

# Optional: python3 is used to pretty-parse JSON if present; falls back to grep.
json_get() {
  # json_get <json> <python-expression-on-variable d>
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print($2)" 2>/dev/null || true
  fi
}

# --- 2. CREATE THE CLOUD RUN SERVICE ---
echo "☁️  2. Creating Cloud Run service (starts a real container)..."

CREATE_BODY=$(cat <<JSON
{
  "template": {
    "containers": [
      {
        "image": "$IMAGE",
        "args": ["-text=$ECHO_TEXT", "-listen=:$CONTAINER_PORT"],
        "ports": [ { "containerPort": $CONTAINER_PORT } ]
      }
    ]
  }
}
JSON
)

CREATE_RESP=$(curl -fsS -X POST \
  "$API/services?serviceId=$SERVICE" \
  -H "Content-Type: application/json" \
  -d "$CREATE_BODY")

echo "   create response:"
echo "$CREATE_RESP"

# The create call returns a google.longrunning.Operation. Extract its name.
OP_NAME=$(json_get "$CREATE_RESP" "d.get('name','')")
# Operation names look like projects/.../locations/.../operations/{id}; keep the tail.
OP_ID="${OP_NAME##*/}"

echo "--------------------------------------------------"
if [ -n "$OP_ID" ]; then
  echo "⏳ 3. Waiting for operation '$OP_ID' to complete (container startup)..."
  for attempt in $(seq 1 60); do
    OP_RESP=$(curl -fsS "$API/operations/$OP_ID" 2>/dev/null || echo '{}')
    DONE=$(json_get "$OP_RESP" "str(d.get('done', False)).lower()")
    if [ "$DONE" = "true" ]; then
      echo "   operation done."
      ERR=$(json_get "$OP_RESP" "json.dumps(d.get('error')) if d.get('error') else ''")
      if [ -n "$ERR" ] && [ "$ERR" != "null" ]; then
        echo "❌ Operation failed: $ERR"
        echo "   Check the floci-gcp pod log for container startup errors."
        exit 1
      fi
      break
    fi
    sleep 3
  done
else
  echo "ℹ️  No operation name returned; assuming synchronous completion. Continuing."
fi

# --- 4. READ BACK THE SERVICE (shows generated uri + ready condition) ---
echo "--------------------------------------------------"
echo "🔎 4. Reading service back..."
SVC_RESP=$(curl -fsS "$API/services/$SERVICE" 2>/dev/null || echo '{}')
GEN_URI=$(json_get "$SVC_RESP" "d.get('uri','')")
READY=$(json_get "$SVC_RESP" "next((c.get('state','') for c in d.get('conditions',[]) if c.get('type')=='Ready'), '')")
echo "   generated uri : ${GEN_URI:-<none>}"
echo "   ready state   : ${READY:-<unknown>}"

# --- 5. INVOKE OVER THE INGRESS HOST (legacy front-door path) ---
# The legacy path is deterministic and routes through brossi.dev.floci-gcp.local
# without needing to resolve the generated *.run.<suffix> hostname.
echo "--------------------------------------------------"
echo "🌐 5. Invoking the service via the legacy front-door path..."
INVOKE_URL="$BASE_ENDPOINT/run/v2/projects/$PROJECT/locations/$LOCATION/services/$SERVICE"
echo "➡️  GET $INVOKE_URL"

for attempt in 1 2 3 4 5 6; do
  echo "   attempt $attempt..."
  if curl -fsS "$INVOKE_URL"; then
    echo
    echo "--------------------------------------------------"
    echo "✅ Cloud Run service responded successfully!"
    echo "   (Generated host-routed URL, if you prefer it: ${GEN_URI:-n/a})"
    echo "--------------------------------------------------"
    exit 0
  fi
  sleep 5
done

echo
echo "⚠️  No response after retries. Inspect the floci-gcp pod logs:"
echo "    kubectl logs -n brossi-dev-floci-gcp deploy/brossi-dev-floci-gcp-deployment -c floci-gcp"
echo "    kubectl logs -n brossi-dev-floci-gcp deploy/brossi-dev-floci-gcp-deployment -c dind-sidecar"
exit 1

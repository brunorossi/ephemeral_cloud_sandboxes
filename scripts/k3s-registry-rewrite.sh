#!/usr/bin/env bash
# =============================================================================
# k3s-registry-rewrite.sh — rewrite dead gcr.io/kubebuilder images to quay.io
# =============================================================================
# WHY: The uffizzi-cluster-operator chart hardcodes
#         gcr.io/kubebuilder/kube-rbac-proxy:v0.13.1
#      in its Deployment template (no Helm value to override it). Google
#      retired the gcr.io/kubebuilder distribution, so that pull now fails with
#      "not found" / ErrImagePull. The image is published upstream at
#         quay.io/brancz/kube-rbac-proxy:v0.13.1
#      This script configures K3s containerd to transparently rewrite the pull
#      at the node level, so no chart edit or vendoring is needed.
#
# WHAT IT DOES (idempotent):
#   1. Backs up any existing /etc/rancher/k3s/registries.yaml (timestamped).
#   2. Writes/merges a gcr.io mirror that rewrites the kube-rbac-proxy repo
#      path to quay.io/brancz, preserving the tag.
#   3. Restarts k3s so containerd reloads the registry config.
#   4. (Optional) Deletes the stuck kube-rbac-proxy pod(s) so they re-pull.
#
# SCOPE / CAVEAT: This is NODE-LEVEL config and lives OUTSIDE GitOps. It must be
#   re-applied if the node is rebuilt (bake into node provisioning if you can).
#   The mirror only rewrites the kubebuilder/kube-rbac-proxy path; other gcr.io
#   repos are routed to the quay.io endpoint but not rewritten, so pin/verify if
#   this node pulls other gcr.io images.
#
# REQUIREMENTS: run ON THE K3S NODE, as root (or via sudo). Needs: k3s, kubectl.
#
# Usage (on the node):
#   sudo ./scripts/k3s-registry-rewrite.sh                 # apply + restart + repull
#   sudo DELETE_PODS=false ./scripts/k3s-registry-rewrite.sh   # skip pod deletion
#   sudo RESTART=false ./scripts/k3s-registry-rewrite.sh       # write config only
#   sudo NAMESPACE=eph-env ./scripts/k3s-registry-rewrite.sh   # override namespace
#   DRY_RUN=true ./scripts/k3s-registry-rewrite.sh             # print, change nothing
# =============================================================================
set -euo pipefail

REG_FILE="${REG_FILE:-/etc/rancher/k3s/registries.yaml}"
NAMESPACE="${NAMESPACE:-eph-env}"
RESTART="${RESTART:-true}"
DELETE_PODS="${DELETE_PODS:-true}"
DRY_RUN="${DRY_RUN:-false}"
MARKER="# managed-by: k3s-registry-rewrite.sh (uffizzi kube-rbac-proxy fix)"

# The mirror block appended to registries.yaml. Rewrites
#   gcr.io/kubebuilder/kube-rbac-proxy:<tag> -> quay.io/brancz/kube-rbac-proxy:<tag>
read -r -d '' MIRROR_BLOCK <<'YAML' || true
mirrors:
  gcr.io:
    endpoint:
      - "https://quay.io"
    rewrite:
      "kubebuilder/kube-rbac-proxy:(.*)": "brancz/kube-rbac-proxy:$1"
YAML

log() { echo "[k3s-registry-rewrite] $*"; }

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY_RUN=true — would write the following to ${REG_FILE}:"
  echo "----------------------------------------"
  printf '%s\n%s\n' "$MARKER" "$MIRROR_BLOCK"
  echo "----------------------------------------"
  log "Would then restart k3s and (if DELETE_PODS=true) delete kube-rbac-proxy pods in ns/${NAMESPACE}."
  exit 0
fi

# Must be root to write /etc/rancher and restart the service.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)." >&2
  exit 1
fi

# 1) Idempotency guard: skip if our marker is already present.
if [[ -f "$REG_FILE" ]] && grep -qF "$MARKER" "$REG_FILE"; then
  log "Mirror already present in ${REG_FILE}; not modifying."
else
  mkdir -p "$(dirname "$REG_FILE")"
  if [[ -f "$REG_FILE" ]]; then
    backup="${REG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$REG_FILE" "$backup"
    log "Backed up existing config -> ${backup}"
    log "NOTE: an existing registries.yaml may already define 'mirrors:'."
    log "      This script APPENDS a block; if 'mirrors:' already exists you"
    log "      must MERGE manually (YAML does not allow duplicate keys)."
    printf '\n%s\n%s\n' "$MARKER" "$MIRROR_BLOCK" >> "$REG_FILE"
  else
    printf '%s\n%s\n' "$MARKER" "$MIRROR_BLOCK" > "$REG_FILE"
    log "Wrote new ${REG_FILE}"
  fi
fi

# 2) Restart k3s so containerd reloads the registry config.
if [[ "$RESTART" == "true" ]]; then
  if systemctl list-units --type=service 2>/dev/null | grep -q 'k3s.service'; then
    log "Restarting k3s.service ..."
    systemctl restart k3s
  elif systemctl list-units --type=service 2>/dev/null | grep -q 'k3s-agent.service'; then
    log "Restarting k3s-agent.service ..."
    systemctl restart k3s-agent
  else
    log "WARN: no k3s/k3s-agent systemd unit found; restart the runtime manually."
  fi
else
  log "RESTART=false — skipping k3s restart (config written only)."
fi

# 3) Re-trigger the image pull by deleting the stuck pod(s).
if [[ "$DELETE_PODS" == "true" ]]; then
  if command -v kubectl >/dev/null 2>&1; then
    log "Deleting kube-rbac-proxy pod(s) in ns/${NAMESPACE} to force re-pull ..."
    kubectl -n "$NAMESPACE" delete pod \
      -l app.kubernetes.io/component=kube-rbac-proxy --ignore-not-found || \
      log "WARN: label-based delete failed; delete the operator pod manually."
  else
    log "WARN: kubectl not found; delete the operator pod manually to re-pull."
  fi
fi

log "Done. Verify with:"
log "  kubectl -n ${NAMESPACE} get pods | grep cluster-operator"
log "  kubectl -n ${NAMESPACE} describe pod <operator-pod> | grep -i image"

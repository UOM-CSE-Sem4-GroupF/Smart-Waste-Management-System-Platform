#!/usr/bin/env bash
# System test: verify that namespaces/namespaces-dev.yaml creates all 8 required namespaces.
# Uses a temporary kind cluster so it does not touch any existing cluster.
#
# Requirements: kind, kubectl

set -euo pipefail

CLUSTER_NAME="swms-ns-test-$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAMESPACES_MANIFEST="$REPO_ROOT/namespaces/namespaces-dev.yaml"

EXPECTED_NAMESPACES=(
  gateway
  auth
  messaging
  monitoring
  cicd
  blockchain
  waste-dev
  waste-prod
)

log()  { echo "[namespace-test] $*"; }
fail() { echo "[FAIL] $*" >&2; kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true; exit 1; }

for tool in kind kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool '$tool' not found"; exit 1; }
done

log "Creating kind cluster: $CLUSTER_NAME"
kind create cluster --name "$CLUSTER_NAME" --wait 60s

log "Applying namespaces manifest"
kubectl apply -f "$NAMESPACES_MANIFEST"

log "Verifying all ${#EXPECTED_NAMESPACES[@]} namespaces exist"
FAILED=0
for ns in "${EXPECTED_NAMESPACES[@]}"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    log "  ✓ $ns"
  else
    log "  ✗ $ns MISSING"
    FAILED=1
  fi
done

log "Verifying namespace labels"
for ns in "${EXPECTED_NAMESPACES[@]}"; do
  MANAGED_BY=$(kubectl get namespace "$ns" \
    -o jsonpath='{.metadata.labels.managed-by}' 2>/dev/null || echo "")
  if [ "$MANAGED_BY" = "f4-platform" ]; then
    log "  ✓ $ns: managed-by=f4-platform"
  else
    log "  ✗ $ns: managed-by label missing or incorrect (got '$MANAGED_BY')"
    FAILED=1
  fi
done

log "Cleaning up kind cluster"
kind delete cluster --name "$CLUSTER_NAME"

if [ "$FAILED" -eq 1 ]; then
  echo ""
  echo "=== System test FAILED: some namespaces missing or misconfigured ==="
  exit 1
fi

echo ""
echo "=== System test PASSED: all ${#EXPECTED_NAMESPACES[@]} namespaces created with correct labels ==="

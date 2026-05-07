#!/usr/bin/env bash
# System test: spin up a kind cluster, install base-service chart for bin-status,
# verify the pod reaches Running state, then tear down.
#
# Requirements: kind, kubectl, helm

set -euo pipefail

CLUSTER_NAME="swms-test-$$"
NAMESPACE="waste-dev"
RELEASE="bin-status-test"
TIMEOUT="90s"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log()  { echo "[system-test] $*"; }
fail() { echo "[FAIL] $*" >&2; kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true; exit 1; }

# --- Prereq check ---
for tool in kind kubectl helm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool '$tool' not found"; exit 1; }
done

log "Creating kind cluster: $CLUSTER_NAME"
kind create cluster --name "$CLUSTER_NAME" --wait 60s

log "Setting kubectl context"
kubectl cluster-info --context "kind-$CLUSTER_NAME"

log "Creating namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE"

log "Running helm dependency update for bin-status"
helm dependency update "$REPO_ROOT/apps/bin-status/" >/dev/null 2>&1 || true

log "Installing bin-status chart"
helm install "$RELEASE" "$REPO_ROOT/apps/bin-status/" \
  --namespace "$NAMESPACE" \
  --values "$REPO_ROOT/apps/bin-status/values-dev.yaml" \
  --set "base-service.externalSecret.enabled=false" \
  --set "base-service.image.repository=nginx" \
  --set "base-service.image.tag=alpine" \
  --set "base-service.podSecurityContext.runAsNonRoot=false" \
  --set "base-service.podSecurityContext.runAsUser=0" \
  --set "base-service.containerSecurityContext.runAsNonRoot=false" \
  --set "base-service.containerSecurityContext.runAsUser=0" \
  --set "base-service.containerSecurityContext.readOnlyRootFilesystem=false" \
  --wait \
  --timeout "$TIMEOUT"

log "Verifying pod reaches Running state"
kubectl wait --for=condition=ready pod \
  -l "app.kubernetes.io/instance=$RELEASE" \
  -n "$NAMESPACE" \
  --timeout="$TIMEOUT" || fail "Pod did not reach Ready state"

POD_STATUS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
  -o jsonpath='{.items[0].status.phase}')
[ "$POD_STATUS" = "Running" ] || fail "Pod phase is '$POD_STATUS', expected 'Running'"

log "PASS: pod is Running"

log "Cleaning up kind cluster"
kind delete cluster --name "$CLUSTER_NAME"

echo ""
echo "=== System test PASSED: cluster deploy + pod running ==="

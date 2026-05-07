#!/usr/bin/env bash
# Group F SWMS — Full Teardown Script
# Removes all Helm releases and namespaces from the local Minikube cluster.
# WARNING: destroys all data. Safe to re-run (uses --ignore-not-found).
#
# Usage: bash ./scripts/teardown.sh

set -euo pipefail

echo "======================================================"
echo " SWMS — Cluster Teardown"
echo " WARNING: This will delete ALL SWMS resources."
echo "======================================================"
echo ""
read -p "Are you sure? Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "[1/5] Uninstalling Helm releases..."

helm uninstall monitoring    -n monitoring  2>/dev/null && echo "  ✅ monitoring"    || echo "  ⚠️  monitoring not found"
helm uninstall kong          -n gateway     2>/dev/null && echo "  ✅ kong"          || echo "  ⚠️  kong not found"
helm uninstall keycloak      -n auth        2>/dev/null && echo "  ✅ keycloak"      || echo "  ⚠️  keycloak not found"
helm uninstall vault         -n auth        2>/dev/null && echo "  ✅ vault"         || echo "  ⚠️  vault not found"
helm uninstall kafka         -n messaging   2>/dev/null && echo "  ✅ kafka"         || echo "  ⚠️  kafka not found"
helm uninstall emqx          -n messaging   2>/dev/null && echo "  ✅ emqx"          || echo "  ⚠️  emqx not found"
helm uninstall postgres-waste -n waste-dev  2>/dev/null && echo "  ✅ postgres-waste" || echo "  ⚠️  postgres-waste not found"
helm uninstall influxdb      -n waste-dev   2>/dev/null && echo "  ✅ influxdb"      || echo "  ⚠️  influxdb not found"
helm uninstall gatekeeper    -n opa-system  2>/dev/null && echo "  ✅ gatekeeper"    || echo "  ⚠️  gatekeeper not found"
helm uninstall argocd        -n cicd        2>/dev/null && echo "  ✅ argocd"        || echo "  ⚠️  argocd not found"
helm uninstall chaos-mesh    -n cicd        2>/dev/null && echo "  ✅ chaos-mesh"    || echo "  ⚠️  chaos-mesh not found"

echo ""
echo "[2/5] Removing F2/F3 application Helm releases..."
for app in bin-status notification orchestrator scheduler core-api ml-service route-optimizer flink-telemetry airflow spark; do
  helm uninstall "$app" -n waste-dev 2>/dev/null && echo "  ✅ $app" || echo "  ⚠️  $app not found"
done

echo ""
echo "[3/5] Deleting blockchain raw manifests..."
kubectl delete -f blockchain/network/ -n blockchain --ignore-not-found 2>/dev/null || true
kubectl delete -f blockchain/api-wrapper/k8s/ -n blockchain --ignore-not-found 2>/dev/null || true

echo ""
echo "[4/5] Deleting namespaces..."
for ns in gateway auth messaging monitoring cicd blockchain waste-dev waste-prod opa-system eso; do
  kubectl delete namespace "$ns" --ignore-not-found 2>/dev/null && echo "  ✅ $ns" || true
done

echo ""
echo "[5/5] Cleaning up PersistentVolumes..."
kubectl delete pv --all --ignore-not-found 2>/dev/null || true

echo ""
echo "======================================================"
echo " ✅ Teardown complete."
echo " Run 'bash ./scripts/setup-local.sh' to restore."
echo "======================================================"

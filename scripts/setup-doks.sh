#!/usr/bin/env bash
# =============================================================================
# Group F — Smart Waste Management System
# DigitalOcean Kubernetes (DOKS) Deployment Script
# Owner: F4 Platform Team
#
# Usage:
#   export DO_TOKEN="dop_v1_..."   # from DigitalOcean dashboard
#   chmod +x scripts/setup-doks.sh
#   bash scripts/setup-doks.sh
#
# Prerequisites (install via winget on Windows):
#   winget install DigitalOcean.doctl
#   winget install Helm.Helm
#   winget install Kubernetes.kubectl
#   winget install Hashicorp.Terraform
#
# After installing, authenticate:
#   doctl auth init        (paste your API token when prompted)
#
# Cost: ~$84/month on DigitalOcean ($200 GitHub Edu Pro Pack → ~2.4 months)
# Destroy when not in use: cd terraform/do && terraform destroy -var="do_token=$DO_TOKEN"
# =============================================================================

set -euo pipefail

# --- Colour output helpers (same as setup-local.sh) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
log_step()    { echo -e "\n${YELLOW}======================================${NC}"; echo -e "${YELLOW}  $*${NC}"; echo -e "${YELLOW}======================================${NC}"; }

# --- Windows Git Bash PATH fix (mirrors setup-local.sh) ---
for path in /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Links; do
  [ -d "$path" ] && export PATH="$PATH:$path"
done
WIN_PATHS=(
  "/mnt/c/ProgramData/chocolatey/bin"
  "/mnt/c/Program Files/Helm"
)
for p in "${WIN_PATHS[@]}"; do
  [ -d "$p" ] && export PATH="$PATH:$p"
done

# Wrap .exe versions on Windows
for tool in doctl kubectl helm terraform; do
  if command -v "${tool}.exe" &>/dev/null; then
    eval "function $tool() { ${tool}.exe \"\$@\"; }"
  fi
done

# --- Config ---
CLUSTER_NAME="${CLUSTER_NAME:-swms-doks-dev}"
DO_REGION="${DO_REGION:-sgp1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo ""
echo "================================================================"
echo "  Group F SWMS — DigitalOcean Kubernetes Deployment"
echo "================================================================"
echo ""

# --- Step 1: Check prerequisites ---
log_step "Step 1: Checking prerequisites"

for tool in doctl kubectl helm terraform; do
  if command -v "$tool" &>/dev/null || command -v "${tool}.exe" &>/dev/null; then
    log_success "$tool found"
  else
    log_error "'$tool' not found. Install it first (see script header for winget commands)."
  fi
done

if [ -z "${DO_TOKEN:-}" ]; then
  log_error "DO_TOKEN environment variable is not set. Run: export DO_TOKEN='dop_v1_...'"
fi

log_success "Prerequisites OK."

# --- Step 2: Provision DOKS cluster via Terraform ---
log_step "Step 2: Provisioning DOKS cluster (terraform/do)"

log_info "Initialising Terraform providers..."
(cd terraform/do && terraform init -upgrade)

log_info "Applying Terraform (this takes ~5 minutes for DOKS provisioning)..."
(cd terraform/do && terraform apply \
  -var="do_token=$DO_TOKEN" \
  -var="region=$DO_REGION" \
  -auto-approve)

log_success "DOKS cluster provisioned."

# --- Step 3: Configure kubectl ---
log_step "Step 3: Configuring kubectl"

log_info "Saving kubeconfig for cluster '$CLUSTER_NAME'..."
doctl kubernetes cluster kubeconfig save "$CLUSTER_NAME"

log_info "Verifying cluster access..."
kubectl get nodes
log_success "kubectl connected to DOKS."

# --- Step 4: Add Helm repos ---
log_step "Step 4: Adding Helm repositories"

helm repo add kong https://charts.konghq.com          2>/dev/null || true
helm repo add emqx https://repos.emqx.io/charts       2>/dev/null || true
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update
log_success "Helm repos up to date."

# --- Step 5: Create namespaces ---
log_step "Step 5: Creating namespaces"

kubectl apply -f ./namespaces/namespaces-dev.yaml
log_success "Namespaces created."

# --- Step 6: Deploy Kafka ---
log_step "Step 6: Deploying Kafka (messaging namespace)"

if helm status kafka -n messaging &>/dev/null; then
  log_warn "Kafka already deployed — upgrading..."
  helm upgrade kafka oci://registry-1.docker.io/bitnamicharts/kafka \
    --namespace messaging \
    --values ./messaging/kafka/values-dev.yaml \
    --values ./messaging/kafka/values-doks.yaml \
    --wait --timeout 10m
else
  log_info "Installing Kafka..."
  helm install kafka oci://registry-1.docker.io/bitnamicharts/kafka \
    --namespace messaging \
    --values ./messaging/kafka/values-dev.yaml \
    --values ./messaging/kafka/values-doks.yaml \
    --wait --timeout 10m
fi
log_success "Kafka deployed."

# --- Step 7: Create Kafka topics ---
log_step "Step 7: Initialising Kafka topics"

log_info "Waiting for Kafka broker pod to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=kafka \
  -n messaging \
  --timeout=180s

log_info "Running topic initialiser Job..."
kubectl apply -f ./messaging/kafka/topics.yaml -n messaging

log_info "Waiting for topic Job to complete..."
kubectl wait --for=condition=complete job/kafka-topic-init \
  -n messaging --timeout=120s

log_success "All 13 Kafka topics created."

# --- Step 8: Deploy Kong API Gateway ---
log_step "Step 8: Deploying Kong (gateway namespace)"

log_info "Applying Kong declarative config ConfigMap..."
kubectl apply -f ./gateway/kong/kong-config.yaml -n gateway

if helm status kong -n gateway &>/dev/null; then
  log_warn "Kong already deployed — upgrading..."
  helm upgrade kong kong/kong \
    --namespace gateway \
    --values ./gateway/kong/values-dev.yaml \
    --values ./gateway/kong/values-doks.yaml \
    --wait --timeout 5m
else
  log_info "Installing Kong (DB-less mode)..."
  helm install kong kong/kong \
    --namespace gateway \
    --values ./gateway/kong/values-dev.yaml \
    --values ./gateway/kong/values-doks.yaml \
    --wait --timeout 5m
fi
log_success "Kong deployed."

# --- Step 9: Deploy Keycloak ---
log_step "Step 9: Deploying Keycloak (auth namespace)"

log_info "Creating Keycloak realm ConfigMap..."
kubectl create configmap keycloak-realm-config \
  --from-file=waste-management-realm.json=./auth/keycloak/realm-export.json \
  -n auth --dry-run=client -o yaml | kubectl apply -f -

if helm status keycloak -n auth &>/dev/null; then
  log_warn "Keycloak already deployed — upgrading..."
  helm upgrade keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
    --namespace auth \
    --values ./auth/keycloak/values-dev.yaml \
    --values ./auth/keycloak/values-doks.yaml \
    --wait --timeout 10m
else
  log_info "Installing Keycloak..."
  helm install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
    --namespace auth \
    --values ./auth/keycloak/values-dev.yaml \
    --values ./auth/keycloak/values-doks.yaml \
    --wait --timeout 10m
fi
log_success "Keycloak deployed."

# --- Step 10: Deploy Vault ---
log_step "Step 10: Deploying HashiCorp Vault (auth namespace)"

if helm status vault -n auth &>/dev/null; then
  log_warn "Vault already deployed — upgrading..."
  helm upgrade vault hashicorp/vault \
    --namespace auth \
    --values ./auth/vault/values-dev.yaml \
    --wait --timeout 5m
else
  log_info "Installing Vault (dev mode)..."
  helm install vault hashicorp/vault \
    --namespace auth \
    --values ./auth/vault/values-dev.yaml \
    --wait --timeout 5m
fi

log_info "Applying Vault bootstrap Job (seeds secrets + K8s auth)..."
kubectl apply -f ./auth/vault/vault-policies.yaml -n auth

log_info "Waiting for vault-bootstrap Job..."
kubectl wait --for=condition=complete job/vault-bootstrap -n auth --timeout=120s \
  && log_success "Vault bootstrap complete." \
  || log_warn "Bootstrap still running. Check: kubectl logs -n auth -l job-name=vault-bootstrap"

# --- Step 11: Deploy EMQX MQTT Broker ---
log_step "Step 11: Deploying EMQX MQTT Broker (messaging namespace)"

if helm status emqx -n messaging &>/dev/null; then
  log_warn "EMQX already deployed — upgrading..."
  helm upgrade emqx emqx/emqx \
    --namespace messaging \
    --values ./messaging/emqx/values-dev.yaml \
    --values ./messaging/emqx/values-doks.yaml \
    --wait --timeout 5m
else
  log_info "Installing EMQX 5..."
  helm install emqx emqx/emqx \
    --namespace messaging \
    --values ./messaging/emqx/values-dev.yaml \
    --values ./messaging/emqx/values-doks.yaml \
    --wait --timeout 5m
fi

log_info "Applying EMQX bootstrap Job (MQTT users + Kafka bridge rules)..."
kubectl apply -f ./messaging/emqx/emqx-bootstrap.yaml -n messaging

log_info "Waiting for emqx-bootstrap Job..."
kubectl wait --for=condition=complete job/emqx-bootstrap -n messaging --timeout=180s \
  && log_success "EMQX bootstrap complete. MQTT ↔ Kafka bridge live." \
  || log_warn "Bootstrap still running. Check: kubectl logs -n messaging -l job-name=emqx-bootstrap"

# --- Final: Status summary ---
log_step "Final: Deployment complete"

echo ""
log_info "All pods:"
kubectl get pods -A

echo ""
KONG_IP=$(kubectl get svc kong-kong-proxy -n gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")
EMQX_IP=$(kubectl get svc emqx -n messaging \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")

echo ""
echo "================================================================"
echo "  DOKS Deployment Complete!"
echo ""
echo "  Public endpoints:"
echo "  Kong API Gateway:  http://$KONG_IP"
echo "  EMQX MQTT:         $EMQX_IP:1883  (for ESP32 / Node-RED)"
echo ""
echo "  (If IPs show <pending>, wait 1-2 min then rerun:)"
echo "    kubectl get svc kong-kong-proxy -n gateway"
echo "    kubectl get svc emqx -n messaging"
echo ""
echo "  Internal access (kubectl port-forward):"
echo "    Keycloak admin:  kubectl port-forward svc/keycloak -n auth 8080:80"
echo "                     → http://localhost:8080/admin  (admin / swms-admin-dev-2026)"
echo "    Vault UI:        kubectl port-forward svc/vault -n auth 8200:8200"
echo "                     → http://localhost:8200  (token: swms-vault-dev-root-token)"
echo "    EMQX dashboard:  kubectl port-forward svc/emqx -n messaging 18083:18083"
echo "                     → http://localhost:18083  (admin / swms-emqx-dev-2026)"
echo ""
echo "  EMQX MQTT Credentials (F1 team):"
echo "    sensor-device / swms-sensor-dev-2026  (ESP32)"
echo "    edge-gateway  / swms-edge-dev-2026    (Node-RED RPi)"
echo ""
echo "  STOP BILLING when not in use:"
echo "    cd terraform/do && terraform destroy -var=\"do_token=\$DO_TOKEN\""
echo "================================================================"

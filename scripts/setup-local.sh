#!/usr/bin/env bash
# =============================================================================
# Group F — Smart Waste Management System
# Local Development Setup Script
# Owner: F4 Platform Team
#
# Usage:
#   chmod +x scripts/setup-local.sh
#   ./scripts/setup-local.sh
#
# Prerequisites:
#   - Docker Desktop (running)
#   - minikube
#   - kubectl
#   - helm (v3+)
# =============================================================================

set -e  # Exit on any error
set -u  # Treat unset variables as errors

# --- Windows / Git Bash PATH fix ---
# When running bash via Git Bash on Windows, winget-installed tools land in
# Windows Program Files paths that Git Bash doesn't load automatically.
# We append those paths here so the script finds minikube.exe, kubectl.exe,
# and helm.exe. This block is harmless on Linux/Mac (dirs won't exist).
WIN_PATHS=(
  "/mnt/c/Program Files/Kubernetes/Minikube"
  "/mnt/c/Program Files/kubectl"
  "/mnt/c/ProgramData/chocolatey/bin"
  "/mnt/c/Program Files/Helm"
)

# Expand wildcard for Winget path separately since quotes break wildcard expansion
for path in /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Links; do
  if [ -d "$path" ]; then
    WIN_PATHS+=("$path")
  fi
done
for p in "${WIN_PATHS[@]}"; do
  [ -d "$p" ] && export PATH="$PATH:$p"
done

# Create wrapper functions so the rest of the script calls the Windows .exe versions
# if they exist. This prevents the Linux version of kubectl from running and
# failing to find Minikube's Windows-generated ~/.kube/config!
for tool in minikube kubectl helm docker; do
  if command -v "${tool}.exe" &>/dev/null; then
    eval "function $tool() { ${tool}.exe \"\$@\"; }"
  fi
done

# --- Colour output helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Colour

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
log_step()    { echo -e "\n${YELLOW}======================================${NC}"; echo -e "${YELLOW}  $*${NC}"; echo -e "${YELLOW}======================================${NC}"; }

# --- Configuration ---
MINIKUBE_CPUS=4
MINIKUBE_MEMORY=6144   # 6 GB — Kafka + Keycloak + Kong need some headroom
MINIKUBE_DISK=20g
KAFKA_CHART_VERSION="32.4.3"  # Bitnami Kafka chart version (KRaft default)

# Script directory (so relative paths work regardless of where it's called from)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Change into the repo root so we can use relative paths.
# This prevents issues where Windows executables (kubectl.exe) fail 
# to understand Linux-style absolute paths (like /mnt/e/...).
cd "$REPO_ROOT"

echo ""
echo "================================================================"
echo "  Group F SWMS — Local Development Setup"
echo "================================================================"
echo ""

# --- Step 1: Verify prerequisite tools ---
log_step "Step 1: Checking prerequisites"

for tool in docker minikube kubectl helm; do
  if command -v "$tool" &>/dev/null; then
    log_success "$tool found: $(command -v $tool)"
  elif command -v "${tool}.exe" &>/dev/null; then
    log_success "${tool}.exe found: $(command -v "${tool}.exe")"
  else
    log_error "'$tool' (or ${tool}.exe) is not installed or not in PATH. Please install it first and RESTART your terminal."
  fi
done

# --- Step 2: Start Minikube ---
log_step "Step 2: Starting Minikube cluster"

if minikube status | grep -q "Running"; then
  log_warn "Minikube already running — skipping start."
else
  log_info "Starting Minikube with ${MINIKUBE_CPUS} CPUs, ${MINIKUBE_MEMORY}MB RAM, ${MINIKUBE_DISK} disk..."
  minikube start \
    --cpus="$MINIKUBE_CPUS" \
    --memory="$MINIKUBE_MEMORY" \
    --disk-size="$MINIKUBE_DISK" \
    --driver=docker
  log_success "Minikube started."
fi

# Enable Minikube addons
log_info "Enabling ingress addon..."
minikube addons enable ingress >/dev/null 2>&1 || log_warn "Ingress addon already enabled."

# --- Step 3: Creating namespaces ---
log_step "Step 3: Creating namespaces"

kubectl apply -f ./namespaces/namespaces-dev.yaml
log_success "All namespaces created."

# --- Step 4: (No longer needed — using OCI registry directly) ---
log_step "Step 4: Checking Helm OCI support"
helm version --short
log_success "Helm OCI support ready."

# --- Step 5: Deploy Kafka ---
log_step "Step 5: Deploying Kafka (messaging namespace)"

if helm status kafka -n messaging &>/dev/null; then
  log_warn "Kafka already deployed — skipping install."
else
  log_info "Installing Kafka (OCI chart from Bitnami registry)..."
  helm install kafka oci://registry-1.docker.io/bitnamicharts/kafka \
    --namespace messaging \
    --values ./messaging/kafka/values-dev.yaml \
    --wait \
    --timeout 10m
  log_success "Kafka deployed."
fi

# --- Step 6: Create Kafka topics ---
log_step "Step 6: Initializing Kafka topics"

log_info "Waiting for Kafka broker to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=kafka \
  -n messaging \
  --timeout=120s

log_info "Running Kafka topic initializer Job..."
kubectl apply -f ./messaging/kafka/topics.yaml

log_info "Waiting for topic creation job to complete..."
kubectl wait --for=condition=complete job/kafka-topic-init \
  -n messaging \
  --timeout=120s

log_success "All 13 Kafka topics created."

# --- Step 7: Deploy Kong API Gateway ---
log_step "Step 7: Deploying Kong (gateway namespace)"

# Apply the declarative config ConfigMap FIRST (Kong reads it on startup)
log_info "Applying Kong declarative config..."
kubectl apply -f ./gateway/kong/kong-config.yaml

if helm status kong -n gateway &>/dev/null; then
  log_warn "Kong already deployed — skipping install."
else
  log_info "Adding Kong Helm repo..."
  helm repo add kong https://charts.konghq.com 2>/dev/null || true
  helm repo update

  log_info "Installing Kong (DB-less mode)..."
  helm install kong kong/kong \
    --namespace gateway \
    --values ./gateway/kong/values-dev.yaml \
    --wait \
    --timeout 5m
  log_success "Kong deployed."
fi

# --- Step 8: Deploy Keycloak ---
log_step "Step 8: Deploying Keycloak (auth namespace)"

# Create the realm ConfigMap from realm-export.json
log_info "Creating Keycloak realm ConfigMap..."
kubectl create configmap keycloak-realm-config \
  --from-file=waste-management-realm.json=./auth/keycloak/realm-export.json \
  -n auth \
  --dry-run=client -o yaml | kubectl apply -f -

if helm status keycloak -n auth &>/dev/null; then
  log_warn "Keycloak already deployed — skipping install."
else
  log_info "Installing Keycloak (OCI chart from Bitnami registry)..."
  helm install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
    --namespace auth \
    --values ./auth/keycloak/values-dev.yaml \
    --wait \
    --timeout 10m
  log_success "Keycloak deployed."
fi

# --- Step 9: Deploy HashiCorp Vault ---
log_step "Step 9: Deploying HashiCorp Vault (auth namespace)"

# Add the hashicorp Helm repo (idempotent)
if ! helm repo list 2>/dev/null | grep -q "hashicorp"; then
  log_info "Adding HashiCorp Helm repo..."
  helm repo add hashicorp https://helm.releases.hashicorp.com
  helm repo update
else
  log_info "HashiCorp Helm repo already added."
fi

if helm status vault -n auth &>/dev/null; then
  log_warn "Vault already deployed — skipping install."
else
  log_info "Installing HashiCorp Vault in dev mode..."
  helm install vault hashicorp/vault \
    --namespace auth \
    --values ./auth/vault/values-dev.yaml \
    --wait \
    --timeout 5m
  log_success "Vault deployed."
fi

# Run the bootstrap Job to seed secrets and configure K8s auth
log_info "Applying Vault bootstrap Job (secrets + policies)..."
kubectl apply -f ./auth/vault/vault-policies.yaml -n auth

log_info "Waiting for vault-bootstrap Job to complete..."
kubectl wait --for=condition=complete job/vault-bootstrap -n auth --timeout=120s \
  && log_success "Vault bootstrap complete. All secrets seeded." \
  || log_warn "Bootstrap job still running. Check: kubectl logs -n auth -l job-name=vault-bootstrap"

# --- Step 10: Deploy EMQX MQTT Broker ---
log_step "Step 10: Deploying EMQX MQTT Broker (messaging namespace)"

# Add the EMQX Helm repo (idempotent)
if ! helm repo list 2>/dev/null | grep -q "emqx"; then
  log_info "Adding EMQX Helm repo..."
  helm repo add emqx https://repos.emqx.io/charts
  helm repo update
else
  log_info "EMQX Helm repo already added."
fi

if helm status emqx -n messaging &>/dev/null; then
  log_warn "EMQX already deployed — skipping install."
else
  log_info "Installing EMQX 5 single-node..."
  helm install emqx emqx/emqx \
    --namespace messaging \
    --values ./messaging/emqx/values-dev.yaml \
    --wait \
    --timeout 5m
  log_success "EMQX deployed."
fi

# Run bootstrap Job to create MQTT users + Kafka bridge rules
log_info "Applying EMQX bootstrap Job (MQTT users + Kafka bridge)..."
kubectl apply -f ./messaging/emqx/emqx-bootstrap.yaml -n messaging

log_info "Waiting for emqx-bootstrap Job to complete..."
kubectl wait --for=condition=complete job/emqx-bootstrap -n messaging --timeout=180s \
  && log_success "EMQX bootstrap complete. MQTT ↔ Kafka bridge is live." \
  || log_warn "Bootstrap job still running. Check: kubectl logs -n messaging -l job-name=emqx-bootstrap"

# --- Step 11: Deploy Argo CD + Image Updater ---
log_step "Step 11: Deploying Argo CD + Image Updater (cicd namespace)"

# Add the official Argo CD Helm repo (idempotent)
if ! helm repo list 2>/dev/null | grep -q "^argo\s"; then
  log_info "Adding Argo CD Helm repo..."
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update
else
  log_info "Argo Helm repo already added."
fi

# Install / upgrade Argo CD
if helm status argocd -n cicd &>/dev/null; then
  log_warn "Argo CD already deployed — upgrading..."
  helm upgrade argocd argo/argo-cd \
    --namespace cicd \
    --values ./cicd/argocd/values-dev.yaml \
    --wait \
    --timeout 10m
else
  log_info "Installing Argo CD..."
  helm install argocd argo/argo-cd \
    --namespace cicd \
    --values ./cicd/argocd/values-dev.yaml \
    --wait \
    --timeout 10m
  log_success "Argo CD deployed."
fi

# Install / upgrade Argo CD Image Updater
if helm status argocd-image-updater -n cicd &>/dev/null; then
  log_warn "Argo CD Image Updater already deployed — upgrading..."
  helm upgrade argocd-image-updater argo/argocd-image-updater \
    --namespace cicd \
    --values ./cicd/argocd/image-updater-values.yaml \
    --wait \
    --timeout 5m
else
  log_info "Installing Argo CD Image Updater..."
  helm install argocd-image-updater argo/argocd-image-updater \
    --namespace cicd \
    --values ./cicd/argocd/image-updater-values.yaml \
    --wait \
    --timeout 5m
  log_success "Argo CD Image Updater deployed."
fi

# Apply AppProjects and bootstrap root Application
log_info "Applying Argo CD AppProjects..."
kubectl apply -n cicd -f ./cicd/projects/

log_info "Bootstrapping App-of-Apps root Application..."
kubectl apply -n cicd -f ./cicd/bootstrap/root-app.yaml

log_info "Waiting for Argo CD server to be ready..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n cicd \
  --timeout=120s

ARGOCD_PASSWORD=$(kubectl -n cicd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "<not available yet>")

log_success "Argo CD is live at http://localhost:30800"
log_info  "  Admin user:     admin"
log_info  "  Admin password: ${ARGOCD_PASSWORD}"
log_info  "  Change password: argocd account update-password --current-password '${ARGOCD_PASSWORD}'"
log_info  ""
log_info  "NOTE: Image Updater needs a GHCR pull secret and SSH deploy key to work."
log_info  "      See cicd/README.md → 'Prerequisites for Image Updater'."

# --- Final: Cluster status ---
log_step "Final: Cluster status"

echo ""
log_info "Pods across all namespaces:"
kubectl get pods -A

echo ""
echo "================================================================"
echo "  Setup complete!"
echo ""
echo "  Access URLs (NodePort — works directly after minikube start):"
echo "  Kafka:          kafka.messaging.svc.cluster.local:9092  (internal)"
echo "  Kong Proxy:     http://localhost:30080  (NodePort)"
echo "  Keycloak:       http://localhost:30180  (NodePort)"
echo "  Vault UI:       http://localhost:30820  (NodePort)"
echo "  EMQX MQTT:      <minikube-ip>:31883  (NodePort — for ESP32/Node-RED)"
echo "  EMQX Dashboard: http://localhost:31083  (NodePort)"
echo "  Argo CD:        http://localhost:30800  (NodePort)"
echo ""
echo "  Keycloak Admin:"
echo "    URL:      http://localhost:30180/admin"
echo "    User:     admin / swms-admin-dev-2026"
echo ""
echo "  Vault:"
echo "    UI:       http://localhost:30820"
echo "    Token:    swms-vault-dev-root-token"
echo ""
echo "  EMQX MQTT Credentials (for F1 team):"
echo "    sensor-device / swms-sensor-dev-2026  (ESP32 devices)"
echo "    edge-gateway  / swms-edge-dev-2026    (Node-RED RPi gateway)"
echo "    f1-admin      / swms-f1-admin-2026    (testing)"
echo "    Dashboard:    admin / swms-emqx-dev-2026"
echo ""
echo "  Kafka Bridge Rules:"
echo "    sensors/#  → waste.bin.telemetry"
echo "    vehicles/# → waste.vehicle.location"
echo ""
echo "  Test Users (Keycloak):"
echo "    supervisor@swms-dev.local / swms-supervisor-dev"
echo "    driver@swms-dev.local     / swms-driver-dev"
echo ""
echo "  Argo CD Admin:"
echo "    URL:      http://localhost:30800"
echo "    User:     admin"
echo "    Password: (printed above by Step 11)"
echo ""
echo "  Next steps:"
echo "  1. Deploy Prometheus + Grafana (monitoring/)"
echo "  2. Create Image Updater SSH deploy key (see cicd/README.md)"
echo "  3. Create ghcr-pull-secret in cicd namespace (see cicd/README.md)"
echo "================================================================"


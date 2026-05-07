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

# --- Step 11: Deploy Hyperledger Fabric Blockchain ---
log_step "Step 11: Deploying Hyperledger Fabric (blockchain namespace)"

# RBAC + PVCs
log_info "Applying RBAC and PVCs..."
kubectl apply -f ./blockchain/network/00-rbac.yaml
kubectl apply -f ./blockchain/network/00-pvc.yaml
log_success "RBAC and PVCs created."

# Setup Job — generates crypto material + genesis block + K8s Secrets
# Only runs once; skip if Secrets already exist from a previous run.
if kubectl get secret fabric-genesis -n blockchain &>/dev/null; then
  log_warn "fabric-genesis Secret already exists — skipping fabric-setup Job."
else
  log_info "Running fabric-setup Job (cryptogen + configtxgen + Secret creation)..."
  kubectl apply -f ./blockchain/network/01-setup-job.yaml
  log_info "Waiting for fabric-setup Job to complete (up to 3 min)..."
  kubectl wait --for=condition=complete job/fabric-setup \
    -n blockchain --timeout=180s \
    && log_success "Crypto material and genesis block generated." \
    || log_warn "fabric-setup still running. Check: kubectl logs -n blockchain -l job-name=fabric-setup"
fi

# Orderer
log_info "Deploying Fabric orderer..."
kubectl apply -f ./blockchain/network/02-orderer.yaml
log_info "Waiting for orderer to be ready (up to 2 min)..."
kubectl wait --for=condition=ready pod \
  -l app=fabric-orderer \
  -n blockchain \
  --timeout=120s \
  && log_success "Orderer is ready." \
  || log_warn "Orderer not ready yet. Check: kubectl logs -n blockchain -l app=fabric-orderer"

# Peer
log_info "Deploying Fabric peer0..."
kubectl apply -f ./blockchain/network/03-peer.yaml
log_info "Waiting for peer to be ready (up to 2 min)..."
kubectl wait --for=condition=ready pod \
  -l app=fabric-peer \
  -n blockchain \
  --timeout=120s \
  && log_success "Peer0 is ready." \
  || log_warn "Peer0 not ready yet. Check: kubectl logs -n blockchain -l app=fabric-peer"

# Channel setup Job
log_info "Running channel setup Job (waste-collection-channel)..."
kubectl apply -f ./blockchain/network/04-channel-setup-job.yaml
log_info "Waiting for channel setup Job to complete (up to 3 min)..."
kubectl wait --for=condition=complete job/fabric-channel-setup \
  -n blockchain --timeout=180s \
  && log_success "Channel waste-collection-channel created." \
  || log_warn "Channel setup still running. Check: kubectl logs -n blockchain -l job-name=fabric-channel-setup"

# Chaincode server (CCaaS deployment — image must be built first)
log_info "Applying chaincode server Deployment (collection-record-cc)..."
log_warn "NOTE: Build the chaincode image first:"
log_warn "  eval \$(minikube docker-env)"
log_warn "  docker build -t collection-record-cc:1.0 ./blockchain/chaincode/"
kubectl apply -f ./blockchain/network/05-chaincode-server.yaml

# Chaincode deploy Job
log_info "Running chaincode deploy Job (install + approve + commit)..."
kubectl apply -f ./blockchain/network/06-chaincode-deploy-job.yaml
log_info "Waiting for chaincode deploy Job to complete (up to 5 min)..."
kubectl wait --for=condition=complete job/fabric-chaincode-deploy \
  -n blockchain --timeout=300s \
  && log_success "Chaincode collection-record v1.0 committed to channel." \
  || log_warn "Chaincode deploy still running. Check: kubectl logs -n blockchain -l job-name=fabric-chaincode-deploy"

# API wrapper
log_info "Applying blockchain API wrapper (Service 18)..."
log_warn "NOTE: Build the API wrapper image first:"
log_warn "  eval \$(minikube docker-env)"
log_warn "  docker build -t blockchain-api-wrapper:1.0 ./blockchain/api-wrapper/"
kubectl apply -f ./blockchain/api-wrapper/k8s/service.yaml
kubectl apply -f ./blockchain/api-wrapper/k8s/deployment.yaml
log_success "Blockchain API wrapper deployed."

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
echo "  Kafka:        kafka.messaging.svc.cluster.local:9092  (internal)"
echo "  Kong Proxy:   http://localhost:30080  (NodePort)"
echo "  Keycloak:     http://localhost:30180  (NodePort)"
echo "  Vault UI:     http://localhost:30820  (NodePort)"
echo "  EMQX MQTT:    <minikube-ip>:31883  (NodePort — for ESP32/Node-RED)"
echo "  EMQX Dashboard: http://localhost:31083  (NodePort)"
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
echo "  Blockchain (Hyperledger Fabric):"
echo "    Channel:   waste-collection-channel"
echo "    Chaincode: collection-record v1.0"
echo "    API:       http://blockchain-api-wrapper.blockchain.svc.cluster.local:8080 (K8s-internal)"
echo "    Kong:      GET /api/v1/records/:job_id  (JWT required)"
echo "    Kong:      GET /api/v1/records/zone/:id (JWT required)"
echo ""
echo "  Next steps:"
echo "  1. Deploy Prometheus + Grafana (monitoring/)"
echo "  2. Deploy Argo CD (cicd/)"
echo "================================================================"


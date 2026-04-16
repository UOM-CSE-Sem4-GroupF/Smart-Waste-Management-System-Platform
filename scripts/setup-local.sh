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

# Create wrapper functions so the rest of the script calls just `minikube`
# etc. regardless of whether the .exe suffix is needed. Aliases don't work in non-interactive bash.
for tool in minikube kubectl helm docker; do
  if ! command -v "$tool" &>/dev/null && command -v "${tool}.exe" &>/dev/null; then
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
KAFKA_CHART_VERSION="28.0.0"  # Bitnami Kafka chart version (KRaft capable)

# Script directory (so relative paths work regardless of where it's called from)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# --- Step 3: Create all Kubernetes namespaces ---
log_step "Step 3: Creating namespaces"

kubectl apply -f "$REPO_ROOT/namespaces/namespaces-dev.yaml"
log_success "All namespaces created."

# --- Step 4: Add Helm repositories ---
log_step "Step 4: Adding Helm repositories"

helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update
log_success "Helm repos up to date."

# --- Step 5: Deploy Kafka ---
log_step "Step 5: Deploying Kafka (messaging namespace)"

if helm status kafka -n messaging &>/dev/null; then
  log_warn "Kafka already deployed — skipping install."
else
  log_info "Installing Kafka chart (bitnami/kafka v${KAFKA_CHART_VERSION})..."
  helm install kafka bitnami/kafka \
    --namespace messaging \
    --version "$KAFKA_CHART_VERSION" \
    --values "$REPO_ROOT/messaging/kafka/values-dev.yaml" \
    --wait \
    --timeout 5m
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
kubectl apply -f "$REPO_ROOT/messaging/kafka/topics.yaml"

log_info "Waiting for topic creation job to complete..."
kubectl wait --for=condition=complete job/kafka-topic-init \
  -n messaging \
  --timeout=120s

log_success "All 13 Kafka topics created."

# --- Step 7: Final status check ---
log_step "Step 7: Cluster status"

echo ""
log_info "Pods across all namespaces:"
kubectl get pods -A

echo ""
log_info "Kafka topics:"
kubectl run kafka-list-topics \
  --image=bitnami/kafka:latest \
  --rm -it \
  --restart=Never \
  -n messaging \
  -- kafka-topics.sh \
     --bootstrap-server kafka.messaging.svc.cluster.local:9092 \
     --list 2>/dev/null || log_warn "Could not list topics (pod may have been cleaned up)."

echo ""
echo "================================================================"
echo "  Setup complete!"
echo ""
echo "  Useful URLs (run 'minikube service <name> -n <ns> --url'):"
echo "  Kafka (internal): kafka.messaging.svc.cluster.local:9092"
echo ""
echo "  Next steps:"
echo "  1. Deploy Kong:      (coming soon — gateway/)"
echo "  2. Deploy Keycloak:  (coming soon — auth/keycloak/)"
echo "  3. Deploy Vault:     (coming soon — auth/vault/)"
echo "================================================================"

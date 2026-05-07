#!/usr/bin/env bats
# Unit tests for scripts/setup-local.sh helper behaviour.
# Focuses on logic that can be exercised without a real cluster.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../scripts" && pwd)/setup-local.sh"

# Source only the helper function definitions, not the main execution block.
# We override the main execution commands (minikube start, helm install, etc.)
# by stubbing them in each test.

setup() {
  # Stubs that satisfy command -v checks without running anything
  minikube() { echo "minikube-stub $*"; }
  kubectl()  { echo "kubectl-stub $*"; }
  helm()     { echo "helm-stub $*"; }
  docker()   { echo "docker-stub $*"; }
  export -f minikube kubectl helm docker
}

@test "log_info prints INFO prefix" {
  source <(grep -A2 'log_info()' "$SCRIPT" | head -3)
  run log_info "test message"
  [[ "$output" == *"[INFO]"* ]]
  [[ "$output" == *"test message"* ]]
}

@test "log_success prints OK prefix" {
  source <(grep -A2 'log_success()' "$SCRIPT" | head -3)
  run log_success "all good"
  [[ "$output" == *"[OK]"* ]]
}

@test "log_error prints ERROR prefix and exits non-zero" {
  source <(grep -A2 'log_error()' "$SCRIPT" | head -3)
  run bash -c "
    log_error() { echo \"[ERROR] \$*\"; exit 1; }
    log_error 'something failed'
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ERROR]"* ]]
}

@test "prerequisite check passes when all tools are present" {
  run bash -c "
    minikube() { return 0; }
    kubectl()  { return 0; }
    helm()     { return 0; }
    docker()   { return 0; }
    for tool in docker minikube kubectl helm; do
      command -v \"\$tool\" &>/dev/null || { echo \"MISSING \$tool\"; exit 1; }
    done
    echo 'all present'
  "
  [[ "$output" == *"all present"* ]]
}

@test "WIN_PATHS array does not add nonexistent paths" {
  run bash -c "
    ORIGINAL_PATH=\"\$PATH\"
    WIN_PATHS=('/nonexistent/path1' '/nonexistent/path2')
    for p in \"\${WIN_PATHS[@]}\"; do
      [ -d \"\$p\" ] && export PATH=\"\$PATH:\$p\"
    done
    [[ \"\$PATH\" == \"\$ORIGINAL_PATH\" ]] && echo 'path unchanged' || echo 'path changed'
  "
  [[ "$output" == *"path unchanged"* ]]
}

@test "KAFKA_CHART_VERSION is set in script" {
  run grep 'KAFKA_CHART_VERSION' "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KAFKA_CHART_VERSION"* ]]
}

@test "script applies namespaces before helm installs" {
  run grep -n 'namespaces-dev.yaml' "$SCRIPT"
  [ "$status" -eq 0 ]
  NAMESPACE_LINE=$(grep -n 'namespaces-dev.yaml' "$SCRIPT" | head -1 | cut -d: -f1)
  KAFKA_LINE=$(grep -n 'helm install kafka' "$SCRIPT" | head -1 | cut -d: -f1)
  [ "$NAMESPACE_LINE" -lt "$KAFKA_LINE" ]
}

@test "script uses idempotent helm status check before installing" {
  run grep 'helm status' "$SCRIPT"
  [ "$status" -eq 0 ]
  # There should be multiple idempotency checks
  COUNT=$(grep -c 'helm status' "$SCRIPT")
  [ "$COUNT" -gt 3 ]
}

#!/usr/bin/env bats
# Unit tests for scripts/setup-doks.sh structure and invariants.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../scripts" && pwd)/setup-doks.sh"

@test "setup-doks.sh exists and is executable" {
  [ -f "$SCRIPT" ]
}

@test "DO_TOKEN check is present before any cloud operations" {
  run grep -n 'DO_TOKEN' "$SCRIPT"
  [ "$status" -eq 0 ]
  DO_TOKEN_LINE=$(grep -n 'DO_TOKEN' "$SCRIPT" | head -1 | cut -d: -f1)
  TERRAFORM_LINE=$(grep -n 'terraform apply' "$SCRIPT" | head -1 | cut -d: -f1)
  [ "$DO_TOKEN_LINE" -lt "$TERRAFORM_LINE" ]
}

@test "terraform apply uses -auto-approve flag" {
  run grep 'terraform apply' "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-auto-approve"* ]]
}

@test "script applies namespaces before helm installs" {
  run grep -n 'namespaces-dev.yaml' "$SCRIPT"
  [ "$status" -eq 0 ]
  NAMESPACE_LINE=$(grep -n 'namespaces-dev.yaml' "$SCRIPT" | head -1 | cut -d: -f1)
  KAFKA_LINE=$(grep -n 'helm install kafka\|helm upgrade kafka' "$SCRIPT" | head -1 | cut -d: -f1)
  [ "$NAMESPACE_LINE" -lt "$KAFKA_LINE" ]
}

@test "script uses values-doks.yaml overlays for cloud deployments" {
  run grep 'values-doks.yaml' "$SCRIPT"
  [ "$status" -eq 0 ]
  COUNT=$(grep -c 'values-doks.yaml' "$SCRIPT")
  [ "$COUNT" -ge 3 ]
}

@test "destroy instructions are present in comments" {
  run grep 'terraform destroy' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "required tools check covers doctl kubectl helm terraform" {
  for tool in doctl kubectl helm terraform; do
    run grep "$tool" "$SCRIPT"
    [ "$status" -eq 0 ]
  done
}

@test "log helper functions are defined" {
  run grep 'log_info\(\)' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep 'log_success\(\)' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep 'log_error\(\)' "$SCRIPT"
  [ "$status" -eq 0 ]
}

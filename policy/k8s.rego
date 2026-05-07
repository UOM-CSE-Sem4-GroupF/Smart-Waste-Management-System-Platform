# Group F — Smart Waste Management System
# OPA/Conftest Kubernetes Security Policies
# Owner: F4 Platform Team
#
# Applied to: rendered base-service Helm chart output
# Run in CI via: conftest test --policy policy/ <rendered.yaml>

package main

# ── No root containers ────────────────────────────────────────────────────────

deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.spec.securityContext.runAsNonRoot
  msg := sprintf("Deployment '%s': podSecurityContext.runAsNonRoot must be true", [input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.securityContext.runAsNonRoot != true
  msg := sprintf("Deployment '%s': container '%s' must set containerSecurityContext.runAsNonRoot=true", [input.metadata.name, container.name])
}

# ── No privilege escalation ───────────────────────────────────────────────────

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.securityContext.allowPrivilegeEscalation != false
  msg := sprintf("Deployment '%s': container '%s' must set allowPrivilegeEscalation=false", [input.metadata.name, container.name])
}

# ── Resource limits required ──────────────────────────────────────────────────

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.cpu
  msg := sprintf("Deployment '%s': container '%s' is missing resources.limits.cpu", [input.metadata.name, container.name])
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.memory
  msg := sprintf("Deployment '%s': container '%s' is missing resources.limits.memory", [input.metadata.name, container.name])
}

# ── Health probes required ────────────────────────────────────────────────────

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.livenessProbe
  msg := sprintf("Deployment '%s': container '%s' must define a livenessProbe", [input.metadata.name, container.name])
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.readinessProbe
  msg := sprintf("Deployment '%s': container '%s' must define a readinessProbe", [input.metadata.name, container.name])
}

# ── Mandatory labels (app, version) ──────────────────────────────────────────
# Required for Istio selectors, Kiali service graph, and Prometheus dashboards.

required_labels := {"app", "version"}

deny[msg] {
  input.kind == "Deployment"
  provided := {label | input.spec.template.metadata.labels[label]}
  missing := required_labels - provided
  count(missing) > 0
  msg := sprintf("Deployment '%s': pod template is missing required labels: %v", [input.metadata.name, missing])
}

deny[msg] {
  input.kind == "Deployment"
  provided := {label | input.metadata.labels[label]}
  missing := required_labels - provided
  count(missing) > 0
  msg := sprintf("Deployment '%s': metadata is missing required labels: %v", [input.metadata.name, missing])
}

# ── No :latest image tags ─────────────────────────────────────────────────────
# Argo CD Image Updater replaces :latest with a pinned digest before deploy.
# :latest in a committed values file means Image Updater hasn't run yet.

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("Deployment '%s': container '%s' must use a pinned image tag, not ':latest'", [input.metadata.name, container.name])
}

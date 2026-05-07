# PURPOSE:
#   These Rego policies are loaded into the OPA Admission Controller
#   (deployed as a Kubernetes ValidatingAdmissionWebhook) to enforce
#   cluster-wide security invariants at the API server level — before
#   any resource is persisted to etcd.
#
#   Unlike policy/k8s.rego (which runs in CI via conftest), these
#   policies run LIVE in the cluster and will hard-reject non-compliant
#   resources at admission time.
#
# Testing:
#   opa test security/opa/admission-control.rego security/opa/admission-control_test.rego -v
#
# REFERENCE: security.md — Task: OPA Admission Control

package kubernetes.admission

import future.keywords.in
import future.keywords.if

# =============================================================================
# RULE 1 — Block allowPrivilegeEscalation: true
#
# Any Pod or Deployment that sets allowPrivilegeEscalation: true on any
# container will be denied by the admission webhook. Containers MUST
# explicitly set allowPrivilegeEscalation: false to comply.
#
# Prevents: container breakout attacks, setuid binary exploitation.
# =============================================================================

deny[msg] {
  # Match Pod creation/update (Deployments create Pods via their template)
  input.request.kind.kind == "Pod"
  container := input.request.object.spec.containers[_]
  container.securityContext.allowPrivilegeEscalation == true
  msg := sprintf(
    "DENIED — Pod '%s': container '%s' has allowPrivilegeEscalation: true. Set it to false.",
    [input.request.object.metadata.name, container.name]
  )
}

deny[msg] {
  input.request.kind.kind == "Pod"
  container := input.request.object.spec.initContainers[_]
  container.securityContext.allowPrivilegeEscalation == true
  msg := sprintf(
    "DENIED — Pod '%s': initContainer '%s' has allowPrivilegeEscalation: true. Set it to false.",
    [input.request.object.metadata.name, container.name]
  )
}

deny[msg] {
  input.request.kind.kind == "Deployment"
  container := input.request.object.spec.template.spec.containers[_]
  container.securityContext.allowPrivilegeEscalation == true
  msg := sprintf(
    "DENIED — Deployment '%s': container '%s' has allowPrivilegeEscalation: true. Set it to false.",
    [input.request.object.metadata.name, container.name]
  )
}

# =============================================================================
# RULE 2 — Enforce mandatory labels: app and version
#
# All Pods and Deployments MUST have both 'app' and 'version' labels.
# These labels are required for:
#   - Istio AuthorizationPolicy selectors (matchLabels)
#   - Istio traffic routing (VirtualService/DestinationRule)
#   - Observability (Kiali service graph, Prometheus dashboards)
#   - Argo CD health tracking
# =============================================================================

required_labels := {"app", "version"}

deny[msg] {
  input.request.kind.kind == "Pod"
  provided := {label | input.request.object.metadata.labels[label]}
  missing := required_labels - provided
  count(missing) > 0
  msg := sprintf(
    "DENIED — Pod '%s' is missing required labels: %v. All Pods must have 'app' and 'version' labels.",
    [input.request.object.metadata.name, missing]
  )
}

deny[msg] {
  input.request.kind.kind == "Deployment"
  provided := {label | input.request.object.metadata.labels[label]}
  missing := required_labels - provided
  count(missing) > 0
  msg := sprintf(
    "DENIED — Deployment '%s' is missing required labels: %v. All Deployments must have 'app' and 'version' labels.",
    [input.request.object.metadata.name, missing]
  )
}

deny[msg] {
  input.request.kind.kind == "Deployment"
  provided := {label | input.request.object.spec.template.metadata.labels[label]}
  missing := required_labels - provided
  count(missing) > 0
  msg := sprintf(
    "DENIED — Deployment '%s': pod template is missing required labels: %v. Pod template must have 'app' and 'version' labels (required for Istio selectors).",
    [input.request.object.metadata.name, missing]
  )
}

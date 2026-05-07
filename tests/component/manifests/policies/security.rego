package swms.security

import future.keywords.in

# Deny any container that runs as root (runAsUser == 0 or runAsNonRoot is absent/false)
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    ctx := object.get(container, "securityContext", {})
    object.get(ctx, "runAsNonRoot", false) == false
    not object.get(ctx, "runAsUser", 0) > 0
    msg := sprintf("Container '%v' in Deployment '%v' may run as root", [container.name, input.metadata.name])
}

# Deny containers that allow privilege escalation
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    ctx := object.get(container, "securityContext", {})
    object.get(ctx, "allowPrivilegeEscalation", true) == true
    msg := sprintf("Container '%v' in Deployment '%v' allows privilege escalation", [container.name, input.metadata.name])
}

# Deny containers without a securityContext
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.securityContext
    msg := sprintf("Container '%v' in Deployment '%v' has no securityContext", [container.name, input.metadata.name])
}

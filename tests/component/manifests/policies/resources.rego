package swms.resources

import future.keywords.in

# Deny containers without resource requests
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.resources.requests
    msg := sprintf("Container '%v' in Deployment '%v' has no resource requests", [container.name, input.metadata.name])
}

# Deny containers without resource limits
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.resources.limits
    msg := sprintf("Container '%v' in Deployment '%v' has no resource limits", [container.name, input.metadata.name])
}

# Deny containers with no cpu request
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.resources.requests.cpu
    msg := sprintf("Container '%v' in Deployment '%v' has no cpu request", [container.name, input.metadata.name])
}

# Deny containers with no memory limit
deny[msg] {
    input.kind == "Deployment"
    container := input.spec.template.spec.containers[_]
    not container.resources.limits.memory
    msg := sprintf("Container '%v' in Deployment '%v' has no memory limit", [container.name, input.metadata.name])
}

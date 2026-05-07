package swms.labels

import future.keywords.in

required_labels := {"app.kubernetes.io/name", "app.kubernetes.io/instance"}

# Deny Deployments missing required labels on pod template
deny[msg] {
    input.kind == "Deployment"
    label := required_labels[_]
    not input.spec.template.metadata.labels[label]
    msg := sprintf("Deployment '%v' pod template is missing required label '%v'", [input.metadata.name, label])
}

# Deny Services missing required labels
deny[msg] {
    input.kind == "Service"
    label := required_labels[_]
    not input.metadata.labels[label]
    msg := sprintf("Service '%v' is missing required label '%v'", [input.metadata.name, label])
}

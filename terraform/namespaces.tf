# Group F — Smart Waste Management System
# Kubernetes Namespaces
# Owner: F4 Platform Team
#
# Mirrors namespaces/namespaces-dev.yaml but managed by Terraform so
# all K8s resources in helm-releases.tf can declare explicit depends_on.
#
# Namespaces:
#   gateway    — Kong API gateway
#   auth       — Keycloak, Vault
#   messaging  — Kafka, EMQX
#   monitoring — Prometheus, Grafana, ELK, Jaeger (deployed separately)
#   cicd       — Argo CD, Chaos Mesh, k6 (deployed separately)
#   blockchain — Hyperledger Fabric (deployed separately)
#   waste-dev  — All F2 + F3 application services (dev)
#   waste-prod — All F2 + F3 application services (prod)

locals {
  namespaces = {
    "gateway" = {
      environment = "dev"
      description = "Kong API gateway"
    }
    "auth" = {
      environment = "dev"
      description = "Keycloak, Vault, OPA"
    }
    "messaging" = {
      environment = "dev"
      description = "Kafka, EMQX"
    }
    "monitoring" = {
      environment = "dev"
      description = "Prometheus, Grafana, ELK, Jaeger"
    }
    "cicd" = {
      environment = "dev"
      description = "Argo CD, Chaos Mesh, k6"
    }
    "blockchain" = {
      environment = "dev"
      description = "Hyperledger Fabric peer, orderer, CA"
    }
    "waste-dev" = {
      environment = "dev"
      description = "F2 + F3 application services (development)"
    }
    "waste-prod" = {
      environment = "prod"
      description = "F2 + F3 application services (production)"
    }
  }
}

resource "kubernetes_namespace" "swms" {
  for_each = local.namespaces

  metadata {
    name = each.key
    labels = {
      project     = "group-f-swms"
      "managed-by" = "f4-platform"
      environment = each.value.environment
    }
    annotations = {
      description = each.value.description
    }
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_eks_node_group.main,
  ]
}

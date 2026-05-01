# Group F — Smart Waste Management System
# Kubernetes Namespaces (DigitalOcean)
# Owner: F4 Platform Team

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

  # Depends on the DOKS cluster being ready
  depends_on = [digitalocean_kubernetes_cluster.swms]
}

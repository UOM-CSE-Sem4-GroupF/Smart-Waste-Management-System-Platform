# Group F — Smart Waste Management System
# DigitalOcean Kubernetes Service (DOKS) Cluster
# Owner: F4 Platform Team
#
# Resources created:
#   - DOKS cluster (2×s-2vcpu-4gb worker nodes, ~$60/mo with LBs)
#
# No VPC, IAM, or S3 needed — DOKS manages its own network isolation.
# DigitalOcean block storage (do-block-storage) is the default StorageClass.

# Resolve the latest available version in the requested minor series.
data "digitalocean_kubernetes_versions" "available" {}

locals {
  matching_versions = [
    for version in data.digitalocean_kubernetes_versions.available.valid_versions : version
    if startswith(version.slug, var.k8s_version_prefix)
  ]

  selected_version = length(local.matching_versions) > 0 ? local.matching_versions[0] : data.digitalocean_kubernetes_versions.available.valid_versions[0]
}

resource "digitalocean_kubernetes_cluster" "swms" {
  name    = var.cluster_name
  region  = var.region
  version = local.selected_version

  # Auto-upgrade minor versions is disabled — keep control over K8s upgrades.
  auto_upgrade  = false
  surge_upgrade = true

  node_pool {
    name       = "swms-worker-pool"
    size       = var.node_size
    node_count = var.node_count
    auto_scale = false

    labels = {
      project = "group-f-swms"
      env     = "dev"
    }

    tags = ["swms", "dev", "f4-platform"]
  }

  tags = ["swms", "dev"]
}

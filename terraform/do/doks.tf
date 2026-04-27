# Group F — Smart Waste Management System
# DigitalOcean Kubernetes Service (DOKS) Cluster
# Owner: F4 Platform Team
#
# Resources created:
#   - DOKS cluster (2×s-2vcpu-4gb worker nodes, ~$60/mo with LBs)
#
# No VPC, IAM, or S3 needed — DOKS manages its own network isolation.
# DigitalOcean block storage (do-block-storage) is the default StorageClass.

# Resolve the latest available version on DOKS (no prefix = absolute latest).
data "digitalocean_kubernetes_versions" "available" {}

resource "digitalocean_kubernetes_cluster" "swms" {
  name    = var.cluster_name
  region  = var.region
  version = data.digitalocean_kubernetes_versions.available.valid_versions[0]

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

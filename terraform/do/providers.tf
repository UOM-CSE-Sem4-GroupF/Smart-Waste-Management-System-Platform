# Group F — Smart Waste Management System
# DigitalOcean Terraform Provider Configuration
# Owner: F4 Platform Team
#
# This is a SEPARATE Terraform root from terraform/ (AWS).
# It targets DigitalOcean Kubernetes Service (DOKS) using the
# GitHub Education Pro Pack $200 credit.
#
# Usage:
#   cd terraform/do
#   terraform init
#   terraform apply -var="do_token=<your-token>"

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# Both kubernetes and helm providers bootstrap from the freshly-created DOKS
# cluster endpoint and credentials — no kubeconfig file needed locally.
provider "kubernetes" {
  host  = digitalocean_kubernetes_cluster.swms.endpoint
  token = digitalocean_kubernetes_cluster.swms.kube_config[0].token
  cluster_ca_certificate = base64decode(
    digitalocean_kubernetes_cluster.swms.kube_config[0].cluster_ca_certificate
  )
}

provider "helm" {
  kubernetes {
    host  = digitalocean_kubernetes_cluster.swms.endpoint
    token = digitalocean_kubernetes_cluster.swms.kube_config[0].token
    cluster_ca_certificate = base64decode(
      digitalocean_kubernetes_cluster.swms.kube_config[0].cluster_ca_certificate
    )
  }
}

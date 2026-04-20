# Group F — Smart Waste Management System
# Terraform Providers
# Owner: F4 Platform Team
#
# IMPORTANT — Two-phase apply required (provider chicken-and-egg):
#   The kubernetes and helm providers need the EKS cluster endpoint to initialise,
#   but that endpoint doesn't exist until the cluster is created.
#
#   Phase 1 (AWS infra only):
#     terraform apply \
#       -target=aws_vpc.main \
#       -target=aws_eks_cluster.main \
#       -target=aws_eks_node_group.main \
#       -target=aws_eks_addon.ebs_csi_driver \
#       -target=aws_eks_addon.coredns \
#       -target=aws_s3_bucket.swms_artifacts
#     aws eks update-kubeconfig --region us-east-1 --name swms-eks-dev
#
#   Phase 2 (everything else):
#     terraform apply

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# ── AWS ──────────────────────────────────────────────────────────────────────
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "group-f-swms"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ── EKS auth data sources ─────────────────────────────────────────────────────
# These data sources resolve AFTER the cluster exists.
# Using data sources (not direct resource references) avoids the
# "provider configuration depends on resource output" cycle error at plan time.
data "aws_eks_cluster" "main" {
  name = aws_eks_cluster.main.name
}

data "aws_eks_cluster_auth" "main" {
  name = aws_eks_cluster.main.name
}

# ── Kubernetes ────────────────────────────────────────────────────────────────
provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

# ── Helm ─────────────────────────────────────────────────────────────────────
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

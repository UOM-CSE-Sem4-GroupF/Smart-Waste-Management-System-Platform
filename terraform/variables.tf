# Group F - Smart Waste Management System
# Input Variables
# Owner: F4 Platform Team

variable "cluster_name" {
  description = "EKS cluster name. Used as a prefix for all related AWS resource names."
  type        = string
  default     = "swms-eks-dev"
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-north-1"
}

variable "eks_kubernetes_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.30"
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for the Spot node group. Multiple types increase Spot availability and reduce interruption risk."
  type        = list(string)
  default     = ["t3.medium", "t3.large"]
}

variable "eks_node_desired_size" {
  description = "Desired number of EKS worker nodes. Increased to 3 to ensure coverage across all 3 Availability Zones (1a, 1b, 1c) and resolve Volume Affinity conflicts."
  type        = number
  default     = 3
}

variable "eks_node_min_size" {
  description = "Minimum EKS worker nodes. Set to 1 so the ASG replaces a reclaimed Spot node automatically."
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum EKS worker nodes."
  type        = number
  default     = 3
}

variable "environment" {
  description = "Deployment environment tag (dev / staging / prod)."
  type        = string
  default     = "dev"
}

variable "kafka_sasl_password" {
  description = "Fixed SASL password for Kafka user1. Setting this explicitly ensures the EMQX bridge and Vault secret both use the same known value (Bitnami otherwise auto-generates a random password)."
  type        = string
  default     = "swms-kafka-dev-2026"
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret for application services. Pass via TF_VAR_jwt_secret or terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "mapbox_api_key" {
  description = "Mapbox API key for frontend map tiles."
  type        = string
  sensitive   = true
  default     = "pk.placeholder.mapbox.key"
}

variable "postgres_password" {
  description = "PostgreSQL waste_admin password. Should match the value seeded in Vault at swms/postgres-waste."
  type        = string
  sensitive   = true
  default     = "waste_admin_password"
}

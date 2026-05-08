# Group F — Smart Waste Management System
# DigitalOcean Terraform Variables
# Owner: F4 Platform Team
#
# Pass do_token on the CLI — never commit it:
#   terraform apply -var="do_token=dop_v1_..."
# Or create a terraform.tfvars file (already in .gitignore):
#   do_token = "dop_v1_..."

variable "do_token" {
  type        = string
  sensitive   = true
  description = "DigitalOcean personal access token (read+write). Get from GitHub Edu Pro Pack."
}

variable "region" {
  type        = string
  default     = "sgp1"
  description = "DigitalOcean region slug. Options: sgp1 (Singapore), nyc1, fra1, blr1 (Bangalore)."
}

variable "cluster_name" {
  type        = string
  default     = "swms-doks-dev"
  description = "DOKS cluster name shown in DigitalOcean dashboard."
}

variable "k8s_version_prefix" {
  type        = string
  default     = "1.35."
  description = "Kubernetes minor version prefix. Terraform picks the latest patch in this series."
}

variable "node_count" {
  type        = number
  default     = 4
  description = "Number of worker nodes. 4×s-2vcpu-4gb = ~$96/mo. 4 nodes required to handle the full microservice stack including Airflow and Flink without scheduling conflicts."
}

variable "node_size" {
  type        = string
  default     = "s-2vcpu-4gb"
  description = "DigitalOcean Droplet size slug for worker nodes."
}

variable "kafka_sasl_password" {
  type        = string
  sensitive   = true
  default     = "swms-kafka-dev-2026"
  description = "Kafka SASL password injected consistently across all Helm releases."
}

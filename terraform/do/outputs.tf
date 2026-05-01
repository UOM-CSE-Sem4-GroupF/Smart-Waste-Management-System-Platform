# Group F — Smart Waste Management System
# DigitalOcean Terraform Outputs
# Owner: F4 Platform Team

output "cluster_name" {
  value       = digitalocean_kubernetes_cluster.swms.name
  description = "DOKS cluster name (use with doctl)."
}

output "cluster_endpoint" {
  value       = digitalocean_kubernetes_cluster.swms.endpoint
  description = "Kubernetes API server endpoint."
}

output "kubernetes_version" {
  value       = digitalocean_kubernetes_cluster.swms.version
  description = "Actual Kubernetes version provisioned."
}

output "kubeconfig_command" {
  value       = "doctl kubernetes cluster kubeconfig save ${digitalocean_kubernetes_cluster.swms.name}"
  description = "Run this after terraform apply to configure kubectl."
}

output "next_step" {
  value = <<-EOT
    =====================================================
    DOKS cluster is ready. Next steps:

    1. Configure kubectl:
       doctl kubernetes cluster kubeconfig save ${digitalocean_kubernetes_cluster.swms.name}

    2. Deploy platform services:
       bash ../../scripts/setup-doks.sh

    3. Get Kong external IP (after setup):
       kubectl get svc kong-kong-proxy -n gateway

    4. Destroy when done to stop billing:
       terraform destroy -var="do_token=<your-token>"
    =====================================================
  EOT
}

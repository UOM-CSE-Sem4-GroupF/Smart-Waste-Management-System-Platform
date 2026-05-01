# Group F — Smart Waste Management System
# Terraform Outputs
# Owner: F4 Platform Team

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint (HTTPS)"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the EKS cluster"
  value       = aws_eks_cluster.main.version
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS worker nodes)"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (NAT instance, NLBs)"
  value       = aws_subnet.public[*].id
}

output "nat_instance_public_ip" {
  description = "Elastic IP of the NAT instance — private subnet nodes use this as outbound public IP"
  value       = aws_eip.nat.public_ip
}

output "s3_bucket_name" {
  description = "S3 bucket for Airflow DAGs, MLflow artifacts, Spark checkpoints"
  value       = aws_s3_bucket.swms_artifacts.bucket
}

output "s3_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.swms_artifacts.arn
}

output "kubeconfig_command" {
  description = "Run this command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

# NLB hostnames are only available after the LoadBalancer services are provisioned
# by the cloud-provider (~2 min after apply). Use these kubectl commands to fetch them.
output "kong_proxy_hostname" {
  description = "Command to get the Kong API gateway NLB hostname (run after apply)"
  value       = "kubectl get svc -n gateway kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "emqx_mqtt_hostname" {
  description = "Command to get the EMQX MQTT NLB hostname for ESP32/Node-RED (port 1883)"
  value       = "kubectl get svc -n messaging emqx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "node_iam_role_arn" {
  description = "IAM role ARN for EKS worker nodes (used by S3 bucket policy)"
  value       = aws_iam_role.eks_nodes.arn
}

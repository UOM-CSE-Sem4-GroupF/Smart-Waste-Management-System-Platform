# Group F — Smart Waste Management System
# EKS Cluster, Node Group, IAM Roles, Add-ons
# Owner: F4 Platform Team
#
# Cost decisions:
#   - Spot instances (t3.medium / t3.large) for ~70% discount over On-Demand
#   - 2 instance types for better Spot availability and lower interruption rate
#   - EBS CSI driver add-on: REQUIRED for gp3 PVCs (Kafka, Keycloak, EMQX)
#     Without it all PVCs remain in Pending state.

# ── IAM Role: EKS Control Plane ───────────────────────────────────────────────
resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── IAM Role: EKS Node Group ──────────────────────────────────────────────────
resource "aws_iam_role" "eks_nodes" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Required by the aws-ebs-csi-driver add-on to call EC2 APIs for volume
# provisioning. In production, prefer IRSA (IAM Roles for Service Accounts)
# over attaching to the node role.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.eks_kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    # Control plane ENIs are placed across all subnets.
    # Worker nodes only use private subnets (see node group below).
    subnet_ids = concat(
      aws_subnet.public[*].id,
      aws_subnet.private[*].id
    )

    endpoint_private_access = true  # Allows worker nodes (in private subnets) to reach API server
    endpoint_public_access  = true  # Allows developer kubectl from laptop

    # Recommended: restrict public endpoint to known IPs once the team is stable
    # public_access_cidrs = ["<office-ip>/32", "<vpn-ip>/32"]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

# ── EKS Node Group (Spot) ─────────────────────────────────────────────────────
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-spot-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  # Workers in private subnets only — no direct public internet exposure
  subnet_ids = aws_subnet.private[*].id

  capacity_type  = "SPOT"
  instance_types = var.eks_node_instance_types # ["t3.medium", "t3.large"]

  scaling_config {
    desired_size = var.eks_node_desired_size # 2
    min_size     = var.eks_node_min_size     # 1
    max_size     = var.eks_node_max_size     # 3
  }

  ami_type  = "AL2_x86_64" # EKS-optimised Amazon Linux 2
  disk_size = 20            # GB — enough for all container images

  # Ensure IAM policies AND VPC endpoints are fully propagated before creating
  # the node group. Without this:
  #   - IAM: node group creation fails with an IAM error
  #   - VPC Endpoints: nodes boot before endpoint DNS propagates, causing
  #     sandbox-image.service to fail (can't pull pause container from ECR)
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
    aws_iam_role_policy_attachment.ebs_csi,
    aws_vpc_endpoint.ec2,
    aws_vpc_endpoint.sts,
    aws_vpc_endpoint.ecr_api,
    aws_vpc_endpoint.ecr_dkr,
    aws_vpc_endpoint.s3,
  ]
}

# ── EKS Add-ons ───────────────────────────────────────────────────────────────
# All add-ons depend on the node group — most require at least one node to
# schedule their DaemonSet / Deployment pods.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
  depends_on   = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
  depends_on   = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.main]
}

# The EBS CSI driver is what makes gp3 PVCs work on EKS.
# The in-tree EBS provisioner was deprecated in Kubernetes 1.23.
# Without this add-on, Kafka/Keycloak/EMQX PVCs will stay in Pending.
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"
  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

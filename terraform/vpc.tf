# Group F - Smart Waste Management System
# VPC, Subnets, Internet Gateway, NAT Instance, Route Tables
# Owner: F4 Platform Team
#
# COST DECISION: NAT Instance (t3.nano ~$4/mo) instead of NAT Gateway (~$32/mo).
# The NAT instance runs Amazon Linux 2023 with iptables masquerade enabled via
# user_data. source_dest_check MUST be false for forwarding to work.
#
# Architecture:
#   VPC 10.0.0.0/16
#   |-- Public subnets  10.0.1-3.0/24  (IGW route, ELB tag, NAT instance lives here)
#   `-- Private subnets 10.0.11-13.0/24 (NAT instance route, EKS worker nodes)

# -- VPC ----------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true # Required for EKS node registration
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

# -- Internet Gateway ----------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# -- Public Subnets ------------------------------------------------------------
# The kubernetes.io/role/elb=1 tag is required for the AWS Load Balancer
# Controller to automatically provision internet-facing NLBs (Kong, EMQX) in
# these subnets.
resource "aws_subnet" "public" {
  count = 3

  vpc_id                  = aws_vpc.main.id
  cidr_block              = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"][count.index]
  availability_zone       = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"][count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

# -- Private Subnets -----------------------------------------------------------
# Worker nodes run here. The kubernetes.io/role/internal-elb=1 tag allows the
# Load Balancer Controller to create internal-facing NLBs in these subnets if
# needed for intra-cluster services.
resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.main.id
  cidr_block        = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"][count.index]
  availability_zone = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"][count.index]

  tags = {
    Name                                        = "${var.cluster_name}-private-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# -- NAT Instance --------------------------------------------------------------
# Replaces NAT Gateway to stay under $200 AWS credit budget.
# NAT Gateway: ~$32/mo fixed + $0.045/GB data
# NAT Instance (t3.nano): ~$4/mo + no data charge within VPC

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_security_group" "nat" {
  name        = "${var.cluster_name}-nat-sg"
  description = "NAT instance - allows all traffic from VPC CIDR outbound to internet"
  vpc_id      = aws_vpc.main.id

  # Allow all traffic originating from within the VPC (private subnet nodes
  # sending outbound traffic that needs to be masqueraded)
  ingress {
    description = "All inbound from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-nat-sg" }
}

# -- NAT Gateway (Managed) -----------------------------------------------------
# Replacing the custom NAT instance with a managed NAT Gateway for reliability.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "swms-nat-gateway"
  }

  # Ensure the IGW is active first
  depends_on = [aws_internet_gateway.main]
}

resource "aws_route" "private_nat_access" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

# Elastic IP for the NAT instance.
# Persists even if the instance is replaced - private subnet nodes keep the
# same outbound public IP.
resource "aws_eip" "nat" {
  domain   = "vpc"

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

# -- Route Tables --------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

# -- Route Table Associations --------------------------------------------------
resource "aws_route_table_association" "public" {
  count = 3

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # Routes are managed via aws_route resources below to avoid dependency cycles.
  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = 3

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# -- VPC Endpoints (Cost Optimization) -----------------------------------------
# Gateway endpoints are FREE. Interface endpoints cost ~$0.01/hr per AZ.
# For this dev project, we use the NAT Gateway for ECR/EC2/STS access to save ~$65/mo.

# S3 Gateway Endpoint - REQUIRED for ECR layer pulls and FREE.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.cluster_name}-vpce-s3" }
}


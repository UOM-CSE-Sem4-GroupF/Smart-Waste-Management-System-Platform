# Group F — Smart Waste Management System
# Terraform Backend Configuration
# Owner: F4 Platform Team
#
# Active: local backend (suitable for single-developer use)
# Uncomment the S3 backend block when the team needs shared state.
#
# To migrate to S3 backend:
#   1. Create state bucket:
#        aws s3 mb s3://swms-terraform-state-$(aws sts get-caller-identity --query Account --output text) --region us-east-1
#   2. Create DynamoDB lock table:
#        aws dynamodb create-table \
#          --table-name swms-tf-lock \
#          --attribute-definitions AttributeName=LockID,AttributeType=S \
#          --key-schema AttributeName=LockID,KeyType=HASH \
#          --billing-mode PAY_PER_REQUEST \
#          --region us-east-1
#   3. Uncomment the S3 backend block below and fill in your account ID
#   4. Run: terraform init -migrate-state

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }

  # S3 backend — uncomment when team state sharing is needed
  #
  # backend "s3" {
  #   bucket         = "swms-terraform-state-<your-aws-account-id>"
  #   key            = "eks/swms-dev/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "swms-tf-lock"
  #   encrypt        = true
  # }
}

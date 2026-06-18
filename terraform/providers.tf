terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote State — uncomment for real deployments
  # ---------------------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "aeromed-terraform-state-us-east-1"
  #   key            = "production/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   kms_key_id     = "arn:aws:kms:us-east-1:ACCOUNT_ID:key/KEY_ID"
  #
  #   # DynamoDB table for state locking (prevents concurrent applies)
  #   dynamodb_table = "aeromed-terraform-locks"
  # }
}

# ---------------------------------------------------------------------------
# Primary Region — us-east-1
# ---------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}

# ---------------------------------------------------------------------------
# DR Region — eu-west-1
# Used for read replicas, cross-region backups, failover Route53 records
# ---------------------------------------------------------------------------
provider "aws" {
  alias  = "dr"
  region = var.secondary_region

  default_tags {
    tags = merge(var.common_tags, {
      Region = var.secondary_region
      Role   = "disaster-recovery"
    })
  }
}

# ---------------------------------------------------------------------------
# Kubernetes provider — wired to the EKS cluster after it is created.
# Terraform applies the EKS module first, then the provider block below
# uses the resulting endpoint and CA for subsequent kubernetes_ resources.
# ---------------------------------------------------------------------------
provider "kubernetes" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_ca_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks_cluster.cluster_name,
      "--region", var.aws_region
    ]
  }
}

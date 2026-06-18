# =============================================================================
# AeroMed DevOps Platform — Root Variables
# =============================================================================

variable "project_name" {
  description = "Short identifier used as a prefix on every AWS resource"
  type        = string
  default     = "aeromed"
}

variable "environment" {
  description = "Deployment environment (production / staging / development)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "environment must be one of: production, staging, development."
  }
}

variable "aws_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Disaster-recovery AWS region (cross-region replication target)"
  type        = string
  default     = "eu-west-1"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the primary VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to spread resources across (must be in aws_region)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Exactly 3 availability zones are required for HA."
  }
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

variable "eks_kubernetes_version" {
  description = "Kubernetes control-plane version"
  type        = string
  default     = "1.29"
}

variable "eks_node_instance_type" {
  description = "EC2 instance type for EKS managed nodes"
  type        = string
  default     = "t3.medium"
}

variable "eks_min_nodes" {
  description = "Minimum nodes in the managed node group"
  type        = number
  default     = 2
}

variable "eks_max_nodes" {
  description = "Maximum nodes in the managed node group (autoscaling ceiling)"
  type        = number
  default     = 10
}

variable "eks_desired_nodes" {
  description = "Desired (initial) node count"
  type        = number
  default     = 3

  validation {
    condition     = var.eks_desired_nodes >= var.eks_min_nodes
    error_message = "eks_desired_nodes must be >= eks_min_nodes."
  }
}

variable "eks_admin_iam_role_arns" {
  description = "List of IAM role ARNs granted system:masters access to the cluster"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# RDS
# ---------------------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "aeromed"
}

variable "db_username" {
  description = "Master DB username"
  type        = string
  default     = "aeromed_admin"
  sensitive   = true
}

variable "db_password" {
  description = "Master DB password — override via TF_VAR_db_password env var, never commit"
  type        = string
  sensitive   = true
  default     = null
}

variable "db_allocated_storage_gb" {
  description = "Initial allocated storage in GiB"
  type        = number
  default     = 100
}

variable "db_max_allocated_storage_gb" {
  description = "Upper limit for autoscaling storage in GiB"
  type        = number
  default     = 500
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

variable "common_tags" {
  description = "Tags applied to every AWS resource created by this workspace"
  type        = map(string)
  default = {
    Project          = "AeroMed"
    Environment      = "production"
    ManagedBy        = "Terraform"
    CriticalityLevel = "HIGH"
    DataClass        = "PHI"
    Owner            = "aeromed-devops-team"
  }
}

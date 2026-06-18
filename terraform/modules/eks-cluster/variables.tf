variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
}

variable "vpc_id" {
  description = "VPC in which to create the cluster"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS node groups and control-plane ENIs"
  type        = list(string)
}

variable "node_security_group_id" {
  description = "Additional security group attached to all EKS nodes"
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for managed node group"
  type        = string
}

variable "min_nodes" {
  type = number
}

variable "max_nodes" {
  type = number
}

variable "desired_nodes" {
  type = number
}

variable "admin_iam_role_arns" {
  description = "IAM role ARNs to be granted system:masters via aws-auth ConfigMap"
  type        = list(string)
  default     = []
}

variable "common_tags" {
  type = map(string)
}

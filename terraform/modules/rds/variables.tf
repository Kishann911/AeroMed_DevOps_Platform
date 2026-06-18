variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "database_subnet_ids" {
  description = "Subnet IDs for the DB subnet group (must span >= 2 AZs)"
  type        = list(string)
}

variable "db_security_group_id" {
  description = "Security group ID to attach to the RDS instance"
  type        = string
}

variable "db_instance_class" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type      = string
  sensitive = true
}

variable "db_password" {
  description = "Master password — if null, a random one is generated and stored in SSM"
  type        = string
  default     = null
  sensitive   = true
}

variable "allocated_storage_gb" {
  type = number
}

variable "max_allocated_storage_gb" {
  description = "Upper limit for autoscaling storage"
  type        = number
}

variable "common_tags" {
  type = map(string)
}

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

variable "private_subnet_ids" {
  type = list(string)
}

variable "monitoring_sg_id" {
  type = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name — used to scope CloudWatch alarms"
  type        = string
}

variable "rds_identifier" {
  description = "RDS instance identifier — used to scope CloudWatch alarms"
  type        = string
}

variable "alarm_evaluation_periods" {
  description = "Number of periods before an alarm transitions to ALARM state"
  type        = number
  default     = 2
}

variable "alarm_period_seconds" {
  description = "Period in seconds for CloudWatch alarm evaluation"
  type        = number
  default     = 60
}

variable "common_tags" {
  type = map(string)
}

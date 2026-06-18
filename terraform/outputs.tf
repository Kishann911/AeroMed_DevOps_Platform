# =============================================================================
# AeroMed DevOps Platform — Root Outputs
# =============================================================================

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the primary AeroMed VPC"
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the 3 public subnets (ALB / ingress tier)"
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the 3 private subnets (EKS node / app tier)"
  value       = module.networking.private_subnet_ids
}

output "database_subnet_ids" {
  description = "IDs of the 3 database subnets (RDS tier)"
  value       = module.networking.database_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "Elastic IPs of the 3 NAT Gateways — whitelist these in aircraft communication firewall rules"
  value       = module.networking.nat_gateway_public_ips
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

output "alb_security_group_id" {
  description = "Security group ID for the Application Load Balancer (ports 80/443 from internet)"
  value       = module.networking.alb_sg_id
}

output "app_security_group_id" {
  description = "Security group ID for app workloads (ports 5000-5006 from ALB only)"
  value       = module.networking.app_sg_id
}

output "db_security_group_id" {
  description = "Security group ID for RDS (port 5432 from app SG only)"
  value       = module.networking.db_sg_id
}

output "monitoring_security_group_id" {
  description = "Security group ID for monitoring stack (9090/3000/9093 from app SG)"
  value       = module.networking.monitoring_sg_id
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks_cluster.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks_cluster.cluster_endpoint
  sensitive   = true
}

output "eks_cluster_ca_data" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks_cluster.cluster_ca_data
  sensitive   = true
}

output "eks_node_group_arn" {
  description = "ARN of the managed node group"
  value       = module.eks_cluster.node_group_arn
}

output "eks_kubeconfig_command" {
  description = "Run this command to update your local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks_cluster.cluster_name}"
}

output "eks_oidc_provider_arn" {
  description = "ARN of the OIDC provider (used for IRSA — IAM Roles for Service Accounts)"
  value       = module.eks_cluster.oidc_provider_arn
}

# ---------------------------------------------------------------------------
# RDS
# ---------------------------------------------------------------------------

output "rds_endpoint" {
  description = "RDS writer endpoint (use this in application connection strings)"
  value       = module.rds.db_endpoint
  sensitive   = true
}

output "rds_port" {
  description = "RDS port (PostgreSQL default 5432)"
  value       = module.rds.db_port
}

output "rds_db_name" {
  description = "Database name"
  value       = module.rds.db_name
}

output "rds_kms_key_arn" {
  description = "ARN of the KMS key encrypting the RDS volume"
  value       = module.rds.kms_key_arn
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

output "cloudwatch_dashboard_url" {
  description = "URL for the AeroMed CloudWatch dashboard"
  value       = module.monitoring.dashboard_url
}

output "sns_critical_alerts_arn" {
  description = "SNS topic ARN for P1 critical alerts (subscribe your on-call endpoint)"
  value       = module.monitoring.sns_critical_arn
}

output "sns_warning_alerts_arn" {
  description = "SNS topic ARN for warning-level alerts"
  value       = module.monitoring.sns_warning_arn
}

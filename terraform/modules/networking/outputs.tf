output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (ALB tier)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (app / EKS node tier)"
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "List of database subnet IDs (RDS tier)"
  value       = aws_subnet.database[*].id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs"
  value       = aws_nat_gateway.main[*].id
}

output "nat_gateway_public_ips" {
  description = "Elastic IPs assigned to NAT Gateways — whitelist in aircraft comms firewall"
  value       = aws_eip.nat[*].public_ip
}

output "alb_sg_id" {
  description = "Security group ID for the Application Load Balancer"
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "Security group ID for AeroMed application workloads"
  value       = aws_security_group.app.id
}

output "db_sg_id" {
  description = "Security group ID for RDS database"
  value       = aws_security_group.db.id
}

output "monitoring_sg_id" {
  description = "Security group ID for the monitoring stack"
  value       = aws_security_group.monitoring.id
}

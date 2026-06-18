output "db_identifier" {
  description = "RDS instance identifier"
  value       = aws_db_instance.main.identifier
}

output "db_endpoint" {
  description = "Connection endpoint (host:port) for the RDS instance"
  value       = aws_db_instance.main.endpoint
  sensitive   = true
}

output "db_address" {
  description = "Hostname of the RDS instance (without port)"
  value       = aws_db_instance.main.address
  sensitive   = true
}

output "db_port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Database name"
  value       = aws_db_instance.main.db_name
}

output "db_arn" {
  description = "ARN of the RDS instance"
  value       = aws_db_instance.main.arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting the RDS storage"
  value       = aws_kms_key.rds.arn
}

output "kms_key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.rds.key_id
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group"
  value       = aws_db_subnet_group.main.name
}

output "parameter_group_name" {
  description = "Name of the DB parameter group"
  value       = aws_db_parameter_group.main.name
}

output "ssm_password_path" {
  description = "SSM Parameter Store path containing the master password"
  value       = aws_ssm_parameter.db_password.name
  sensitive   = true
}

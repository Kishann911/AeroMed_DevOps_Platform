output "sns_critical_arn" {
  description = "SNS topic ARN for P1 critical alerts"
  value       = aws_sns_topic.critical.arn
}

output "sns_warning_arn" {
  description = "SNS topic ARN for warning-level alerts"
  value       = aws_sns_topic.warning.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.aeromed.dashboard_name
}

output "dashboard_url" {
  description = "Direct URL to the CloudWatch operations dashboard"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.aeromed.dashboard_name}"
}

output "log_group_names" {
  description = "Map of service name to CloudWatch log group name"
  value       = { for k, v in aws_cloudwatch_log_group.service : k => v.name }
}

output "logs_kms_key_arn" {
  description = "ARN of the KMS key encrypting CloudWatch log groups"
  value       = aws_kms_key.logs.arn
}

output "alarm_arns" {
  description = "Map of alarm name to ARN"
  value = {
    eks_node_cpu      = aws_cloudwatch_metric_alarm.eks_node_cpu.arn
    eks_node_memory   = aws_cloudwatch_metric_alarm.eks_node_memory.arn
    rds_cpu           = aws_cloudwatch_metric_alarm.rds_cpu.arn
    rds_connections   = aws_cloudwatch_metric_alarm.rds_connections.arn
    rds_storage_low   = aws_cloudwatch_metric_alarm.rds_storage_low.arn
    rds_replica_lag   = aws_cloudwatch_metric_alarm.rds_replica_lag.arn
  }
}

# =============================================================================
# AeroMed Monitoring Module
# CloudWatch Log Groups · Dashboards · Alarms · SNS Topics
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  aeromed_services = [
    "api-gateway",
    "flight-operations",
    "patient-records",
    "medical-equipment",
    "emergency-dispatch",
    "aircraft-comms",
  ]
}

# ---------------------------------------------------------------------------
# SNS Topics — alert routing for critical and warning severities
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "critical" {
  name              = "${local.name_prefix}-alerts-critical"
  kms_master_key_id = "alias/aws/sns"

  tags = merge(var.common_tags, {
    Name     = "${local.name_prefix}-alerts-critical"
    Severity = "critical"
  })
}

resource "aws_sns_topic" "warning" {
  name              = "${local.name_prefix}-alerts-warning"
  kms_master_key_id = "alias/aws/sns"

  tags = merge(var.common_tags, {
    Name     = "${local.name_prefix}-alerts-warning"
    Severity = "warning"
  })
}

# Placeholder subscription — replace with real on-call endpoint (PagerDuty / Opsgenie / email)
resource "aws_sns_topic_subscription" "critical_email_placeholder" {
  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = "aeromed-oncall@example.com" # Replace with real on-call address
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups — one per AeroMed service + EKS control-plane logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "service" {
  for_each = toset(local.aeromed_services)

  name              = "/aeromed/${var.environment}/${each.key}"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.logs.arn

  tags = merge(var.common_tags, {
    Name    = "/aeromed/${var.environment}/${each.key}"
    Service = each.key
  })
}

resource "aws_cloudwatch_log_group" "eks_api" {
  name              = "/aws/eks/${var.eks_cluster_name}/cluster"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.logs.arn

  tags = merge(var.common_tags, {
    Name = "/aws/eks/${var.eks_cluster_name}/cluster"
  })
}

# ---------------------------------------------------------------------------
# KMS Key — encrypts CloudWatch Log Groups
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "logs" {
  description             = "AeroMed CloudWatch Logs encryption key"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch Logs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${local.name_prefix}-logs-kms"
    Purpose = "cloudwatch-logs-encryption"
  })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name_prefix}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms — EKS Node Group
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "eks_node_cpu" {
  alarm_name          = "${local.name_prefix}-eks-node-cpu-high"
  alarm_description   = "EKS node CPU utilization above 80% — risk of service degradation"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "eks_node_memory" {
  alarm_name          = "${local.name_prefix}-eks-node-memory-high"
  alarm_description   = "EKS node memory utilization above 85%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "node_memory_utilization"
  namespace           = "ContainerInsights"
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]

  tags = var.common_tags
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms — RDS
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS CPU utilization above 75% — investigate slow queries"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = 75
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${local.name_prefix}-rds-connections-high"
  alarm_description   = "RDS connections approaching max_connections limit of 200"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = 160 # 80% of max_connections=200
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${local.name_prefix}-rds-storage-low"
  alarm_description   = "RDS free storage below 20 GiB — autoscaling may have been exhausted"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 21474836480 # 20 GiB in bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_replica_lag" {
  alarm_name          = "${local.name_prefix}-rds-replica-lag"
  alarm_description   = "RDS replica lag > 60 seconds — potential data staleness in DR region"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = 60
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  ok_actions    = [aws_sns_topic.warning.arn]

  tags = var.common_tags
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard — AeroMed Operations
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "aeromed" {
  dashboard_name = "${local.name_prefix}-operations"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# AeroMed Platform — Operations Dashboard\nEnvironment: **${var.environment}** | Region: **${var.aws_region}** | Cluster: **${var.eks_cluster_name}**"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "EKS Node CPU Utilization (%)"
          view   = "timeSeries"
          period = 60
          stat   = "Average"
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.eks_cluster_name]
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "EKS Node Memory Utilization (%)"
          view   = "timeSeries"
          period = 60
          stat   = "Average"
          metrics = [
            ["ContainerInsights", "node_memory_utilization", "ClusterName", var.eks_cluster_name]
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "RDS CPU Utilization (%)"
          view   = "timeSeries"
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_identifier]
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "RDS Database Connections"
          view   = "timeSeries"
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_identifier]
          ]
          annotations = {
            horizontal = [{ value = 160, label = "80% of max_connections", color = "#ff6961" }]
          }
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 14
        width  = 24
        height = 4
        properties = {
          title = "Active Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.eks_node_cpu.arn,
            aws_cloudwatch_metric_alarm.eks_node_memory.arn,
            aws_cloudwatch_metric_alarm.rds_cpu.arn,
            aws_cloudwatch_metric_alarm.rds_connections.arn,
            aws_cloudwatch_metric_alarm.rds_storage_low.arn,
          ]
        }
      }
    ]
  })
}

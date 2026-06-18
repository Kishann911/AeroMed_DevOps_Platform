# =============================================================================
# AeroMed RDS Module
# PostgreSQL 15.4 · Multi-AZ · Encrypted · Automated Backups · Deletion Protection
# =============================================================================

locals {
  identifier = "${var.project_name}-${var.environment}-postgres"
}

# ---------------------------------------------------------------------------
# KMS Key — encrypts the RDS storage volume and automated snapshots
# ---------------------------------------------------------------------------

resource "aws_kms_key" "rds" {
  description             = "AeroMed RDS encryption key — ${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true # Allows decryption in DR region

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
        Sid    = "Allow RDS to use the key"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${local.identifier}-kms"
    Purpose = "rds-encryption"
  })
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${local.identifier}"
  target_key_id = aws_kms_key.rds.key_id
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Auto-generate DB password if none supplied
# ---------------------------------------------------------------------------

resource "random_password" "db" {
  count   = var.db_password == null ? 1 : 0
  length  = 32
  special = true
  # RDS disallows / @ " and space in the master password
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

locals {
  db_password = var.db_password != null ? var.db_password : random_password.db[0].result
}

# Store the generated password in SSM Parameter Store so apps can retrieve it
resource "aws_ssm_parameter" "db_password" {
  name        = "/${var.project_name}/${var.environment}/rds/master_password"
  description = "AeroMed RDS master password — ${var.environment}"
  type        = "SecureString"
  value       = local.db_password
  key_id      = aws_kms_key.rds.arn

  tags = var.common_tags
}

# ---------------------------------------------------------------------------
# DB Subnet Group
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name        = "${local.identifier}-subnet-group"
  description = "AeroMed RDS subnet group — database tier subnets"
  subnet_ids  = var.database_subnet_ids

  tags = merge(var.common_tags, {
    Name = "${local.identifier}-subnet-group"
  })
}

# ---------------------------------------------------------------------------
# DB Parameter Group — PostgreSQL 15 tuning
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "main" {
  name        = "${local.identifier}-params"
  family      = "postgres15"
  description = "AeroMed PostgreSQL 15 parameter group"

  parameter {
    name         = "log_min_duration_statement"
    value        = "1000" # Log queries taking > 1 second
    apply_method = "immediate"
  }

  parameter {
    name         = "max_connections"
    value        = "200"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_lock_waits"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_temp_files"
    value        = "0" # Log all temp files (useful for query tuning)
    apply_method = "immediate"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  tags = merge(var.common_tags, {
    Name = "${local.identifier}-params"
  })
}

# ---------------------------------------------------------------------------
# RDS Instance — PostgreSQL 15.4 Multi-AZ
# ---------------------------------------------------------------------------

resource "aws_db_instance" "main" {
  identifier = local.identifier

  # Engine
  engine               = "postgres"
  engine_version       = "15.4"
  instance_class       = var.db_instance_class
  db_name              = var.db_name
  username             = var.db_username
  password             = local.db_password
  parameter_group_name = aws_db_parameter_group.main.name

  # Storage
  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_security_group_id]
  publicly_accessible    = false
  port                   = 5432

  # High Availability
  multi_az = true

  # Backups
  backup_retention_period   = 7
  backup_window             = "02:00-03:00"
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false

  # Maintenance
  maintenance_window         = "Mon:04:00-Mon:05:00"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  # Protection
  deletion_protection = true
  skip_final_snapshot = false
  final_snapshot_identifier = "${local.identifier}-final-${formatdate("YYYY-MM-DD", timestamp())}"

  # Performance Insights
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.rds.arn
  performance_insights_retention_period = 7

  # Enhanced Monitoring (60-second granularity)
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # CA certificate
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  tags = merge(var.common_tags, {
    Name = local.identifier
  })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [password, final_snapshot_identifier]
  }

  depends_on = [aws_db_subnet_group.main, aws_db_parameter_group.main]
}

# ---------------------------------------------------------------------------
# IAM Role — RDS Enhanced Monitoring
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${local.identifier}-monitoring-role"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

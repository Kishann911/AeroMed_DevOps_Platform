# =============================================================================
# AeroMed DevOps Platform — Root Module
# Orchestrates: networking → eks → rds → monitoring
# =============================================================================

# ---------------------------------------------------------------------------
# Networking — VPC, subnets, IGW, NAT GWs, security groups
# ---------------------------------------------------------------------------
module "networking" {
  source = "./modules/networking"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  common_tags        = var.common_tags
}

# ---------------------------------------------------------------------------
# EKS Cluster — control plane, managed node group, IAM, add-ons, aws-auth
# ---------------------------------------------------------------------------
module "eks_cluster" {
  source = "./modules/eks-cluster"

  project_name            = var.project_name
  environment             = var.environment
  aws_region              = var.aws_region
  kubernetes_version      = var.eks_kubernetes_version
  vpc_id                  = module.networking.vpc_id
  private_subnet_ids      = module.networking.private_subnet_ids
  node_security_group_id  = module.networking.app_sg_id
  node_instance_type      = var.eks_node_instance_type
  min_nodes               = var.eks_min_nodes
  max_nodes               = var.eks_max_nodes
  desired_nodes           = var.eks_desired_nodes
  admin_iam_role_arns     = var.eks_admin_iam_role_arns
  common_tags             = var.common_tags

  depends_on = [module.networking]
}

# ---------------------------------------------------------------------------
# RDS PostgreSQL — Multi-AZ, encrypted, automated backups
# ---------------------------------------------------------------------------
module "rds" {
  source = "./modules/rds"

  project_name              = var.project_name
  environment               = var.environment
  aws_region                = var.aws_region
  vpc_id                    = module.networking.vpc_id
  database_subnet_ids       = module.networking.database_subnet_ids
  db_security_group_id      = module.networking.db_sg_id
  db_instance_class         = var.db_instance_class
  db_name                   = var.db_name
  db_username               = var.db_username
  db_password               = var.db_password
  allocated_storage_gb      = var.db_allocated_storage_gb
  max_allocated_storage_gb  = var.db_max_allocated_storage_gb
  common_tags               = var.common_tags

  depends_on = [module.networking]
}

# ---------------------------------------------------------------------------
# Monitoring — CloudWatch dashboards, alarms, SNS, log groups
# ---------------------------------------------------------------------------
module "monitoring" {
  source = "./modules/monitoring"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  monitoring_sg_id   = module.networking.monitoring_sg_id
  eks_cluster_name   = module.eks_cluster.cluster_name
  rds_identifier     = module.rds.db_identifier
  common_tags        = var.common_tags

  depends_on = [module.eks_cluster, module.rds]
}

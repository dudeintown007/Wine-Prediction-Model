# ─────────────────────────────────────────────────────────────────────────────
# Terraform: EKS Cluster + RDS PostgreSQL for MLflow (Production)
# Region: ap-south-1 (Mumbai)
#
# Database:  mlflow_abhi   (RDS default database)
# DB User:   mlflow_abhi   (RDS master user — MLflow connects as this user)
# ─────────────────────────────────────────────────────────────────────────────
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in S3 (same bucket you already have)
  backend "s3" {
    bucket = "dvc-abhi-test"
    key    = "mlops/infra/terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Data ──────────────────────────────────────────────────────────────────────
data "aws_availability_zones" "available" {}

data "aws_caller_identity" "current" {}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true          # cost saving; use false for full HA
  enable_dns_hostnames = true

  # Required tags for EKS to discover subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.common_tags
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project}-cluster"
  cluster_version = "1.29"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true  # access kubectl from your laptop

  # Automatically grants cluster-admin to whoever runs terraform apply.
  # Without this, EKS v20+ does NOT give the creator any kubectl access.
  enable_cluster_creator_admin_permissions = true

  # Node group
  eks_managed_node_groups = {
    mlops = {
      instance_types = [var.node_instance_type]
      min_size       = 1
      max_size       = 3
      desired_size   = 2

      labels = {
        workload = "mlops"
      }
    }
  }

  tags = local.common_tags
}

# ── Security group: EKS nodes → RDS on port 5432 ─────────────────────────────
resource "aws_security_group" "rds_sg" {
  name        = "${var.project}-rds-sg"
  description = "Allow PostgreSQL from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# ── RDS Subnet Group (uses private subnets) ───────────────────────────────────
resource "aws_db_subnet_group" "mlflow" {
  name       = "${var.project}-rds-subnet-group"
  subnet_ids = module.vpc.private_subnets
  tags       = local.common_tags
}

# ── RDS PostgreSQL ────────────────────────────────────────────────────────────
resource "aws_db_instance" "mlflow" {
  identifier            = "${var.project}-mlflow-db"
  engine                = "postgres"
  engine_version        = "15"
  instance_class        = var.db_instance_class
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  # Database and user are both named mlflow_abhi.
  # MLflow connects with these credentials — no secondary user provisioning needed.
  db_name  = "mlflow_abhi"
  username = "mlflow_abhi"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.mlflow.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  multi_az            = false        # set true for production HA
  publicly_accessible = false        # only reachable from inside VPC
  skip_final_snapshot = true

  backup_retention_period = 7
  deletion_protection     = false    # set true in real production

  tags = local.common_tags
}

# ── Secrets Manager: DB credentials ──────────────────────────────────────────
# Stores RDS connection details written after the DB is created.
resource "aws_secretsmanager_secret" "mlflow_db" {
  name                    = "${var.project}/mlflow/db-credentials"
  recovery_window_in_days = 0   # allow immediate deletion on teardown
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "mlflow_db" {
  secret_id = aws_secretsmanager_secret.mlflow_db.id
  secret_string = jsonencode({
    username     = aws_db_instance.mlflow.username           # mlflow_abhi
    password     = var.db_password
    host         = aws_db_instance.mlflow.address
    port         = aws_db_instance.mlflow.port
    dbname       = aws_db_instance.mlflow.db_name            # mlflow_abhi
    postgres_url = "postgresql://mlflow_abhi:${var.db_password}@${aws_db_instance.mlflow.address}:5432/mlflow_abhi"
  })
}

# ── Secrets Manager: master all-credentials secret ───────────────────────────
# Secret name: "mysecret"
# Created and managed entirely by: bash helm/secrets-bootstrap.sh
# Read at deploy time by:          bash helm/load-secrets.sh
#
# NOT managed by Terraform on purpose — so plaintext credentials never touch
# terraform state or plan output. Terraform only manages the DB-credentials
# secret above (which contains no sensitive values beyond what RDS already knows).

locals {
  common_tags = {
    Project     = var.project
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

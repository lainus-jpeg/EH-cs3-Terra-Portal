# ── Security Group for RDS ────────────────────────────────────────────────────
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"  # excludes chars that break connection strings
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.environment}-rds-sg"
  description = "Allow PostgreSQL access from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS cluster"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_cluster_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-${var.environment}-rds-sg" }
}

# ── RDS Parameter Group ───────────────────────────────────────────────────────
resource "aws_db_parameter_group" "postgres" {
  name   = "${var.project}-${var.environment}-postgres15"
  family = "postgres15"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = { Name = "${var.project}-${var.environment}-pg-params" }
}

# ── RDS Instance ──────────────────────────────────────────────────────────────
resource "aws_db_instance" "postgres" {
  identifier = "${var.project}-${var.environment}-postgres"

  engine         = "postgres"
  engine_version = "15"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100  # autoscaling storage up to 100GB
  storage_type          = "gp3"
  storage_encrypted     = true  # encryption at rest (Zero Trust)

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result  # auto-generated, stored in Secrets Manager

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name

  # Multi-AZ for automatic failover — required for Phase 4 testing
  multi_az = var.multi_az

  # Backups
  backup_retention_period = 1
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Don't delete DB when terraform destroy is run in production
  # Set to true for dev to allow easy teardown
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = "${var.project}-${var.environment}-final-snapshot"

  deletion_protection = false  # set true in production

  tags = { Name = "${var.project}-${var.environment}-postgres" }
}

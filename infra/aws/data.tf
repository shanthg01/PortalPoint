# ---- RDS ----

resource "aws_db_subnet_group" "main" {
  name        = "portalpoint-subnet-group"
  description = "PortalPoint RDS"
  subnet_ids  = var.db_subnet_ids
}

resource "aws_db_parameter_group" "pg15" {
  name        = "portalpoint-pg15"
  description = "PortalPoint Postgres 15"
  family      = "postgres15"
}

resource "aws_db_instance" "portalpoint" {
  identifier     = "portalpoint-db"
  engine         = "postgres"
  engine_version = "15.17"
  # Downsized 2026-07-24 from db.r6g.large + Multi-AZ (see road_to_production.md).
  instance_class = "db.m6g.large"
  multi_az       = false

  db_name  = "portalpoint"
  username = "portalpoint_master"
  # Password is not in code. On a rebuild (no snapshot), set one out-of-band:
  #   aws rds modify-db-instance --db-instance-identifier portalpoint-db --master-user-password ...
  # (restoring from rds_restore_snapshot_identifier keeps the snapshot's password).
  snapshot_identifier = var.rds_restore_snapshot_identifier

  allocated_storage = 50
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.pg15.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  # True as originally created, but the SG only admits the ECS task + bastion
  # SGs, so it isn't reachable from the internet.
  publicly_accessible = true

  backup_retention_period    = 7
  backup_window              = "07:26-07:56"
  maintenance_window         = "wed:06:50-wed:07:20"
  auto_minor_version_upgrade = true
  database_insights_mode     = "standard"

  # Live value is false; the real guard on destroy is the final snapshot below.
  deletion_protection = false
  # `terraform destroy` takes a final snapshot. These three are Terraform-only
  # settings (no AWS API call) but must be applied to STATE before destroy --
  # destroy reads them from state, not config.
  skip_final_snapshot       = false
  final_snapshot_identifier = var.rds_final_snapshot_identifier
  delete_automated_backups  = true

  tags = {
    Project = "portalpoint"
  }
}

# ---- ElastiCache (cache only -- safe to delete/recreate, holds no durable data) ----

resource "aws_elasticache_subnet_group" "main" {
  name        = "portalpoint-cache-subnets"
  description = "PortalPoint ElastiCache"
  subnet_ids  = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

resource "aws_elasticache_cluster" "main" {
  cluster_id           = "portalpoint-cache"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  availability_zone    = "us-east-1a"
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.cache.id]
  maintenance_window   = "sun:03:30-sun:04:30"
  snapshot_window      = "05:00-06:00"
}

# ---- EFS: persistent MLflow tracking store (sqlite) for scripts/run_in_ecs.sh ----

resource "aws_efs_file_system" "mlflow" {
  creation_token   = "portalpoint-mlflow"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name = "portalpoint-mlflow"
  }
}

# Root /mlflow owned by uid/gid 1000 -- matches the Dockerfile's non-root `appuser`.
resource "aws_efs_access_point" "mlflow" {
  file_system_id = aws_efs_file_system.mlflow.id

  posix_user {
    uid = 1000
    gid = 1000
  }
  root_directory {
    path = "/mlflow"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "755"
    }
  }

  tags = {
    Name = "portalpoint-mlflow-ap"
  }
}

resource "aws_efs_mount_target" "private_a" {
  file_system_id  = aws_efs_file_system.mlflow.id
  subnet_id       = aws_subnet.private_a.id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_mount_target" "private_b" {
  file_system_id  = aws_efs_file_system.mlflow.id
  subnet_id       = aws_subnet.private_b.id
  security_groups = [aws_security_group.efs.id]
}

# Private subnets + NAT for ECS tasks / ElastiCache / EFS, carved out of the
# default VPC (see variables.tf for why the VPC itself isn't managed).

resource "aws_subnet" "private_a" {
  vpc_id                  = var.vpc_id
  availability_zone       = "us-east-1a"
  cidr_block              = "172.31.128.0/20"
  map_public_ip_on_launch = false
}

resource "aws_subnet" "private_b" {
  vpc_id                  = var.vpc_id
  availability_zone       = "us-east-1b"
  cidr_block              = "172.31.144.0/20"
  map_public_ip_on_launch = false
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id     = aws_eip.nat.id
  subnet_id         = var.public_subnet_ids[0]
  connectivity_type = "public"
}

resource "aws_route_table" "private" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  # The S3 gateway endpoint adds its own prefix-list route; the provider
  # ignores endpoint-managed routes here.
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# Free: keeps S3 traffic from private subnets off the NAT bill.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

# ---- security groups ----

resource "aws_security_group" "alb" {
  name        = "portalpoint-alb-sg"
  description = "PortalPoint ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_task" {
  name        = "portalpoint-ecs-task-sg"
  description = "PortalPoint ECS Fargate tasks"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SSH (22) was closed 2026-07-20 -- access is SSM port-forwarding only, so no ingress.
resource "aws_security_group" "bastion" {
  name        = "portalpoint-bastion-sg"
  description = "PortalPoint bastion SSH"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "portalpoint-rds-sg"
  description = "PortalPoint RDS access"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_task.id, aws_security_group.bastion.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Bastion is allowed too, for debugging via the SSM tunnel (same as RDS).
resource "aws_security_group" "cache" {
  name        = "portalpoint-cache-sg"
  description = "PortalPoint ElastiCache Redis"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_task.id, aws_security_group.bastion.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "efs" {
  name        = "portalpoint-efs-sg"
  description = "PortalPoint EFS mount targets (MLflow tracking store)"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_task.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

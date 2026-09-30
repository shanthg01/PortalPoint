# ---- ECR ----

resource "aws_ecr_repository" "backend" {
  name                 = "portalpoint-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # destroy deletes the repo even with images in it

  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
}

# ---- ECS ----

resource "aws_ecs_cluster" "prod" {
  name = "portalpoint-prod"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

# The API service's task definition. deploy.yml registers new revisions at
# deploy time (image tag, DB-master-url swap for the migration family), so only
# this baseline revision lives in code; the -migrate and -modeling families are
# derived from it at runtime by deploy.yml / scripts/run_in_ecs.sh.
resource "aws_ecs_task_definition" "backend" {
  family                   = "portalpoint-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "backend"
    image     = "${aws_ecr_repository.backend.repository_url}:latest"
    essential = true
    portMappings = [{
      containerPort = 8000
      hostPort      = 8000
      protocol      = "tcp"
    }]
    environment = [
      { name = "AWS_DEFAULT_REGION", value = var.region },
      { name = "REDIS_URL", value = "redis://${aws_elasticache_cluster.main.cache_nodes[0].address}:6379" },
      { name = "S3_BUCKET", value = var.data_bucket },
    ]
    secrets = [
      { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.database_url.arn },
      { name = "GOOGLE_API_KEY", valueFrom = aws_secretsmanager_secret.google_api_key.arn },
      { name = "JWT_SECRET", valueFrom = aws_secretsmanager_secret.jwt_secret.arn },
      { name = "TAVILY_API_KEY", valueFrom = aws_secretsmanager_secret.tavily_api_key.arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-create-group  = "true"
        awslogs-group         = aws_cloudwatch_log_group.backend.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "backend"
      }
    }
    mountPoints    = []
    systemControls = []
    volumesFrom    = []
  }])
}

resource "aws_ecs_service" "backend" {
  name            = "portalpoint-backend"
  cluster         = aws_ecs_cluster.prod.id
  task_definition = "${aws_ecs_task_definition.backend.family}:${aws_ecs_task_definition.backend.revision}"
  desired_count   = 1
  launch_type     = "FARGATE"

  availability_zone_rebalancing = "ENABLED"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_groups  = [aws_security_group.ecs_task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 8000
  }

  lifecycle {
    # deploy.yml rolls new task-def revisions; don't fight it.
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http]
}

# ---- ALB (health-checked on the DB-aware /ready, not /health) ----

resource "aws_lb" "main" {
  name               = "portalpoint-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = slice(var.public_subnet_ids, 0, 2)
}

resource "aws_lb_target_group" "backend" {
  name                 = "portalpoint-tg"
  port                 = 8000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = "300"

  health_check {
    path                = "/ready"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  lifecycle {
    # AWS echoes a single-target forward back as an expanded `forward {}` block;
    # ignore the representational diff rather than re-writing the listener.
    ignore_changes = [default_action]
  }
}

# ---- Bastion: SSM port-forward target for RDS/ElastiCache (no SSH) ----

resource "aws_instance" "bastion" {
  ami                         = var.bastion_ami
  instance_type               = "t2.micro"
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true
  # Legacy key pair from the SSH era (not managed here; delete by hand on teardown).
  # Leave null on a rebuild -- SSM doesn't need one.
  key_name = "portalpoint-bastion"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 2
  }

  tags = {
    Name = "portalpoint-bastion"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

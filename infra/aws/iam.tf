# ---- GitHub Actions OIDC deploy role (used by .github/workflows/deploy.yml) ----

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "gha_deploy" {
  name = "portalpoint-gha-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main" }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gha_ecr" {
  role       = aws_iam_role.gha_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "gha_ecs" {
  role       = aws_iam_role.gha_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

resource "aws_iam_role_policy" "gha_frontend_deploy" {
  name = "portalpoint-frontend-deploy"
  role = aws_iam_role.gha_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PortalPointFrontendS3Sync"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.frontend.arn
      },
      {
        Sid      = "PortalPointFrontendS3Objects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.frontend.arn}/*"
      },
      {
        Sid      = "PortalPointCloudFrontInvalidate"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = aws_cloudfront_distribution.main.arn
      },
    ]
  })
}

# ---- ECS roles ----

locals {
  ecs_tasks_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# Execution role: pull image, read secrets, write logs.
resource "aws_iam_role" "ecs_execution" {
  name               = "portalpoint-ecs-execution"
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The managed policy lacks logs:CreateLogGroup, which awslogs-create-group needs.
resource "aws_iam_role_policy" "ecs_execution_logs" {
  name = "portalpoint-logs-write"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/ecs/portalpoint-backend:*"
    }]
  })
}

# Wildcard suffixes: ECS requests secrets by full ARN (incl. the random suffix).
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "portalpoint-secrets-read"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        for s in ["database-url", "jwt-secret", "database-master-url", "tavily-api-key", "google-api-key"] :
        "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:portalpoint/${s}-*"
      ]
    }]
  })
}

# Task role: the running app's own AWS permissions (no static keys).
resource "aws_iam_role" "ecs_task" {
  name               = "portalpoint-ecs-task"
  assume_role_policy = local.ecs_tasks_trust
}

# Cross-account: the bucket-owner account's bucket policy must ALSO allow this role.
resource "aws_iam_role_policy" "ecs_task_s3" {
  name = "portalpoint-s3-access"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${var.data_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.data_bucket}/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_efs" {
  name = "portalpoint-efs-mlflow-access"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
      Resource = aws_efs_file_system.mlflow.arn
      Condition = {
        StringEquals = { "elasticfilesystem:AccessPointArn" = aws_efs_access_point.mlflow.arn }
      }
    }]
  })
}

# ---- Bastion instance role (SSM agent registration) ----

resource "aws_iam_role" "bastion" {
  name = "portalpoint-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "portalpoint-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ---- Teammate group: SSM port-forward to the bastion only (users in iam_users.tf) ----

resource "aws_iam_group" "dev" {
  name = "PortalPoint-Dev"
}

resource "aws_iam_group_policy" "dev_ssm" {
  name  = "PortalPointSSMBastionAccess"
  group = aws_iam_group.dev.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = [
          aws_instance.bastion.arn,
          "arn:aws:ssm:${var.region}::document/AWS-StartPortForwardingSessionToRemoteHost",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:TerminateSession", "ssm:ResumeSession"]
        Resource = "arn:aws:ssm:${var.region}:*:session/$${aws:username}-*"
      },
    ]
  })
}

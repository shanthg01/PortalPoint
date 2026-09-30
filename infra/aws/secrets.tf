# Secret CONTAINERS only. Values are never in code -- set them out-of-band:
#   aws secretsmanager put-secret-value --secret-id portalpoint/<name> --secret-string '...'
# database-url / database-master-url embed the RDS hostname, so they must be
# re-set after any rebuild (new endpoint). database-master-url is used only by
# deploy.yml's one-off migration task.

locals {
  secret_recovery_days = 7
}

resource "aws_secretsmanager_secret" "database_url" {
  name                    = "portalpoint/database-url"
  recovery_window_in_days = local.secret_recovery_days
}

resource "aws_secretsmanager_secret" "database_master_url" {
  name                    = "portalpoint/database-master-url"
  recovery_window_in_days = local.secret_recovery_days
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "portalpoint/jwt-secret"
  recovery_window_in_days = local.secret_recovery_days
}

resource "aws_secretsmanager_secret" "tavily_api_key" {
  name                    = "portalpoint/tavily-api-key"
  recovery_window_in_days = local.secret_recovery_days
}

resource "aws_secretsmanager_secret" "google_api_key" {
  name                    = "portalpoint/google-api-key"
  recovery_window_in_days = local.secret_recovery_days
}

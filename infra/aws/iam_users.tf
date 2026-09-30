# Teammate IAM users for the SSM port-forward tunnel to RDS (docs/aws_rds_setup.md).
# Access keys are created out-of-band (`aws iam create-access-key`) and never
# managed here; force_destroy lets `terraform destroy` delete a user that still
# has keys.
locals {
  dev_users = toset(["ajay", "justin", "yoko"])
}

resource "aws_iam_user" "dev" {
  for_each      = local.dev_users
  name          = "${each.key}-portalpoint-infra"
  path          = "/"
  force_destroy = true
}

resource "aws_iam_user_group_membership" "dev" {
  for_each = local.dev_users
  user     = aws_iam_user.dev[each.key].name
  groups   = [aws_iam_group.dev.name]
}

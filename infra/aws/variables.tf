variable "region" {
  type    = string
  default = "us-east-1"
}

variable "account_id" {
  description = "PortalPoint infra account."
  type        = string
  default     = "424056758764"
}

# ---- default VPC (not managed here) ----
# The account's default VPC is shared with non-PortalPoint resources (e.g. the
# UCB_MIDS_w205_Security group) and costs nothing, so it and its default public
# subnets are referenced by ID rather than managed. On a brand-new account, look
# these up with `aws ec2 describe-subnets --filters Name=default-for-az,Values=true`.
variable "vpc_id" {
  type    = string
  default = "vpc-0704fc22b655ba770"
}

variable "public_subnet_ids" {
  description = "Default-VPC public subnets: [0] hosts the NAT gateway and bastion (us-east-1a); [0..1] host the ALB."
  type        = list(string)
  default     = ["subnet-0d573b4aee63c1490", "subnet-076c1137acea09c9b"]
}

variable "db_subnet_ids" {
  description = "Default-VPC subnets in the RDS subnet group (as originally created -- all public, one per AZ except 1b's default)."
  type        = list(string)
  default = [
    "subnet-022364c6709e7d644", "subnet-03ef22a33a6015935", "subnet-076c1137acea09c9b",
    "subnet-0b32d26e7cb719673", "subnet-0bb8f8a769148cc47", "subnet-0d573b4aee63c1490",
  ]
}

# ---- app ----
variable "github_repo" {
  description = <<-EOT
    owner/repo trusted by the GitHub Actions OIDC deploy role. Still the pre-rename
    name, matching what's live -- which is why every deploy.yml run since the
    rename to PortalPoint (~2026-09-09) failed to assume the role. Change to
    "shanthg01/PortalPoint" when rebuilding.
  EOT
  type        = string
  default     = "shanthg01/MIDS210-Capstone"
}

variable "data_bucket" {
  description = "S3 bucket for MLflow artifacts / model pkls / raw parquet. Lives in a DIFFERENT (bucket-owner) account; its bucket policy must separately allow the ECS task role."
  type        = string
  default     = "portalpoint-data"
}

variable "alert_email" {
  type    = string
  default = "shanthg01@berkeley.edu"
}

variable "bastion_ami" {
  description = "Amazon Linux 2023 AMI the bastion was launched from. For a rebuild, use a current AL2023 AMI instead (this one may be deregistered)."
  type        = string
  default     = "ami-0ed7d7210d3f78108"
}

variable "rds_final_snapshot_identifier" {
  description = "Name of the snapshot `terraform destroy` takes of portalpoint-db."
  type        = string
  default     = "portalpoint-db-final-2026-10"
}

variable "rds_restore_snapshot_identifier" {
  description = "Rebuild only: restore portalpoint-db from this snapshot. Leave null to create an empty DB (then pg_restore from the B2 dump)."
  type        = string
  default     = null
}

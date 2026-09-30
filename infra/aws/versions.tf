terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local state on purpose: an S3 backend can't live in the account this code
  # tears down. State can contain secret values -- *.tfstate is gitignored.
  backend "local" {}
}

provider "aws" {
  region = var.region

  # Guard against running against the wrong account (e.g. the bucket-owner one).
  allowed_account_ids = [var.account_id]
}

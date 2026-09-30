# PortalPoint AWS stack (Terraform)

The original production stack (ECS Fargate + ALB, RDS Postgres, ElastiCache, EFS, CloudFront + S3,
bastion, NAT) as code. It was imported from the live infra account (`424056758764`, `us-east-1`) on
2026-09-30 for decommissioning. `terraform plan` reported **No changes** against live before teardown,
so this code matches what actually ran.

Full context: [`docs/aws_decommission_runbook.md`](../../docs/aws_decommission_runbook.md) (teardown +
rebuild steps) and [`docs/production_deployment_commands.md`](../../docs/production_deployment_commands.md)
(the original, hand-run build history).

## Files

| File | What |
|---|---|
| `network.tf` | Private subnets, NAT + EIP, private route table, S3 gateway endpoint, all 6 security groups |
| `data.tf` | RDS (+ subnet/parameter groups), ElastiCache, EFS (MLflow tracking store) |
| `compute.tf` | ECR, ECS cluster/service/task def, ALB/target group/listener, bastion |
| `edge.tf` | Frontend S3 bucket (+ policy/PAB/ownership), CloudFront distribution, OAC, `spa-routing` function |
| `iam.tf` | GitHub OIDC provider + deploy role, ECS execution/task roles, bastion role/profile, `PortalPoint-Dev` group |
| `iam_users.tf` | Teammate SSM-tunnel users (`ajay`/`justin`/`yoko`-portalpoint-infra) |
| `secrets.tf` | Secrets Manager containers (values never in code) |
| `monitoring.tf` | Log group, SNS alerts topic + email subscription, ALB unhealthy-target alarm |

## Not managed here, on purpose

- **The default VPC**, its IGW/main route table/default subnets. They're shared (the account also holds
  a non-PortalPoint `UCB_MIDS_w205_Security` SG and `UCB` key pair) and free. They're referenced by ID
  in `variables.tf`.
- **`portalpoint-data`** (MLflow artifacts/models/raw parquet) and its bucket policy. They live in a
  different (bucket-owner) account.
- **Secret values, the RDS master password, IAM access keys.**
- **The `portalpoint-bastion` key pair** (legacy SSH-era; delete by hand on teardown).
- **Task-definition revisions** beyond the baseline `portalpoint-backend` one. `deploy.yml` and
  `scripts/run_in_ecs.sh` register the `-migrate`/`-modeling` families and new image revisions at runtime.

## Running Terraform

State is **local** (`terraform.tfstate`, gitignored, since it can contain secret values). It can't
live in S3 in the account being torn down.

**Credentials gotcha:** the AWS provider can't read `aws login` sessions (`login_session` in
`~/.aws/config`) directly: "No valid credential sources found". Export temporary credentials from the
CLI into the shell first. Also make sure stale `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars
aren't set, because they override everything:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
eval "$(aws configure export-credentials --format env)"
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: stops /ecs/... args being rewritten
terraform plan
```
The exported credentials expire; re-run the `eval` line if Terraform starts returning auth errors.

## Teardown
See runbook Step 5 (`terraform plan -destroy -out=destroy.tfplan` → review → `terraform apply destroy.tfplan`).
`skip_final_snapshot = false` is already in state, so destroy snapshots RDS to
`var.rds_final_snapshot_identifier` first.

## Rebuild
See the runbook's "Rebuilding the AWS stack". Before running `apply` on a rebuild:
- `github_repo` → `"shanthg01/PortalPoint"`. The live trust policy still names the pre-rename repo,
  which is why every `deploy.yml` run since ~2026-09-09 failed.
- `bastion_ami` → a current Amazon Linux 2023 AMI; drop `key_name` (SSM doesn't need it).
- `rds_restore_snapshot_identifier` → the final snapshot, if it still exists.
- After apply: set secret values, update `deploy.yml`'s hard-coded CloudFront distribution ID, and
  confirm the SNS email subscription.
- Cross-account: the bucket owner must re-add the `portalpoint-data` bucket-policy grant for the
  (new) `portalpoint-ecs-task` role ARN.

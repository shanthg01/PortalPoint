# AWS Decommission Runbook

**Status (2026-09-30):** Steps 1, 2 and 2b done. Step 1 is on branch `aws-decommission`
(`deploy.yml` disabled on GitHub). Step 2 inventory results are below. Step 2b: 70 resources imported into
`infra/aws/`, final `terraform plan` = **No changes**. Nothing in AWS has been modified or deleted yet.
**Later same day:** Step 3a done (40/42 tables identical; only gap: 1 user who signed up on the
old site on 2026-09-21, which you decided not to copy). Step 3b done (EFS MLflow store backed up to
`Desktop/MIDS/portalpoint_aws_backups/`; only 6 experiments/8 runs, no registry). Step 3d done (Tavily/Gemini
keys copied into local `.env`). **The old CloudFront URL now 301-redirects everything to
the Workers URL** (`redirect_to` in `infra/aws/variables.tf`) instead of being disabled, because people were
still logging into the old site as of 2026-09-29. Step 3c: skip if the team-rating what-if works on the
new stack. Next: Step 4 (the scream test minus CloudFront), which you run yourself (see below).

This finishes the platform migration in `docs/selfhost_no_vm_runbook.md`: shut down the AWS stack
(ECS/ALB/RDS/ElastiCache/EFS/CloudFront/S3) now that the free-tier stack (Render + Cloudflare Workers
+ Oracle VM Postgres + Upstash + B2) is live. The order matters: check the gates, freeze deploys,
**capture the infrastructure as Terraform**, keep copies of the data, run a reversible "scream test",
then `terraform destroy`.

**Goal: a reversible shutdown.** The AWS stack is preserved as code in `infra/aws/` (Step 2b). Standing
it back up is `terraform apply` plus a data restore (see "Rebuilding the AWS stack" at the end).
Terraform was chosen over CDK because it's better at importing resources that already exist, and it
can also codify the current Cloudflare/Render/OCI/B2 stack later.

**Two AWS accounts are involved:**
- **Infra account `424056758764`**: everything except the data bucket. Region `us-east-1`.
- **Bucket-owner account**: `s3://portalpoint-data` (MLflow artifacts, model pkls, hoopR raw parquet)
  and its bucket policy. Kept out of the Terraform code because it lives in a different account.
  **Open question:** earlier notes say it's Justin's account; confirm whose it is before Step 3c.
  The IAM users and groups in that account are handled in Step 7, which is optional.

**Known IDs** (from `docs/production_deployment_commands.md`; confirm each one in Step 2 before deleting):

| Resource | ID / name |
|---|---|
| CloudFront distribution | `E2HF7HKH8Y1FKD` (`d331zwrxbrp79d.cloudfront.net`), OAC `portalpoint-oac` |
| Frontend bucket | `s3://portalpoint-frontend` |
| ECS | cluster `portalpoint-prod`, service `portalpoint-backend`; task-def families `portalpoint-backend`, `portalpoint-backend-migrate`, `portalpoint-backend-modeling` |
| ECR | `portalpoint-backend` |
| ALB / TG | `portalpoint-alb` / `portalpoint-tg` |
| RDS | `portalpoint-db` (`db.m6g.large`, Single-AZ), SG `sg-0ec78cb4f641ee901` |
| ElastiCache | `portalpoint-cache`, subnet group `portalpoint-cache-subnets`, SG `portalpoint-cache-sg` |
| EFS (MLflow tracking store) | `fs-0701ce18ffb150214`, AP `fsap-0a142e76c49576fc3`, SG `sg-0d8c52ccc2a7d8c37` |
| Bastion | `i-0a6e1bafc1cb6f379`, SG `sg-06d79bdd59fea641a`, profile `portalpoint-bastion-profile` |
| ECS task SG | `sg-0585f9f30db5bfc57` |
| Networking | NAT gateway + its Elastic IP, S3 gateway VPC endpoint, private subnets + route table (IDs unknown, look them up in Step 2) |
| Secrets Manager | `portalpoint/database-url`, `portalpoint/database-master-url`, `portalpoint/jwt-secret`, `portalpoint/tavily-api-key`, `portalpoint/google-api-key` |
| Monitoring | alarm `portalpoint-unhealthy-targets`, SNS `portalpoint-alerts`, log group `/ecs/portalpoint-backend` |
| IAM | roles `portalpoint-gha-deploy`, `portalpoint-ecs-execution`, `portalpoint-ecs-task`, `portalpoint-bastion-role`; group `PortalPoint-Dev` + `*-portalpoint-infra` users; GitHub OIDC provider |

The biggest monthly costs are RDS, the NAT gateway, the ALB, ElastiCache and the Fargate task.

**Step 2 inventory results (2026-09-30), what the docs didn't say:**
- **September spend: $213** (RDS $113, NAT/"EC2-Other" $30, public IPv4 $17, ECS $17, ALB $15,
  ElastiCache $11, bastion $8, Secrets $2, ECR $1). Nothing unaccounted for. No resources in
  us-east-2/us-west-1/us-west-2; no EventBridge rules, Lambdas, Route53 zones, ACM certs or AWS Budgets.
- **The VPC is the account's default VPC** (`vpc-0704fc22b655ba770`). It stays. The account also holds
  **non-PortalPoint resources that must not be deleted:** the `UCB_MIDS_w205_Security` SG and the
  `UCB` key pair.
- **RDS:** 50GB gp3, **deletion protection is OFF**, `PubliclyAccessible=true` (but its SG only admits
  the ECS task + bastion SGs), custom parameter group `portalpoint-pg15`, 7 days of automated snapshots.
- **EFS is only 1.7MB**, so the Step 3b `mlruns.db` copy is trivial.
- Extra resources beyond the doc table: CloudFront function `spa-routing`, S3 ownership controls,
  3 teammate IAM users (`ajay`/`justin`/`yoko-portalpoint-infra`, all with active keys), SNS email
  subscription to `shanthg01@berkeley.edu`. ECR holds 22 images; task-def revisions: backend 4,
  migrate 6, modeling 23.
- **Every `deploy.yml` run since ~2026-09-09 failed.** The OIDC deploy role still trusts
  `repo:shanthg01/MIDS210-Capstone`, so the repo rename to PortalPoint broke it. The CloudFront site
  has therefore been serving a stale pre-September build. `infra/aws/variables.tf` → `github_repo` notes
  the fix for a rebuild.
- **Credentials gotcha:** stale `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars (an old, invalid
  key) override `aws login`. Unset them per shell. Terraform can't read `aws login` sessions
  directly: `eval "$(aws configure export-credentials --format env)"` first (see `infra/aws/README.md`).

---

## Step 0: Go/no-go gates (don't touch AWS until all pass)

- [ ] **The VM has nightly backups and a restore has been tested.** The self-host runbook's
  "No backups configured yet" item looks resolved: the 2026-09-11 commit says the cron is running
  with off-site B2 retention. Still, restore one dump into a scratch DB and compare row counts on
  2-3 large tables before RDS goes away. Right now RDS is the only other full copy.
- [ ] **Cloudflare's native "Workers Builds" is disconnected** (dashboard → Workers & Pages →
  portalpoint → Settings → Build → disconnect). Otherwise every frontend push can ship a broken bundle.
- [ ] **Full UI click-through on the new stack** (recommendations, compare, projections, shortlist,
  settings). The self-host runbook says this hasn't been done yet.
- [ ] **No AWS-side data is newer than the VM.** If any `run_*.py` or ingest wrote to RDS after the
  lift-and-shift, rerun `scripts/selfhost/lift_and_shift_vm.py` (idempotent) first. Step 3a checks this.
- [ ] **Teammates know the date.** Share the new URLs; nobody should still be using the SSM tunnel.
- [ ] **Working infra-account credentials.** `aws sts get-caller-identity` currently fails with
  `InvalidClientTokenId` on `default`. Run `aws login` again or get a key from Justin.

---

## Step 1: Freeze AWS deploys and repoint public links (repo changes, one PR)

Do this first. As long as `deploy.yml` exists, every merge to `main` rebuilds ECR, runs an ECS
migration task and syncs CloudFront. Once IAM is gone, every merge will fail.

1. **Disable `.github/workflows/deploy.yml`**: change `on:` to `workflow_dispatch` only. Keep the
   file, because it's the deploy path if the stack is ever rebuilt. Also run `gh workflow disable deploy`
   so it takes effect immediately, before the PR merges (undo: `gh workflow enable deploy`).
2. **GitHub Pages landing page** (`gh-pages` branch, `index.html` lines 331 and 607; this is the repo's
   homepage, https://shanthg01.github.io/PortalPoint/): change both `https://d331zwrxbrp79d.cloudfront.net`
   links to `https://portalpoint.shanthg01.workers.dev`. This is the only public link to the old app
   that visitors actually see.
3. **README.md "Live Site"** (line 12): change it to the Workers URL and replace "S3+CloudFront / ECS
   Fargate / RDS" with the new stack. Point readers to `docs/selfhost_no_vm_runbook.md`.
4. **Everything else with AWS references is historical docs.** Add a one-line "decommissioned 2026-MM-DD"
   banner rather than rewriting them: `docs/road_to_production.md`, `docs/production_deployment_commands.md`,
   `docs/status/ARCHITECTURE_STATUS.md`, `docs/status/STATUS.md`, `docs/aws_rds_setup.md`,
   `docs/aws_s3_setup.md`, `docs/presentation/final_presentation_plan.md` (line 392, "Live app" URL:
   **update this one**, it's presenter-facing).
5. **Leave these for Step 8 (after teardown):** `scripts/run_in_ecs.sh` (still needed for Step 3b),
   the RDS/SSM references in `scripts/selfhost/migrate_db.sh`, `.env.example` (RDS tunnel comment,
   `S3_BUCKET=portalpoint-data`), and comments in `src/` mentioning ECS. None of them break anything.
6. Local-only (not tracked): update `CLAUDE.md`'s "Production Deployment" and "RDS Access" sections.

---

## Step 2: Inventory (fill in the unknown IDs, catch anything undocumented)

```bash
export AWS_REGION=us-east-1 MSYS_NO_PATHCONV=1   # MSYS_NO_PATHCONV stops Git Bash mangling /ecs/... args

aws sts get-caller-identity                       # must say 424056758764

# Everything tagged or named portalpoint, plus a cross-service sweep
aws resourcegroupstaggingapi get-resources --query 'ResourceTagMappingList[].ResourceARN' --output text
aws ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' --output table
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].[NatGatewayId,VpcId,NatGatewayAddresses[0].AllocationId]' --output table
aws ec2 describe-addresses --query 'Addresses[].[AllocationId,PublicIp,AssociationId]' --output table
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[].[VpcEndpointId,VpcId,ServiceName]' --output table
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,IsDefault,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table
aws rds describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,DeletionProtection,DBSubnetGroup.DBSubnetGroupName]' --output table
aws rds describe-db-snapshots --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotType,AllocatedStorage]' --output table
aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,LoadBalancerArn]' --output table
aws efs describe-file-systems --query 'FileSystems[].[FileSystemId,SizeInBytes.Value]' --output table
aws events list-rules --query 'Rules[].Name'      # expect none (Phase 5 was never built)
aws s3 ls                                          # expect portalpoint-frontend (portalpoint-data lives in Justin's account)
aws iam list-roles --query 'Roles[?contains(RoleName,`portalpoint`)].RoleName'
aws iam list-open-id-connect-providers
```

Also check **Billing → Cost Explorer, grouped by Service, last 30 days**. Any service with spend that
isn't in the table at the top is an undocumented resource. Find it before deleting anything.

Record the VPC ID, NAT ID, EIP allocation ID, VPC endpoint ID, private subnet/route-table IDs and ALB
SG ID for later steps. **Decide now whether the VPC itself gets deleted.** Delete it only if it's a
non-default VPC that holds nothing but PortalPoint. If it's the default VPC, or Justin uses it for
anything else, keep the VPC and delete only the resources inside it.

---

## Step 2b: Capture the stack as Terraform (`infra/aws/`)

The Step 2 inventory becomes the list of resources to import. Terraform 1.5+ can generate config from
`import` blocks (Terraform 1.9.8 is installed locally).

**Layout:**
```
infra/aws/
  versions.tf        # terraform + aws provider pins; backend "local" (see State below)
  variables.tf       # region, vpc_id (if the VPC is kept out of code), image tag, instance sizes
  imports.tf         # one import block per live resource; delete after the first clean plan
  network.tf         # private subnets, route table, NAT + EIP, S3 gateway endpoint, SGs (+ VPC if owned)
  data.tf            # RDS instance + subnet group, ElastiCache + subnet group, EFS + AP + mount targets
  compute.tf         # ECR, ECS cluster/service/task defs, ALB/TG/listener, bastion + profile
  edge.tf            # CloudFront distribution + OAC, portalpoint-frontend bucket + policy
  iam.tf             # gha-deploy/ecs-execution/ecs-task/bastion roles, OIDC provider, PortalPoint-Dev group
  secrets.tf         # secret *containers* only; values are set out-of-band, never in code
  monitoring.tf      # log group, alarm, SNS topic
  README.md          # apply/destroy/rebuild instructions
```

**Procedure:**
1. Write `imports.tf` with an `import { to = ..., id = ... }` block for each resource from Step 2.
2. `terraform init && terraform plan -generate-config-out=generated.tf`, then sort the generated
   resources into the files above. Replace hard-coded IDs with references/variables, and delete
   read-only/computed attributes that the generator emits.
3. Iterate until **`terraform plan` reports "No changes."** That's the proof that the code matches
   what's running. Don't go on to Step 3 until it does.
4. Remove `imports.tf` and commit the code (not the state; see below).

**Deliberately left out of the code:**
- Secret *values*. `aws_secretsmanager_secret` is codified, `aws_secretsmanager_secret_version` isn't.
- Task-definition revisions that were one-off migration/modeling runs. Codify only the
  `portalpoint-backend` family. `deploy.yml` and `run_in_ecs.sh` derive the others at runtime.
- `portalpoint-data` and its bucket policy (a different account).
- The VPC itself, if Step 2 decided it stays (pass `vpc_id` in as a variable instead).

**Settings for safe destroy/rebuild:**
- RDS: `skip_final_snapshot = false`, `final_snapshot_identifier = "portalpoint-db-final-2026-10"`,
  `delete_automated_backups = true`. These are already applied to state (destroy reads them from state,
  not config). `deletion_protection = false` matches live (it was never on). For a rebuild, set
  `rds_restore_snapshot_identifier` if the snapshot still exists.
- ECR: `force_delete = true`. S3 frontend bucket: `force_destroy = true`.
- Secrets: `recovery_window_in_days = 7`.

**State:** use a **local** state file, never an S3 backend in the account being torn down. Keep
`*.tfstate*` gitignored while resources exist, since state can contain secret values. After
`destroy` the state is empty; delete it or keep it locally. Add `infra/aws/.terraform/` and
`*.tfstate*` to `.gitignore`. Commit `.terraform.lock.hcl`.

---

## Step 3: Keep copies of everything AWS holds that the new stack doesn't

### 3a. RDS: final parity check + snapshot
Open the SSM tunnel (while the bastion still exists) and compare exact row counts, RDS vs. VM, for
every table. Reuse the audit pass from `lift_and_shift_vm.py`. Any gap means rerun the copy first.

The snapshot is taken as part of the delete in Step 5. It costs about $0.095/GB-month (~$4/mo at
~42GB). Keep it 30 days as a safety net, then delete it (Step 9).

Optional but recommended: keep one extra `pg_dump` from RDS in B2 too. Snapshots live inside the AWS
account, and a dump doesn't depend on it.

### 3b. EFS: MLflow tracking store (`mlruns.db`). Easy to miss.
The EFS-mounted SQLite store holds the model registry: every `@champion` alias and run history from
the in-VPC modeling runs. The new stack tracks MLflow in the VM's Postgres, so this history is **not**
on the VM. Copy it out through the task role's existing S3 write access to `portalpoint-data/mlflow/*`:

```bash
export PORTALPOINT_MLFLOW_FS_ID=fs-0701ce18ffb150214
export PORTALPOINT_MLFLOW_AP_ID=fsap-0a142e76c49576fc3
./scripts/run_in_ecs.sh -c "import boto3; boto3.client('s3').upload_file('/mnt/mlflow/mlruns.db','portalpoint-data','mlflow/_final_backup/mlruns.db')"
aws s3 cp s3://portalpoint-data/mlflow/_final_backup/mlruns.db ./mlruns_ecs_final.db   # needs bucket-owner-account creds
```
Then push `mlruns_ecs_final.db` to B2 (`mc cp`) and keep a local copy. Check it with
`sqlite3 mlruns_ecs_final.db "select name from registered_models"`.

### 3c. S3 `portalpoint-data` → B2 parity (bucket-owner account)
The new backend reads MLflow artifacts and model pkls from B2. Confirm B2 has everything:
```bash
aws s3 ls s3://portalpoint-data --recursive --summarize | tail -2     # object count + total size
mc ls --recursive --summarize b2/portalpoint | tail -2
```
If they don't match, rerun `scripts/selfhost/sync_s3_to_minio.sh` against B2. Mind B2's 10GB free cap:
backups already use ~7.7GB of it (3 × ~2.57GB). If artifacts plus backups don't fit, choose between a
paid B2 tier, a second bucket/provider, or dropping raw hoopR parquet (it can be regenerated from
`ingest_hoopr.py`).

### 3d. Secrets
- `portalpoint/tavily-api-key`, `portalpoint/google-api-key`: confirm the same values are set on Render
  (news-monitoring agent). Copy them before deleting.
- `database-url`/`database-master-url`/`jwt-secret` point at RDS or are superseded. Nothing to carry over.
  Existing user JWTs are already invalid on the new stack, since it has its own secret.

---

## Step 4: Scream test (reversible, run 3-7 days)

Stop traffic and compute, but keep the data. If something still depends on AWS, it breaks now while it
can still be undone.

```bash
# Backend to zero tasks (restore: --desired-count 1)
aws ecs update-service --cluster portalpoint-prod --service portalpoint-backend --desired-count 0

# CloudFront: NOT disabled. It already 301-redirects to the new site (done 2026-09-30) and no longer
# depends on the ALB, so it keeps old links working while the backend is torn down.

# Stop (not terminate) the bastion; stop RDS (auto-restarts after 7 days, so this window caps at 7)
aws ec2 stop-instances --instance-ids i-0a6e1bafc1cb6f379
aws rds stop-db-instance --db-instance-identifier portalpoint-db

# Delete the two hourly-billed resources that hold no data (both are in the Terraform code, so
# `terraform apply` recreates them if a rollback is needed)
aws elasticache delete-cache-cluster --cache-cluster-id portalpoint-cache
aws ec2 delete-nat-gateway --nat-gateway-id <NAT_ID>    # its EIP is released in Step 5 by destroy
```
Run this **after** Step 3. 3a needs the bastion and RDS running, and 3b needs the ECS service's network
config plus the NAT gateway (the task pulls its image from ECR through it). **Run this for 2–3 days.**
Watch the new stack's logs and ask teammates whether anything broke.

**Cost during the scream test:** about $1/day with ElastiCache and NAT gone. That's mostly the ALB
(~$0.70/day, kept because deleting it would mean re-pointing CloudFront's `/api/*` origin on rollback)
plus RDS/bastion storage. For comparison, it's about $2.50–3/day if those two are kept, and about
$6–8/day with everything running.

**Rollback:** set ECS desired count back to 1, re-enable CloudFront, start RDS and the bastion, and
`terraform apply` (recreates ElastiCache and NAT). Afterwards, `terraform plan` should show no changes again.

**Terraform drift from this step is expected.** After Step 4, `terraform plan` will want to recreate
ElastiCache and NAT, and will see ECS at 0 and CloudFront disabled. That's fine: the next command run
is `destroy`. Don't "fix" the code to match the scream-test state.

---

## Step 5: `terraform destroy`

> **Irreversible except through the RDS final snapshot and the Step 3 copies.** Before starting,
> confirm that 3a's parity check passed, 3b's `mlruns.db` was checked, and Step 0's VM restore test passed.

```bash
cd infra/aws
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
eval "$(aws configure export-credentials --format env)"
# 1. RDS is stopped from Step 4; a stopped instance can't be deleted
aws rds start-db-instance --db-instance-identifier portalpoint-db
aws rds wait db-instance-available --db-instance-identifier portalpoint-db
# 2. Confirm the final-snapshot settings are in state (they were applied during Step 2b):
terraform state show aws_db_instance.portalpoint | grep -E "skip_final_snapshot|final_snapshot_identifier"
# 3. Review the plan: every resource should show "destroy", 70 in total, none outside PortalPoint
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```
Terraform works out the deletion order itself. CloudFront is the slowest (it must finish disabling
before it can be deleted, ~15 min), then RDS (final snapshot, ~10–20 min) and the NAT/ENI drain.
If a resource fails with `DependencyViolation`, wait a few minutes and rerun `terraform apply destroy.tfplan`
(or re-plan).

**After destroy:** confirm `terraform state list` is empty, then run the Step 2 inventory again. The
only things left should be the RDS final snapshot and anything intentionally left out of the code
(the VPC, if kept). Terraform doesn't manage the bastion's key pair or `.pem`, so delete those by hand.

### Manual fallback (only if Terraform can't do it)
These are the same deletions as CLI commands, for any resource that couldn't be imported or that
destroy gets stuck on. Each block assumes the ones above it are finished. Use waiters where shown;
deleting too early fails with "DependencyViolation" or "in use". ElastiCache and the NAT gateway
should already be gone from Step 4.

**5.1 CloudFront + frontend bucket**
```bash
aws cloudfront wait distribution-deployed --id E2HF7HKH8Y1FKD     # disable from Step 4 must be fully deployed
ETAG=$(aws cloudfront get-distribution --id E2HF7HKH8Y1FKD --query ETag --output text)
aws cloudfront delete-distribution --id E2HF7HKH8Y1FKD --if-match "$ETAG"
OAC_ID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='portalpoint-oac'].Id" --output text)
aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$(aws cloudfront get-origin-access-control --id $OAC_ID --query ETag --output text)"
aws s3 rb s3://portalpoint-frontend --force
```

**5.2 ECS + ECR**
```bash
aws ecs delete-service --cluster portalpoint-prod --service portalpoint-backend --force
aws ecs wait services-inactive --cluster portalpoint-prod --services portalpoint-backend
for fam in portalpoint-backend portalpoint-backend-migrate portalpoint-backend-modeling; do
  for td in $(aws ecs list-task-definitions --family-prefix $fam --query 'taskDefinitionArns[]' --output text); do
    aws ecs deregister-task-definition --task-definition $td >/dev/null
    aws ecs delete-task-definitions --task-definitions $td >/dev/null
  done
done
aws ecs delete-cluster --cluster portalpoint-prod
aws ecr delete-repository --repository-name portalpoint-backend --force
```

**5.3 ALB, target group, alarm, SNS**
```bash
ALB_ARN=$(aws elbv2 describe-load-balancers --names portalpoint-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names portalpoint-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"      # removes its listeners too
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
aws cloudwatch delete-alarms --alarm-names portalpoint-unhealthy-targets
aws sns delete-topic --topic-arn "$(aws sns list-topics --query "Topics[?ends_with(TopicArn,':portalpoint-alerts')].TopicArn" --output text)"
```

**5.4 ElastiCache**
```bash
aws elasticache delete-cache-cluster --cache-cluster-id portalpoint-cache
aws elasticache wait cache-cluster-deleted --cache-cluster-id portalpoint-cache
aws elasticache delete-cache-subnet-group --cache-subnet-group-name portalpoint-cache-subnets
```

**5.5 EFS** (only after 3b's `mlruns.db` copy has been checked)
```bash
aws efs delete-access-point --access-point-id fsap-0a142e76c49576fc3
for mt in $(aws efs describe-mount-targets --file-system-id fs-0701ce18ffb150214 --query 'MountTargets[].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id $mt; done
# wait until describe-mount-targets returns empty (~1-2 min), then:
aws efs delete-file-system --file-system-id fs-0701ce18ffb150214
```

**5.6 RDS**
> **Irreversible, except through the final snapshot.** Don't start this until 3a's parity check
> passed and Step 0's VM restore test is done.
```bash
aws rds start-db-instance --db-instance-identifier portalpoint-db   # only if still stopped from Step 4; a stopped instance can't be deleted
aws rds wait db-instance-available --db-instance-identifier portalpoint-db
aws rds delete-db-instance --db-instance-identifier portalpoint-db \
  --final-db-snapshot-identifier portalpoint-db-final-2026-10 --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier portalpoint-db
# then the DB subnet group (name from Step 2), and any custom parameter group:
aws rds delete-db-subnet-group --db-subnet-group-name <DB_SUBNET_GROUP>
```

**5.7 Bastion**
```bash
aws ec2 terminate-instances --instance-ids i-0a6e1bafc1cb6f379
aws ec2 wait instance-terminated --instance-ids i-0a6e1bafc1cb6f379
aws ec2 delete-key-pair --key-name <bastion key pair name>          # then delete portalpoint-bastion.pem locally
# release its Elastic IP too, if Step 2 showed one
```

**5.8 Networking** (NAT is the expensive one)
```bash
aws ec2 delete-nat-gateway --nat-gateway-id <NAT_ID>
aws ec2 wait nat-gateway-deleted --nat-gateway-ids <NAT_ID>
aws ec2 release-address --allocation-id <NAT_EIP_ALLOCATION_ID>
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids <S3_ENDPOINT_ID>
# SGs: delete once nothing references them (retry any "DependencyViolation" after ENIs drain)
for sg in sg-0d8c52ccc2a7d8c37 <CACHE_SG_ID> sg-0585f9f30db5bfc57 <ALB_SG_ID> sg-0ec78cb4f641ee901 sg-06d79bdd59fea641a; do
  aws ec2 delete-security-group --group-id $sg; done
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<VPC_ID> --output table   # should be empty
```
Then, based on the Step 2 decision: delete the private subnets and their route table, or, if the whole
VPC is PortalPoint's: detach and delete the IGW, delete all subnets, non-main route tables and the
remaining non-default SGs, then `aws ec2 delete-vpc --vpc-id <VPC_ID>`.

**5.9 Secrets + logs**
```bash
for s in database-url database-master-url jwt-secret tavily-api-key google-api-key; do
  aws secretsmanager delete-secret --secret-id portalpoint/$s --recovery-window-in-days 7; done
aws logs delete-log-group --log-group-name /ecs/portalpoint-backend
aws logs describe-log-groups --query 'logGroups[].logGroupName'   # delete any other portalpoint/ECS/RDS leftovers
```
RDS may have created a managed master secret (`rds!db-...`). If Step 2 listed one, it was deleted
along with the instance.

**5.10 IAM (last, since everything above needs the permissions)**
Each role: remove all inline policies (`list-role-policies` → `delete-role-policy`) and detach managed
ones (`list-attached-role-policies` → `detach-role-policy`) before `delete-role`.
```bash
for r in portalpoint-gha-deploy portalpoint-ecs-execution portalpoint-ecs-task portalpoint-bastion-role; do
  for p in $(aws iam list-role-policies --role-name $r --query 'PolicyNames[]' --output text); do aws iam delete-role-policy --role-name $r --policy-name $p; done
  for a in $(aws iam list-attached-role-policies --role-name $r --query 'AttachedPolicies[].PolicyArn' --output text); do aws iam detach-role-policy --role-name $r --policy-arn $a; done
done
aws iam remove-role-from-instance-profile --instance-profile-name portalpoint-bastion-profile --role-name portalpoint-bastion-role
aws iam delete-instance-profile --instance-profile-name portalpoint-bastion-profile
for r in portalpoint-gha-deploy portalpoint-ecs-execution portalpoint-ecs-task portalpoint-bastion-role; do aws iam delete-role --role-name $r; done

# Teammate SSM users: for each <name>-portalpoint-infra user
aws iam list-access-keys --user-name <user>          # delete-access-key for each
aws iam remove-user-from-group --group-name PortalPoint-Dev --user-name <user>
aws iam delete-user --user-name <user>
aws iam delete-group-policy --group-name PortalPoint-Dev --policy-name PortalPointSSMBastionAccess
aws iam delete-group --group-name PortalPoint-Dev

# GitHub OIDC provider: only if no other repo/role in this account uses it
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::424056758764:oidc-provider/token.actions.githubusercontent.com
```

---

## Step 6: GitHub cleanup
- The only repo secrets/variables are Cloudflare's (verified 2026-09-30), and `deploy.yml` used OIDC,
  so there are no AWS keys to remove from GitHub.
- The only GitHub environment is `github-pages` (the landing page). Keep it; it has nothing to do with AWS.

## Step 7 (optional): bucket-owner account (`portalpoint-data`)
Not required for cost, since IAM users, groups and keys are free. The one real risk is old S3 access
keys that still work, and it mostly goes away once the bucket is gone. Do this if/when someone with
access to that account can. After 3b/3c are verified:
- Remove the bucket-policy statement that grants `portalpoint-ecs-task` (the role is deleted anyway).
- Empty and delete `s3://portalpoint-data` (`aws s3 rb s3://portalpoint-data --force`), or keep it
  briefly as a cold copy. It's cheap, but note it in this doc if kept.
- Deactivate/delete the S3 IAM access keys handed to teammates, the users, and that account's
  `PortalPoint-Dev` group. Remove `AWS_*` S3 keys from everyone's local `.env`.

## Step 8: Repo cleanup (post-teardown PR)
- **Keep** `.github/workflows/deploy.yml` (dispatch-only), `scripts/run_in_ecs.sh`, and
  `docs/cloudfront-spa-routing-function.js`. They're part of the rebuild path together with `infra/aws/`.
  Add a header comment to each pointing at `infra/aws/README.md`.
- `README.md` developer setup: the prerequisites table, "Start infrastructure", the env-var table,
  and the "Team RDS access (AWS)" / "Team S3 access (AWS)" sections all describe RDS/SSM/S3 (they
  carry a "being decommissioned" banner from Step 1). Rewrite them for the VM Postgres + B2 setup.
- `.env.example`: drop the RDS/SSM tunnel comment and point at the self-host variables
  (or merge in `.env.selfhost.example`).
- `scripts/selfhost/migrate_db.sh` / `lift_and_shift_vm.py`: add a header saying the source (RDS) no
  longer exists. They stay as history.
- Delete local-only files: `ssm-tunnel-params.json`, `ssm-cache-tunnel-params.json`, `task-def*.json`,
  `cloudfront-config.json`, `s3-bucket-policy.json`, `portalpoint-bastion.pem`.

## Step 9: Verify $0, then final cleanup
- Cost Explorer daily view: after 2-3 days, only the RDS snapshot's storage should remain in the infra account.
- Set an AWS Budget alert at $1/month on both accounts so a forgotten resource can't keep billing unnoticed.
- **Day +30:** `aws rds delete-db-snapshot --db-snapshot-identifier portalpoint-db-final-2026-10`,
  as long as the new stack has run cleanly and B2 has a verified dump.
- Keep the infra account open (it costs $0 when empty) if a rebuild is plausible, and **turn on root MFA**.
  The `default` CLI profile was logged in as the **root** user. Closing the account is the only
  guaranteed $0, but a rebuild would then need a new account and new IDs.

---

## Rebuilding the AWS stack (if ever needed)

The code recreates the infrastructure, but the data and secret values have to be restored separately.

1. **Credentials + state:** log into the infra account, `cd infra/aws && terraform init`.
2. **Database source:** set `snapshot_identifier` in `data.tf` if the RDS final snapshot still exists
   (fastest). Otherwise leave it empty; the DB is restored from the B2 dump in step 5.
3. **`terraform apply`.** It creates the VPC pieces, RDS, ElastiCache, EFS, ECR, ECS, ALB,
   CloudFront, IAM and empty secrets. ECS tasks will fail until steps 4–5 are done. That's expected.
4. **Secret values:** `aws secretsmanager put-secret-value` for `database-url` (new RDS hostname),
   `database-master-url`, `jwt-secret`, `tavily-api-key`, `google-api-key`.
5. **Data:** if RDS came from the snapshot, skip this. Otherwise open the SSM tunnel via the new bastion
   and restore the latest B2 dump (`pg_restore`), then run `alembic upgrade head`. Restore `mlruns.db`
   from B2 onto EFS (a one-off `run_in_ecs.sh -c` task, the reverse of Step 3b).
6. **Deploy:** re-enable and dispatch `deploy.yml` (`gh workflow enable deploy && gh workflow run deploy`).
   It builds/pushes the image, runs migrations, rolls ECS, and syncs the frontend. The new CloudFront
   distribution ID must be updated in `deploy.yml` first (and the S3 bucket name, if changed).
7. **Point things at the new URLs:** CloudFront gets a new `dxxxx.cloudfront.net` domain, and RDS/ALB
   get new hostnames. Update README, the landing page and CORS. A custom domain would make this step unnecessary.
8. **Verify:** `/ready` is healthy on the ALB target group, and the frontend loads through CloudFront.

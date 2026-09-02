# Self-Hosted (Zero-Cost) Stack — Runbook

Dual-hosted alongside the AWS production stack (ECS/RDS/ElastiCache/S3/CloudFront,
see `docs/road_to_production.md`). This doc covers the free-tier replacement:
managed free services for everything except the database, which lives on a
free-tier VM (full data didn't fit any managed free Postgres tier — see
"Why the DB moved to a VM" below). AWS is untouched by anything here and
remains the system of record until an explicit decision to cut over.

**Live URLs:**
- Frontend: https://portalpoint.shanthg01.workers.dev
- Backend: https://portalpoint.onrender.com (`/health`, `/ready`, `/docs`)

## Architecture

| Piece | Provider | Replaces (AWS) |
|---|---|---|
| Postgres + pgvector | Self-hosted on Oracle Cloud free-tier VM | RDS |
| Redis | Upstash | ElastiCache |
| Object storage (MLflow artifacts, hoopR raw parquet) | Backblaze B2 (S3-compatible) | S3 |
| Backend (FastAPI container) | Render (free Web Service) | ECS Fargate + ALB |
| Frontend (static React build) | Cloudflare Workers (static assets) | S3 + CloudFront |

Tradeoff vs. fully-managed: Render's free tier spins down after ~15min idle
(~30-50s cold start on the next request); the DB VM has no such penalty but
is now a self-managed box (see "Known open items").

## Why the DB moved to a VM

Every managed free-tier Postgres (Neon, Supabase, etc.) caps out around
0.5-1GB storage. The real dataset is **42.5GB** (dominated by 5 ML-output
tables: `player_team_fit_scores` ~20GB, `playing_time_projections` ~10GB,
`player_projections` ~8GB, `transfer_success_scores` ~3GB,
`team_rating_projections` ~2GB). A first pass ran on Neon with just
`schools` + a one-school slice of the 5 giants to prove the app worked; a
follow-up lift-and-shift moved everything to a free-tier VM instead
(Oracle Cloud Always Free: real 200GB block storage, $0), which fits the
full dataset with room to spare (33GB used of 200GB after the full copy).

## Credentials

All real connection strings/keys live in:
- Local `.env` (gitignored, never committed) — for anyone running scripts
  locally against this stack.
- Render's dashboard env vars (Environment tab) — for the running backend.
- GitHub repo secrets (Settings → Secrets and variables → Actions) — for the
  frontend deploy workflow below.
- The VM's own filesystem (SSH access only) — Postgres container env vars.

Nothing here is duplicated into any tracked repo file.

## Database VM (Oracle Cloud)

**Provisioning notes** (for recreating or scaling up):
- Shape: `VM.Standard.A1.Flex` (Ampere ARM), Always Free eligible up to 4
  OCPU/24GB RAM total allowance.
- Boot volume: 100GB+ (Always Free covers up to 200GB block storage total) —
  the wizard's default (often 50GB) isn't enough headroom for growth.
- Boot volume VPU/GB: leave at the default (10, "Balanced") — increasing it
  is a separate cost dimension from the storage allowance and risks real
  charges.
- OS image: Ubuntu 24.04 LTS.
- Networking: new VCN with a **public** subnet (needs a route to an
  Internet Gateway), "Assign a public IPv4 address" checked on the VNIC. If
  that checkbox gets missed at creation time, attach a Reserved Public IP
  after the fact via the VNIC's IPv4 Addresses table → row-level Edit
  action (not the Reserved-IP resource's own ellipsis menu, which has no
  attach option).
- SSH: default username is `ubuntu` for this image, not your OCI console
  login name.

**⚠️ Real gotcha: Oracle's Ubuntu image ships a default-deny `iptables`
ruleset** even after the OCI-level Security List/NSG allows a port — the
Security List is necessary but not sufficient. Both layers need the same
ports opened:
- OCI Security List: ingress TCP 22 (SSH) and 5432 (Postgres), source
  `0.0.0.0/0` (Render has no static egress IP on its free tier, so this
  can't be scoped tighter without breaking connectivity).
- VM's own `iptables`: `sudo iptables -I INPUT 5 -p tcp --dport 5432 -m
  state --state NEW -j ACCEPT` (insert before the existing REJECT rule),
  then persist with `sudo apt-get install -y iptables-persistent && sudo
  netfilter-persistent save` or it reverts on reboot.

**Running Postgres:**
```bash
sudo docker run -d \
  --name portalpoint-db \
  --restart unless-stopped \
  -e POSTGRES_DB=portalpoint \
  -e POSTGRES_USER=portalpoint_app \
  -e POSTGRES_PASSWORD="<password>" \
  -p 5432:5432 \
  -v pgdata:/var/lib/postgresql/data \
  pgvector/pgvector:pg15
```
`--restart unless-stopped` means it survives a VM reboot automatically. Data
lives in the `pgdata` named Docker volume, not the container itself.

**Connecting:** plain (unencrypted) TCP, no `ssl=`/`sslmode=` param needed —
`postgresql+asyncpg://portalpoint_app:<password>@<vm-public-ip>:5432/portalpoint`
(async, for the backend/alembic) or the `+psycopg2` form (sync, for
MLflow's tracking URI and standalone scripts).

## Backend (Render)

**Redeploy:** automatic — Render's own git integration triggers on every
push to `main` (`autoDeploy: yes`). No GitHub Actions workflow needed for
this half.

**Env vars set on the Render service** (Environment tab):
```
DATABASE_URL=postgresql+asyncpg://portalpoint_app:<password>@<vm-public-ip>:5432/portalpoint
REDIS_URL=rediss://default:<password>@<upstash-host>:6379
JWT_SECRET=<random>
JWT_ALGORITHM=HS256
JWT_EXPIRY_SECONDS=3600
ENVIRONMENT=production
CORS_ORIGINS=https://portalpoint.shanthg01.workers.dev http://localhost:3000 http://localhost:5173
MLFLOW_TRACKING_URI=postgresql+psycopg2://portalpoint_app:<password>@<vm-public-ip>:5432/portalpoint
AWS_ACCESS_KEY_ID=<B2 keyID>
AWS_SECRET_ACCESS_KEY=<B2 applicationKey>
AWS_S3_ENDPOINT_URL=https://s3.<region>.backblazeb2.com
MLFLOW_S3_ENDPOINT_URL=https://s3.<region>.backblazeb2.com
S3_BUCKET=portalpoint
AWS_DEFAULT_REGION=<B2 region, e.g. us-east-005>
```

**Health check path:** `/ready` (set via Render API — the real DB-aware
check, matches the ALB target-group convention on the AWS side, not `/health`).

**⚠️ Migrations are NOT automatic.** Render's Pre-Deploy Command field is
locked on the free tier. After any schema change (new alembic revision),
run manually against the VM before or right after the next deploy:
```bash
DATABASE_URL="postgresql+asyncpg://portalpoint_app:<password>@<vm-public-ip>:5432/portalpoint" \
  uv run alembic upgrade head
```
Alembic's `env.py` uses the async engine directly — use the `+asyncpg` form,
not the psycopg2 form, for this specific command.

**Programmatic access:** Render has a REST API (`api.render.com`) for
reading/writing env vars and triggering deploys — used throughout setup,
requires a Render API key (Account Settings → API Keys). Not wired into any
GitHub workflow; env var changes were applied ad hoc.

## Frontend (Cloudflare Workers)

This project was deployed manually (`wrangler deploy`), not through
Cloudflare's git-integrated build pipeline — confirmed via the Workers API
(`last_deployed_from` was empty). That matters because Vite bakes
`VITE_API_BASE_URL` into the JS bundle at **build time**, on whichever
machine runs `npm run build` — Cloudflare never runs a build here, so a
dashboard/API env var setting would be a no-op. The value must be set before
every build.

**Redeploy:** automatic via `.github/workflows/deploy-cloudflare-frontend.yml`
on every push to `main` touching `frontend/**`, or manually via
`workflow_dispatch`.

**Manual fallback** (if you ever need to deploy without GitHub Actions):
```powershell
cd frontend
$env:VITE_API_BASE_URL = "https://portalpoint.onrender.com/api"
npm run build
$env:CLOUDFLARE_API_TOKEN = "<token>"
$env:CLOUDFLARE_ACCOUNT_ID = "63c1d68768bb35d40aa524aef74c2d4c"
npx wrangler deploy
```

**⚠️ Do not pass `--env production` to `wrangler deploy`.** The Cloudflare
dashboard shows this service's environment as "production," but that's
metadata for its *default* environment, not a `wrangler.jsonc`
`env.production` block (which doesn't exist here). Passing `--env
production` anyway silently creates a **separate new Worker**
(`portalpoint-production`) instead of updating the real one — this happened
once during initial setup; the stray worker was deleted by hand.
`frontend/wrangler.jsonc` has no `env` section on purpose — leave it that
way, or add a matching `[env.production]` block first if `--env` is ever
genuinely needed.

**Required GitHub configuration** (Settings → Secrets and variables → Actions):
- **Secret** `CLOUDFLARE_API_TOKEN` — scoped to **Account → Workers Scripts →
  Edit** (Pages permission alone is NOT sufficient — this is a Workers
  service, not classic Pages, despite living under the same "Workers &
  Pages" dashboard and originally being described as "Cloudflare Pages"
  during planning).
- **Variable** (not a secret — not sensitive) `CLOUDFLARE_ACCOUNT_ID` —
  `63c1d68768bb35d40aa524aef74c2d4c`.

`frontend/wrangler.jsonc`:
```json
{
  "name": "portalpoint",
  "compatibility_date": "2026-08-28",
  "assets": { "directory": "./dist" }
}
```

## Data state — full parity, verified

The VM has **every real table**, row-count-verified against RDS
(`scripts/selfhost/lift_and_shift_vm.py`, run in 15 batches of 25 schools
each to stay within manageable ~1-2h chunks against the bandwidth-capped SSM
tunnel — see below). Final comparison: every real table's row count matches
RDS exactly. 33GB used on the VM's 200GB volume.

**Excluded on purpose, not gaps:**
- `pt_staging_*` (9 tables) — ephemeral scratch/materialized tables from the
  playing-time pipeline's internal CTEs. Not created by any alembic
  migration, not read by any live API route.
- `alembic_version` — managed by alembic itself, not copied data.

**Two real bugs hit and fixed during the migration, worth knowing about if
repeating this:**
1. A NULL-value bug: the batching script unions `DISTINCT school_id` across
   the 5 giant tables and discards `NULL` before building batches — which
   silently skipped `player_projections`' **neutral-mode rows** entirely
   (that table's `school_id` is nullable by design, split via two partial
   unique indexes for neutral vs. destination-mode dedup). Caught by a
   final full row-count audit (94,128-row gap), fixed with a supplemental
   copy pass filtered to `WHERE school_id IS NULL`.
2. Both the RDS-tunnel connection and the target connection can drop
   mid-run (SSM tunnel idle timeout, or the target just closing). Fixed by
   opening a **fresh connection on both sides for every single table copy**
   rather than one long-lived connection for the whole run — a drop then
   costs at most one table's retry, not the whole batch.

**Reusable script:** `scripts/selfhost/lift_and_shift_vm.py` —
`python lift_and_shift_vm.py phase1` (full copy of all small/reference
tables) then `python lift_and_shift_vm.py batch N` for N in
`0..(total_batches-1)` (the 5 giant ML-output tables, batched by school_id).
Every table copy is an anti-join on `id` against what the target already
has, so batches — and reruns of the same batch after a connection drop —
are naturally idempotent/resumable.

## Reaching RDS (only needed to copy more data over, e.g. after a fresh
## production run on the AWS side)

Requires the SSM tunnel (see root `CLAUDE.md`'s "RDS Access via SSM Bastion
Tunnel" section) — the `--parameters` flag must use `file://ssm-tunnel-params.json`
(repo root) rather than an inline JSON string; PowerShell mangles the quotes
on inline JSON when calling the `aws` binary directly.

```powershell
aws ssm start-session --profile default `
  --target i-0a6e1bafc1cb6f379 `
  --document-name AWS-StartPortForwardingSessionToRemoteHost `
  --parameters file://ssm-tunnel-params.json
```

Note: the `portalpoint-infra`/`portalpoint-dev` named profiles were both
found to have expired/invalid credentials during setup — `default` turned
out to already be logged into the correct infra account (`424056758764`,
root user) via `aws login`. Worth confirming which profile is actually live
before assuming a fresh key is needed from Justin.

The tunnel dropped multiple times during the full lift-and-shift (idle
timeout, most likely) — this is normal for a long session; just reopen it
and rerun whatever batch failed (safe to rerun, see above).

## Known open items — read before fully cutting over from AWS

- **No backups configured yet.** `scripts/selfhost/backup_cron.sh` exists
  (pg_dump + rotation + optional off-site push) but is **not installed** as
  an actual cron job on the VM. RDS had automated backups; this VM
  currently has none — a VM failure or an errant `DROP`/`DELETE` right now
  means real, permanent data loss with no recovery path. **This is the one
  thing to fix before treating this stack as AWS's real replacement,** not
  just a proof-of-concept.
- **Postgres has no TLS.** Connections between Render and the VM are plain,
  unencrypted TCP — a real (if minor, for this data) gap vs. RDS's enforced
  TLS.
- **Postgres port 5432 is open to `0.0.0.0/0`.** Mitigated only by password
  strength (Render has no static egress IP to scope the Security List
  rule down to).
- **No monitoring/alerting on the VM.** RDS/ECS had a CloudWatch alarm; a VM
  outage here currently has no automatic notification.
- **No automatic OS/security patching.** Self-managed maintenance burden
  that RDS/ECS/Render/Cloudflare/Upstash/B2 all handle for their piece;
  this VM is the one part of the stack that's now fully on you.
- Render free-tier cold start (~30-50s after ~15min idle) — accepted
  tradeoff of this path, not a bug.
- Alembic migrations are manual (Pre-Deploy Command locked on free tier).
- `CORS_ORIGINS` on Render must include the live frontend origin exactly
  (`https://portalpoint.shanthg01.workers.dev`) or the browser blocks API
  calls with no server-side error to point at.
- AWS stack is untouched and still the system of record — nothing here
  reduces the AWS bill until an explicit decision to cut over and
  decommission ECS/RDS/ElastiCache/ALB/CloudFront/S3.
- Full UI click-through (recommendations, comparison, projections,
  shortlist, settings pages) has not been exhaustively re-verified against
  this stack — signup, player search, and the core health/ready checks are
  confirmed live; the rest is very likely fine (same backend code, same
  schema, real data) but hasn't been individually clicked through.

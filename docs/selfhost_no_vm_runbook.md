# Self-Hosted (No-VM, Zero-Cost) Stack — Runbook

Dual-hosted alongside the AWS production stack (ECS/RDS/ElastiCache/S3/CloudFront,
see `docs/road_to_production.md`). This doc covers the free-tier, no-VM
replacement: separate managed services instead of AWS, no server to patch or
pay for. AWS is untouched by anything here and remains the system of record
until an explicit decision to cut over.

**Live URLs:**
- Frontend: https://portalpoint.shanthg01.workers.dev
- Backend: https://portalpoint.onrender.com (`/health`, `/ready`, `/docs`)

## Architecture

| Piece | Provider | Replaces (AWS) |
|---|---|---|
| Postgres + pgvector | Neon | RDS |
| Redis | Upstash | ElastiCache |
| Object storage (MLflow artifacts, hoopR raw parquet) | Backblaze B2 (S3-compatible) | S3 |
| Backend (FastAPI container) | Render (free Web Service) | ECS Fargate + ALB |
| Frontend (static React build) | Cloudflare Workers (static assets) | S3 + CloudFront |

No VM anywhere in this path — each piece is a separate managed free-tier
service. Tradeoff vs. a VM: Render's free tier spins down after ~15min idle
(~30-50s cold start on the next request); everything else has no such
penalty since it isn't a continuously-running process.

## Credentials

All real connection strings/keys live in:
- Local `.env` (gitignored, never committed) — for anyone running scripts
  locally against this stack.
- Render's dashboard env vars (Environment tab) — for the running backend.
- GitHub repo secrets (Settings → Secrets and variables → Actions) — for the
  two deploy workflows below.

Nothing here is duplicated into any tracked repo file. If a value below is
shown as `<get from wherever you stored it>`, that's deliberate.

## Backend (Render)

**Redeploy:** automatic — Render's own git integration triggers on every
push to `main` (`autoDeploy: yes`, confirmed via the Workers... er, Render
API). No GitHub Actions workflow needed for this half.

**Env vars set on the Render service** (Environment tab):
```
DATABASE_URL=postgresql+asyncpg://neondb_owner:<password>@<neon-pooler-host>/neondb?ssl=require
REDIS_URL=rediss://default:<password>@<upstash-host>:6379
JWT_SECRET=<random>
JWT_ALGORITHM=HS256
JWT_EXPIRY_SECONDS=3600
ENVIRONMENT=production
CORS_ORIGINS=https://portalpoint.shanthg01.workers.dev http://localhost:3000 http://localhost:5173
MLFLOW_TRACKING_URI=postgresql+psycopg2://neondb_owner:<password>@<neon-pooler-host>/neondb?sslmode=require&channel_binding=require
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
run manually against Neon before or right after the next deploy:
```bash
DATABASE_URL="postgresql+asyncpg://neondb_owner:<password>@<neon-pooler-host>/neondb?ssl=require" \
  uv run alembic upgrade head
```
Alembic's `env.py` uses the async engine directly — use the `+asyncpg` form
with `?ssl=require`, not the psycopg2 form, for this specific command.

**Programmatic access:** Render has a REST API (`api.render.com`) for
reading/writing env vars and triggering deploys — used during initial setup,
requires a Render API key (Account Settings → API Keys). Not wired into any
GitHub workflow; env var changes were applied ad hoc during setup.

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
once during initial setup; the stray worker was deleted by hand. `frontend/wrangler.jsonc`
has no `env` section on purpose — leave it that way, or add a matching
`[env.production]` block first if `--env` is ever genuinely needed.

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

## Data state on Neon — IMPORTANT, partial only

Neon currently has the **full schema** (43 tables, `alembic upgrade head`
applied) but only **one table's real data**: `schools` (400 rows, copied
from RDS — needed because signup validates `school_id` against it). Every
other table is empty. Expect empty search results, empty recommendations,
empty fit scores until/unless more data is copied over.

**A full lift-and-shift was deliberately NOT done.** Known real row counts
from the AWS side (`player_team_fit_scores` ~9.7M rows, `team_rating_projections`
457K, `transfer_success_scores` 456K, `player_projections` destination-mode
454K, `hoopr_player_game_logs` 1.17M, etc.) very likely exceed Neon's free
tier storage cap. If more data is needed later:
- **Partial/representative copy** (recommended) — a season slice or a
  handful of core tables, same pattern used for `schools`: connect to RDS
  via the SSM tunnel with `asyncpg`, connect to Neon, `copy_records_to_table`.
- **Full copy** — possible via `scripts/selfhost/migrate_db.sh` (built for
  the earlier VM-based path, works against any Postgres target including
  Neon's direct/pooler hostname), but real risk of hitting the storage cap
  mid-restore.

## Reaching RDS (only needed to copy more data over)

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

## Known open items

- Render free-tier cold start (~30-50s after ~15min idle) — accepted
  tradeoff of this path, not a bug.
- Alembic migrations are manual (Pre-Deploy Command locked on free tier).
- Only `schools` table has real data on Neon — see above.
- `CORS_ORIGINS` on Render must include the live frontend origin exactly
  (`https://portalpoint.shanthg01.workers.dev`) or the browser blocks API
  calls with no server-side error to point at.
- AWS stack is untouched and still the system of record — nothing here
  reduces the AWS bill until an explicit decision to cut over and
  decommission ECS/RDS/ElastiCache/ALB/CloudFront/S3.

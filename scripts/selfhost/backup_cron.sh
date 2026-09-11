#!/usr/bin/env bash
#
# backup_cron.sh — ongoing scheduled backup of the self-hosted Postgres, meant to be installed
# as a cron job on the self-host VM.
#
# CRONTAB EXAMPLE (daily at 3am, matching CLAUDE.md's existing "weekly_model_training_dag"-style
# 3 AM convention, log appended for later inspection):
#
#   0 3 * * * /path/to/backup_cron.sh >> /var/log/portalpoint-backup.log 2>&1
#
# All configuration is via environment variables — set them in the crontab entry itself, in
# a wrapper script that `source`s an env file before calling this, or in /etc/environment /
# the cron user's own environment. This script does not read a hardcoded .env file.
#
# WHAT THIS DOES
#   1. `pg_dump -Fc` the self-hosted Postgres DB, into a timestamped file in $BACKUP_DIR.
#   2. Retention: keeps the last $BACKUP_RETAIN_COUNT dumps in $BACKUP_DIR (default 7),
#      deletes older ones.
#   3. Off-site push (optional): if the BACKUP_REMOTE_* vars below are all set, uses `mc`
#      (the MinIO client — already a required dependency elsewhere in this stack, so no new
#      tooling) to push the just-created dump to a configurable S3-compatible off-site
#      endpoint (e.g. Backblaze B2's S3-compatible API, or another MinIO/S3-compatible
#      target). If any BACKUP_REMOTE_* var is unset, the off-site push is skipped and this is
#      logged clearly — it is NOT a fatal error, local-only backup still counts as success.
#   4. Remote retention (only runs if step 3 ran): same "keep last N, delete older" policy as
#      step 2, applied to the off-site bucket via $BACKUP_REMOTE_RETAIN_COUNT — without this,
#      off-site storage grows forever since step 3 only ever adds objects.
#
# REQUIRED ENV VARS (self-hosted Postgres connection to back up)
#   SELFHOST_DB_NAME        Database name
#   SELFHOST_DB_USER        Database user
#   SELFHOST_DB_PASSWORD    Database password
#
# OPTIONAL ENV VARS (self-hosted Postgres connection)
#   SELFHOST_DB_HOST        Default: localhost
#   SELFHOST_DB_PORT        Default: 5432
#
# OPTIONAL ENV VARS (local backup behavior)
#   BACKUP_DIR              Local directory dumps are written to. Default: ./backups
#   BACKUP_RETAIN_COUNT     Number of most-recent dumps to keep locally. Default: 7
#
# OPTIONAL ENV VARS (off-site push — ALL of the following must be set to enable it; if any
# one is missing, the off-site push step is skipped and this is logged, not treated as an error)
#   BACKUP_REMOTE_ENDPOINT       Off-site S3-compatible endpoint URL, e.g.
#                                "https://s3.us-west-002.backblazeb2.com" (Backblaze B2) or
#                                "https://minio.example.com" (another MinIO/S3-compatible host).
#                                THIS SCRIPT HAS NO DEFAULT/HARDCODED ENDPOINT — placeholder only.
#   BACKUP_REMOTE_BUCKET         Off-site bucket name to push dumps into.
#   BACKUP_REMOTE_ACCESS_KEY     Off-site access key ID.
#   BACKUP_REMOTE_SECRET_KEY     Off-site secret access key.
#   BACKUP_REMOTE_MC_ALIAS       Local `mc` alias name to register for the off-site target.
#                                Default: offsite
#   BACKUP_REMOTE_RETAIN_COUNT   Number of most-recent dumps to keep in the off-site bucket,
#                                same "keep last N, delete older" policy as BACKUP_RETAIN_COUNT
#                                but applied remotely. Default: 3 -- deliberately lower than the
#                                local default (7). Real incident (2026-09-11): with no remote
#                                retention at all, 4 uncleaned dumps at ~2.57GB each already
#                                exceeded Backblaze B2's 10GB free tier after only 2 days of the
#                                nightly cron running. At 3 retained (~7.7GB at today's dump
#                                size), there's headroom for the DB to grow before hitting the
#                                cap again -- lower this further (or raise it if paying for
#                                storage) if the dump size grows materially.
#
# FLAGS
#   -h, --help              Print this help and exit 0.
#
# EXAMPLE (local-only backup, no off-site push — BACKUP_REMOTE_* all left unset)
#   SELFHOST_DB_NAME=portalpoint SELFHOST_DB_USER=portalpoint_app SELFHOST_DB_PASSWORD=*** \
#   BACKUP_DIR=/var/backups/portalpoint \
#     ./backup_cron.sh
#
# EXAMPLE (with off-site push to Backblaze B2)
#   SELFHOST_DB_NAME=portalpoint SELFHOST_DB_USER=portalpoint_app SELFHOST_DB_PASSWORD=*** \
#   BACKUP_DIR=/var/backups/portalpoint \
#   BACKUP_REMOTE_ENDPOINT=https://s3.us-west-002.backblazeb2.com \
#   BACKUP_REMOTE_BUCKET=portalpoint-offsite-backups \
#   BACKUP_REMOTE_ACCESS_KEY=*** \
#   BACKUP_REMOTE_SECRET_KEY=*** \
#     ./backup_cron.sh
#
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Run '${SCRIPT_NAME} --help' for usage." >&2
      exit 1
      ;;
  esac
done

# ---- apply defaults, then fail fast on anything still unset (required vars only) -----------
SELFHOST_DB_HOST="${SELFHOST_DB_HOST:-localhost}"
SELFHOST_DB_PORT="${SELFHOST_DB_PORT:-5432}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_RETAIN_COUNT="${BACKUP_RETAIN_COUNT:-7}"
BACKUP_REMOTE_MC_ALIAS="${BACKUP_REMOTE_MC_ALIAS:-offsite}"
BACKUP_REMOTE_RETAIN_COUNT="${BACKUP_REMOTE_RETAIN_COUNT:-3}"

missing=()
for var in SELFHOST_DB_NAME SELFHOST_DB_USER SELFHOST_DB_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("$var")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required environment variable(s): ${missing[*]}" >&2
  echo "Run '${SCRIPT_NAME} --help' for the full list of required/optional env vars." >&2
  exit 1
fi

if ! [[ "$BACKUP_RETAIN_COUNT" =~ ^[0-9]+$ ]] || [[ "$BACKUP_RETAIN_COUNT" -lt 1 ]]; then
  echo "ERROR: BACKUP_RETAIN_COUNT must be a positive integer (got '${BACKUP_RETAIN_COUNT}')." >&2
  exit 1
fi

if ! [[ "$BACKUP_REMOTE_RETAIN_COUNT" =~ ^[0-9]+$ ]] || [[ "$BACKUP_REMOTE_RETAIN_COUNT" -lt 1 ]]; then
  echo "ERROR: BACKUP_REMOTE_RETAIN_COUNT must be a positive integer (got '${BACKUP_REMOTE_RETAIN_COUNT}')." >&2
  exit 1
fi

for cmd in pg_dump; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found on PATH (install postgresql-client)." >&2
    exit 1
  fi
done

log() {
  echo "[backup_cron] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# ---- step 1: dump ----------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/portalpoint_${TIMESTAMP}.dump"

log "Dumping self-hosted DB '${SELFHOST_DB_NAME}' at ${SELFHOST_DB_HOST}:${SELFHOST_DB_PORT} -> ${DUMP_FILE}"
PGPASSWORD="$SELFHOST_DB_PASSWORD" pg_dump \
  -h "$SELFHOST_DB_HOST" \
  -p "$SELFHOST_DB_PORT" \
  -U "$SELFHOST_DB_USER" \
  -d "$SELFHOST_DB_NAME" \
  -Fc \
  -f "$DUMP_FILE"

DUMP_SIZE_HUMAN="$(du -h "$DUMP_FILE" | cut -f1)"
log "Dump complete: ${DUMP_FILE} (${DUMP_SIZE_HUMAN})"

# ---- step 2: retention — keep the last N dumps, delete older ones ---------------------------
log "Applying retention policy: keep last ${BACKUP_RETAIN_COUNT} dump(s) in ${BACKUP_DIR}"
# Sort by filename (timestamp-sortable: portalpoint_YYYYMMDD_HHMMSS.dump), newest last.
mapfile -t all_dumps < <(find "$BACKUP_DIR" -maxdepth 1 -name 'portalpoint_*.dump' -type f | sort)
total_dumps="${#all_dumps[@]}"

if [[ "$total_dumps" -gt "$BACKUP_RETAIN_COUNT" ]]; then
  num_to_delete=$((total_dumps - BACKUP_RETAIN_COUNT))
  log "Found ${total_dumps} dump(s), deleting ${num_to_delete} oldest to retain ${BACKUP_RETAIN_COUNT}."
  for ((i = 0; i < num_to_delete; i++)); do
    log "Deleting old backup: ${all_dumps[$i]}"
    rm -f "${all_dumps[$i]}"
  done
else
  log "Found ${total_dumps} dump(s), within retention limit of ${BACKUP_RETAIN_COUNT}. Nothing deleted."
fi

# ---- step 3: optional off-site push -----------------------------------------------------------
remote_missing=()
for var in BACKUP_REMOTE_ENDPOINT BACKUP_REMOTE_BUCKET BACKUP_REMOTE_ACCESS_KEY BACKUP_REMOTE_SECRET_KEY; do
  if [[ -z "${!var:-}" ]]; then
    remote_missing+=("$var")
  fi
done

if [[ ${#remote_missing[@]} -gt 0 ]]; then
  log "Off-site push skipped — not all BACKUP_REMOTE_* vars are set (missing: ${remote_missing[*]})."
  log "Local-only backup completed successfully: ${DUMP_FILE}"
  exit 0
fi

if ! command -v mc >/dev/null 2>&1; then
  log "WARNING: BACKUP_REMOTE_* vars are set but 'mc' (MinIO client) is not on PATH."
  log "Off-site push skipped. Local-only backup completed successfully: ${DUMP_FILE}"
  exit 0
fi

log "Off-site push enabled — registering mc alias '${BACKUP_REMOTE_MC_ALIAS}' -> ${BACKUP_REMOTE_ENDPOINT}"
mc alias set "$BACKUP_REMOTE_MC_ALIAS" "$BACKUP_REMOTE_ENDPOINT" "$BACKUP_REMOTE_ACCESS_KEY" "$BACKUP_REMOTE_SECRET_KEY"

log "Pushing ${DUMP_FILE} -> ${BACKUP_REMOTE_MC_ALIAS}/${BACKUP_REMOTE_BUCKET}/"
mc cp "$DUMP_FILE" "${BACKUP_REMOTE_MC_ALIAS}/${BACKUP_REMOTE_BUCKET}/"

# ---- step 4: remote retention — keep the last N dumps off-site, delete older ones ------------
# `mc cp` above only ever adds objects — with no cleanup here, off-site storage grows forever.
# Real incident (2026-09-11): 4 unpruned dumps at ~2.57GB each already exceeded Backblaze B2's
# 10GB free tier after 2 days of the nightly cron running, since only local retention existed.
log "Applying remote retention policy: keep last ${BACKUP_REMOTE_RETAIN_COUNT} dump(s) in ${BACKUP_REMOTE_MC_ALIAS}/${BACKUP_REMOTE_BUCKET}"
mapfile -t remote_dumps < <(mc find "${BACKUP_REMOTE_MC_ALIAS}/${BACKUP_REMOTE_BUCKET}/" \
  --name 'portalpoint_*.dump' 2>/dev/null | sort)
total_remote_dumps="${#remote_dumps[@]}"

if [[ "$total_remote_dumps" -gt "$BACKUP_REMOTE_RETAIN_COUNT" ]]; then
  num_to_delete=$((total_remote_dumps - BACKUP_REMOTE_RETAIN_COUNT))
  log "Found ${total_remote_dumps} remote dump(s), deleting ${num_to_delete} oldest to retain ${BACKUP_REMOTE_RETAIN_COUNT}."
  for ((i = 0; i < num_to_delete; i++)); do
    log "Deleting old off-site backup: ${remote_dumps[$i]}"
    mc rm "${remote_dumps[$i]}"
  done
else
  log "Found ${total_remote_dumps} remote dump(s), within retention limit of ${BACKUP_REMOTE_RETAIN_COUNT}. Nothing deleted."
fi

log "Off-site push complete. Backup finished: ${DUMP_FILE}"

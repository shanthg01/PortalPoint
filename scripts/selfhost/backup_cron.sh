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
#   3. Off-site push (optional, only if the BACKUP_REMOTE_* vars below are all set): prunes the
#      off-site bucket DOWN TO $BACKUP_REMOTE_RETAIN_COUNT-1 dumps FIRST (making room), then
#      uses `mc` (the MinIO client — already a required dependency elsewhere in this stack) to
#      push the just-created dump, then prunes back down to $BACKUP_REMOTE_RETAIN_COUNT as a
#      safety net. Pruning before the push, not just after, matters: a provider that rejects
#      writes once a storage quota is hit (e.g. Backblaze B2's free 10GB tier) would otherwise
#      deadlock — the push that's supposed to trigger cleanup never completes, so cleanup never
#      runs either. This happened for real (2026-09-11) and had been silently failing every
#      night for a week before anyone noticed. If any BACKUP_REMOTE_* var is unset, the whole
#      off-site step is skipped and this is logged clearly — it is NOT a fatal error, local-only
#      backup still counts as success.
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
#   BACKUP_REMOTE_RETAIN_COUNT   Number of most-recent dumps to keep in the off-site bucket (min 2),
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

# Minimum 2, not 1: the pre-push prune (step 4a) trims to RETAIN_COUNT-1 *before* uploading,
# so a value of 1 would delete the only off-site dump before the new one is safely stored --
# a failed upload would then leave nothing off-site at all.
if ! [[ "$BACKUP_REMOTE_RETAIN_COUNT" =~ ^[0-9]+$ ]] || [[ "$BACKUP_REMOTE_RETAIN_COUNT" -lt 2 ]]; then
  echo "ERROR: BACKUP_REMOTE_RETAIN_COUNT must be an integer >= 2 (got '${BACKUP_REMOTE_RETAIN_COUNT}')." >&2
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

prune_remote_dumps() {
  # Prunes down to $1 remaining objects (oldest deleted first). Used both
  # before and after the push -- see the real deadlock this fixes, below.
  local keep="$1"
  mapfile -t remote_dumps < <(mc find "${BACKUP_REMOTE_MC_ALIAS}/${BACKUP_REMOTE_BUCKET}/" \
    --name 'portalpoint_*.dump' 2>/dev/null | sort)
  local total_remote_dumps="${#remote_dumps[@]}"
  if [[ "$total_remote_dumps" -gt "$keep" ]]; then
    local num_to_delete=$((total_remote_dumps - keep))
    log "Found ${total_remote_dumps} remote dump(s), deleting ${num_to_delete} oldest to retain ${keep}."
    for ((i = 0; i < num_to_delete; i++)); do
      log "Deleting old off-site backup (all versions): ${remote_dumps[$i]}"
      # --versions --force: a plain `mc rm` on a versioned bucket (Backblaze B2's default
      # "keep all versions") only adds a delete marker -- the old version stays stored and
      # keeps counting toward the storage cap. Real incident: hidden dumps filled the 10GB
      # free tier and every upload from 2026-09-14 to 2026-09-30 failed with
      # "storage cap exceeded" even though only 5GB of dumps were visible.
      mc rm --versions --force "${remote_dumps[$i]}"
    done
  else
    log "Found ${total_remote_dumps} remote dump(s), within limit of ${keep}. Nothing deleted."
  fi
}

# ---- step 4a: prune remote BEFORE pushing, down to RETAIN_COUNT-1 -----------------------------
# Real incident (2026-09-11): pruning only *after* the push (the original order) is a deadlock
# once the bucket is at/near quota -- Backblaze B2 rejects a write that would exceed the free
# 10GB tier, so the push that was supposed to trigger cleanup never completes, and cleanup
# never runs either. This had been silently failing every night for a week (confirmed: local
# dumps existed for every night, but the off-site bucket only had the last few pre-quota
# ones) since nothing surfaces a failed `mc cp` unless someone reads the cron log. Pruning
# down to one slot below the limit *first* guarantees there's always room for the new dump.
log "Pre-push remote retention: making room for the new dump"
prune_remote_dumps "$((BACKUP_REMOTE_RETAIN_COUNT - 1))"

log "Pushing ${DUMP_FILE} -> ${BACKUP_REMOTE_MC_ALIAS}/${BACKUP_REMOTE_BUCKET}/"
mc cp "$DUMP_FILE" "${BACKUP_REMOTE_MC_ALIAS}/${BACKUP_REMOTE_BUCKET}/"

# ---- step 4b: safety-net prune AFTER pushing, back down to RETAIN_COUNT -----------------------
# Should be a no-op given step 4a already made exactly one slot of room -- kept as a cheap
# second pass in case of concurrent runs, a manually-added object, or a changed retain count.
prune_remote_dumps "$BACKUP_REMOTE_RETAIN_COUNT"

log "Off-site push complete. Backup finished: ${DUMP_FILE}"

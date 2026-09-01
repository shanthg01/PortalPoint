#!/usr/bin/env bash
#
# migrate_db.sh — one-shot Postgres migration: RDS (via SSM tunnel) -> self-hosted Postgres.
#
# *** TOOL ONLY. This script performs a real, hard-to-reverse database restore when run
# *** without --dry-run. A --force restore DROPS/OVERWRITES data in the target database.
# *** Do not run this against the real production RDS DB or a real target DB except at the
# *** planned cutover window, and only by hand, deliberately.
#
# WHAT THIS DOES
#   1. Dumps the source Postgres DB (the live RDS instance, reached through the already-open
#      SSM Session Manager tunnel documented in CLAUDE.md's "RDS Access via SSM Bastion Tunnel"
#      section) using `pg_dump -Fc` (custom format: compressed, supports parallel restore).
#   2. (unless --dry-run) Restores that dump into a self-hosted Postgres container using
#      `pg_restore`.
#
# TUNNEL ASSUMPTION
#   This script does NOT open the SSM tunnel for you. Per CLAUDE.md, you must already have run:
#     aws ssm start-session --profile portalpoint-infra \
#       --target i-0a6e1bafc1cb6f379 \
#       --document-name AWS-StartPortForwardingSessionToRemoteHost \
#       --parameters '{"host":["portalpoint-db.con8amymqi1e.us-east-1.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5433"]}'
#   in a separate terminal window (it blocks; keep it open for the duration of this script).
#   This script only CHECKS that something is listening on the source port and fails with a
#   clear pointer back to CLAUDE.md if it isn't — it never attempts to start the tunnel itself.
#
# WHERE TO RUN THIS FROM
#   Either works, your choice:
#     (a) On the new self-host VM itself, after copying the dump file over (run with
#         --dry-run first elsewhere or here to produce the .dump file, scp it over, then
#         run the restore-only path — see --dump-file below).
#     (b) From any single machine that can reach BOTH the SSM tunnel's localhost:5433 (source)
#         AND the new self-hosted Postgres host:port (target) — e.g. your laptop during the
#         tunnel session, doing dump + restore in one invocation.
#
# REQUIRED ENV VARS
#   Source (RDS, reached through the SSM tunnel — NOT the RDS hostname directly):
#     SOURCE_DB_NAME       Source database name
#     SOURCE_DB_USER       Source database user
#     SOURCE_DB_PASSWORD   Source database password
#   Optional (source), sensible tunnel defaults:
#     SOURCE_DB_HOST       Default: 127.0.0.1
#     SOURCE_DB_PORT       Default: 5433  (the SSM tunnel's local forwarded port)
#
#   Target (new self-hosted Postgres container):
#     SELFHOST_DB_NAME     Target database name
#     SELFHOST_DB_USER     Target database user
#     SELFHOST_DB_PASSWORD Target database password
#   Optional (target), sensible container defaults:
#     SELFHOST_DB_HOST     Default: localhost
#     SELFHOST_DB_PORT     Default: 5432
#
#   Optional (behavior):
#     RESTORE_JOBS         Parallel pg_restore jobs. Default: 4
#
# FLAGS
#   --dry-run            Dump only. No restore attempted. Prints dump file size and a
#                         pg_restore --list summary (table count in the dump) plus a live
#                         psql table-count check against the source DB for comparison.
#   --force               Required to restore into a target database that is not empty.
#                          Without it, a non-empty target aborts the restore before touching
#                          anything.
#   --dump-file PATH       Use an existing dump file instead of dumping the source now (useful
#                          on the target VM once the dump has been scp'd over). Skips the dump
#                          step and the source-tunnel check entirely.
#   -h, --help             Print this help and exit 0.
#
# EXAMPLES
#   # Dry run: dump only, sanity-check it, no restore.
#   SOURCE_DB_NAME=portalpoint SOURCE_DB_USER=portalpoint_app SOURCE_DB_PASSWORD=*** \
#     ./migrate_db.sh --dry-run
#
#   # Full dump + restore in one shot (source and target both reachable from this machine),
#   # refusing to touch a non-empty target:
#   SOURCE_DB_NAME=portalpoint SOURCE_DB_USER=portalpoint_app SOURCE_DB_PASSWORD=*** \
#   SELFHOST_DB_NAME=portalpoint SELFHOST_DB_USER=portalpoint_app SELFHOST_DB_PASSWORD=*** \
#     ./migrate_db.sh
#
#   # Restore a dump already copied to the target VM, overwriting an existing target DB:
#   SELFHOST_DB_NAME=portalpoint SELFHOST_DB_USER=portalpoint_app SELFHOST_DB_PASSWORD=*** \
#     ./migrate_db.sh --dump-file /path/to/portalpoint_20260901_120000.dump --force
#
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
  # Print everything above between the shebang and "set -euo pipefail" — i.e. this header.
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# ---- parse args first, so --help works with zero env vars set ------------------------------
DRY_RUN=0
FORCE=0
DUMP_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --dump-file)
      DUMP_FILE="${2:-}"
      if [[ -z "$DUMP_FILE" ]]; then
        echo "ERROR: --dump-file requires a path argument" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Run '${SCRIPT_NAME} --help' for usage." >&2
      exit 1
      ;;
  esac
done

if [[ $DRY_RUN -eq 1 && -n "$DUMP_FILE" ]]; then
  echo "ERROR: --dry-run and --dump-file are mutually exclusive (--dump-file skips dumping)." >&2
  exit 1
fi

# ---- apply defaults, then fail fast on anything still unset --------------------------------
SOURCE_DB_HOST="${SOURCE_DB_HOST:-127.0.0.1}"
SOURCE_DB_PORT="${SOURCE_DB_PORT:-5433}"
SELFHOST_DB_HOST="${SELFHOST_DB_HOST:-localhost}"
SELFHOST_DB_PORT="${SELFHOST_DB_PORT:-5432}"
RESTORE_JOBS="${RESTORE_JOBS:-4}"

missing=()

# Source DB vars are only required when we're actually going to dump (i.e. no --dump-file given).
if [[ -z "$DUMP_FILE" ]]; then
  for var in SOURCE_DB_NAME SOURCE_DB_USER SOURCE_DB_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
fi

# Target DB vars are only required when we're actually going to restore (i.e. not --dry-run).
if [[ $DRY_RUN -eq 0 ]]; then
  for var in SELFHOST_DB_NAME SELFHOST_DB_USER SELFHOST_DB_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required environment variable(s): ${missing[*]}" >&2
  echo "Run '${SCRIPT_NAME} --help' for the full list of required/optional env vars." >&2
  exit 1
fi

for cmd in pg_dump pg_restore psql; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found on PATH (install postgresql-client)." >&2
    exit 1
  fi
done

# ---- helpers --------------------------------------------------------------------------------
log() {
  echo "[migrate_db] $*"
}

warn() {
  echo "[migrate_db] WARNING: $*" >&2
}

check_port_listening() {
  local host="$1" port="$2"
  # Portable TCP connect check using bash's /dev/tcp pseudo-device; times out in 3s.
  if timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ---- step 1: verify source tunnel is open (unless restoring from an existing dump file) ----
if [[ -z "$DUMP_FILE" ]]; then
  log "Checking source connection at ${SOURCE_DB_HOST}:${SOURCE_DB_PORT} ..."
  if ! check_port_listening "$SOURCE_DB_HOST" "$SOURCE_DB_PORT"; then
    cat >&2 <<EOF
ERROR: nothing is listening on ${SOURCE_DB_HOST}:${SOURCE_DB_PORT}.

This script assumes the SSM Session Manager port-forward tunnel to RDS is ALREADY OPEN,
per CLAUDE.md's "RDS Access via SSM Bastion Tunnel" section. It does not open the tunnel
for you. In a separate terminal, run:

  aws ssm start-session --profile portalpoint-infra \\
    --target i-0a6e1bafc1cb6f379 \\
    --document-name AWS-StartPortForwardingSessionToRemoteHost \\
    --parameters '{"host":["portalpoint-db.con8amymqi1e.us-east-1.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5433"]}'

... and leave it running, then re-run this script.
EOF
    exit 1
  fi
  log "Source connection OK."
fi

# ---- step 2: dump (unless an existing dump file was supplied) ------------------------------
if [[ -n "$DUMP_FILE" ]]; then
  log "Using existing dump file: ${DUMP_FILE}"
  if [[ ! -f "$DUMP_FILE" ]]; then
    echo "ERROR: --dump-file path does not exist: ${DUMP_FILE}" >&2
    exit 1
  fi
else
  DUMP_FILE="portalpoint_$(date +%Y%m%d_%H%M%S).dump"
  log "Dumping source DB '${SOURCE_DB_NAME}' from ${SOURCE_DB_HOST}:${SOURCE_DB_PORT} -> ${DUMP_FILE}"
  PGPASSWORD="$SOURCE_DB_PASSWORD" pg_dump \
    -h "$SOURCE_DB_HOST" \
    -p "$SOURCE_DB_PORT" \
    -U "$SOURCE_DB_USER" \
    -d "$SOURCE_DB_NAME" \
    -Fc \
    -f "$DUMP_FILE"
  log "Dump complete: ${DUMP_FILE}"
fi

DUMP_SIZE_HUMAN="$(du -h "$DUMP_FILE" | cut -f1)"
DUMP_TABLE_COUNT="$(pg_restore --list "$DUMP_FILE" | grep -c 'TABLE DATA' || true)"

log "Dump file size: ${DUMP_SIZE_HUMAN}"
log "Dump contains ${DUMP_TABLE_COUNT} TABLE DATA entries (per 'pg_restore --list')."

# ---- step 3: dry-run stops here, with an extra sanity check against the live source ---------
if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry run requested — comparing against a live table count on the source DB..."
  SOURCE_TABLE_COUNT="$(PGPASSWORD="$SOURCE_DB_PASSWORD" psql \
    -h "$SOURCE_DB_HOST" -p "$SOURCE_DB_PORT" -U "$SOURCE_DB_USER" -d "$SOURCE_DB_NAME" \
    -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" || echo "unknown")"
  log "Source DB reports ${SOURCE_TABLE_COUNT} tables in the public schema (live psql check)."
  log "--dry-run complete. No restore was attempted. Dump file left at: ${DUMP_FILE}"
  exit 0
fi

# ---- step 4: check whether the target DB is empty, refuse to clobber without --force --------
log "Checking target DB '${SELFHOST_DB_NAME}' at ${SELFHOST_DB_HOST}:${SELFHOST_DB_PORT} ..."
TARGET_TABLE_COUNT="$(PGPASSWORD="$SELFHOST_DB_PASSWORD" psql \
  -h "$SELFHOST_DB_HOST" -p "$SELFHOST_DB_PORT" -U "$SELFHOST_DB_USER" -d "$SELFHOST_DB_NAME" \
  -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")"
TARGET_TABLE_COUNT="$(echo "$TARGET_TABLE_COUNT" | tr -d '[:space:]')"

warn "About to restore into ${SELFHOST_DB_HOST}:${SELFHOST_DB_PORT}/${SELFHOST_DB_NAME}."
warn "This target currently has ${TARGET_TABLE_COUNT} table(s) in its public schema."
warn "pg_restore will run with --clean --if-exists, which DROPS existing objects with the"
warn "same name before recreating them from the dump. Any data in this target not present"
warn "in the dump, or any data you care about in tables the dump will overwrite, WILL BE LOST."

if [[ "$TARGET_TABLE_COUNT" != "0" && $FORCE -eq 0 ]]; then
  echo "ERROR: target database is not empty (${TARGET_TABLE_COUNT} tables) and --force was not passed." >&2
  echo "Refusing to restore. Re-run with --force if you really intend to overwrite it." >&2
  exit 1
fi

if [[ $FORCE -eq 1 ]]; then
  warn "--force was passed. Proceeding with restore in 5 seconds... (Ctrl+C to abort)"
  sleep 5
fi

# ---- step 5: restore -------------------------------------------------------------------------
log "Restoring ${DUMP_FILE} into ${SELFHOST_DB_HOST}:${SELFHOST_DB_PORT}/${SELFHOST_DB_NAME} (jobs=${RESTORE_JOBS})..."
PGPASSWORD="$SELFHOST_DB_PASSWORD" pg_restore \
  -h "$SELFHOST_DB_HOST" \
  -p "$SELFHOST_DB_PORT" \
  -U "$SELFHOST_DB_USER" \
  -d "$SELFHOST_DB_NAME" \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  -j "$RESTORE_JOBS" \
  "$DUMP_FILE"

log "Restore complete."

RESTORED_TABLE_COUNT="$(PGPASSWORD="$SELFHOST_DB_PASSWORD" psql \
  -h "$SELFHOST_DB_HOST" -p "$SELFHOST_DB_PORT" -U "$SELFHOST_DB_USER" -d "$SELFHOST_DB_NAME" \
  -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")"
log "Target DB now reports ${RESTORED_TABLE_COUNT} table(s) in the public schema."
log "Done. Dump file retained at: ${DUMP_FILE}"

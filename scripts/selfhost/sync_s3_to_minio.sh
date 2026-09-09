#!/usr/bin/env bash
#
# sync_s3_to_minio.sh — one-shot storage migration: real AWS S3 bucket -> self-hosted MinIO.
#
# *** TOOL ONLY. This is a real, live-credential AWS operation when run — it downloads the
# *** entire real S3 bucket to local disk and mirrors it into a real MinIO instance. Not
# *** something this session runs; the user runs it by hand at the planned cutover time.
#
# WHAT THIS DOES
#   1. `aws s3 sync s3://$S3_BUCKET <staging dir>` — pulls the ENTIRE bucket down to a local
#      staging directory using the real AWS CLI and real credentials.
#   2. `mc mb --ignore-existing` + `mc mirror <staging dir> selfhost/<bucket>` — mirrors that
#      staging directory into the new self-hosted MinIO instance's matching bucket, using the
#      MinIO client (`mc`).
#
#   NOTE: per CLAUDE.md's data pipeline description, `$S3_BUCKET` (default "portalpoint-data")
#   is used for BOTH MLflow tracking artifacts (s3://portalpoint-data/mlflow/, models/) AND raw
#   hoopR parquet files — they live under the same bucket. This single sync covers both; there
#   is no separate step needed for MLflow artifacts vs. raw parquet data.
#
# CREDENTIALS
#   AWS side: this script relies on the AMBIENT AWS CLI credential chain (env vars,
#   ~/.aws/credentials, an assumed role, etc.) rather than requiring its own AWS_ACCESS_KEY_ID/
#   AWS_SECRET_ACCESS_KEY env vars — `aws s3 sync` already knows how to resolve credentials the
#   normal way. If you need to point at a specific profile, export AWS_PROFILE before running
#   this script, or set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_DEFAULT_REGION yourself
#   (all three are read here if present, and exported to the `aws` subprocess, but none of the
#   three is required directly by this script — only that SOME valid credential source exists).
#   MinIO side: this script DOES require explicit MinIO credentials — MINIO_ROOT_USER /
#   MINIO_ROOT_PASSWORD below.
#
# REQUIRED ENV VARS
#   S3_BUCKET              Source S3 bucket name (e.g. "portalpoint-data")
#   MINIO_HOST              Hostname/IP of the self-hosted MinIO instance (no scheme, no port)
#   MINIO_ROOT_USER         MinIO root/access-key user
#   MINIO_ROOT_PASSWORD     MinIO root/secret-key password
#
# OPTIONAL ENV VARS
#   AWS_PROFILE             Named AWS CLI profile to use, if not relying on default chain
#   AWS_ACCESS_KEY_ID       Only needed if not using the ambient credential chain
#   AWS_SECRET_ACCESS_KEY   Only needed if not using the ambient credential chain
#   AWS_DEFAULT_REGION      Only needed if not using the ambient credential chain
#   MINIO_PORT              MinIO API port. Default: 9000
#   MINIO_BUCKET            Target bucket name in MinIO. Default: same as $S3_BUCKET
#   MINIO_USE_TLS           Set to "true" to use https:// against MinIO instead of http://. Default: false
#   STAGING_DIR             Local staging directory for the intermediate `aws s3 sync`.
#                           Default: ./staging-s3-sync
#   MC_ALIAS                Local `mc` alias name to register for the self-hosted MinIO.
#                           Default: selfhost
#
# FLAGS
#   -h, --help              Print this help and exit 0.
#
# EXAMPLE
#   S3_BUCKET=portalpoint-data \
#   MINIO_HOST=10.0.1.50 \
#   MINIO_ROOT_USER=minioadmin \
#   MINIO_ROOT_PASSWORD=*** \
#     ./sync_s3_to_minio.sh
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

# ---- apply defaults, then fail fast on anything still unset --------------------------------
MINIO_PORT="${MINIO_PORT:-9000}"
MINIO_BUCKET="${MINIO_BUCKET:-${S3_BUCKET:-}}"
MINIO_USE_TLS="${MINIO_USE_TLS:-false}"
STAGING_DIR="${STAGING_DIR:-./staging-s3-sync}"
MC_ALIAS="${MC_ALIAS:-selfhost}"

missing=()
for var in S3_BUCKET MINIO_HOST MINIO_ROOT_USER MINIO_ROOT_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("$var")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required environment variable(s): ${missing[*]}" >&2
  echo "Run '${SCRIPT_NAME} --help' for the full list of required/optional env vars." >&2
  exit 1
fi

for cmd in aws mc; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found on PATH." >&2
    if [[ "$cmd" == "mc" ]]; then
      echo "        Install the MinIO client: https://min.io/docs/minio/linux/reference/minio-mc.html" >&2
    fi
    exit 1
  fi
done

log() {
  echo "[sync_s3_to_minio] $*"
}

MINIO_SCHEME="http"
if [[ "$MINIO_USE_TLS" == "true" ]]; then
  MINIO_SCHEME="https"
fi
MINIO_URL="${MINIO_SCHEME}://${MINIO_HOST}:${MINIO_PORT}"

# ---- step 1: pull the real S3 bucket down to a local staging directory ---------------------
log "Syncing s3://${S3_BUCKET} -> ${STAGING_DIR} (this covers MLflow artifacts AND raw hoopR"
log "parquet, both under the same bucket per CLAUDE.md — no separate step needed for either)."
mkdir -p "$STAGING_DIR"
aws s3 sync "s3://${S3_BUCKET}" "$STAGING_DIR"
log "S3 sync complete. Local staging size: $(du -sh "$STAGING_DIR" | cut -f1)"

# ---- step 2: register the self-hosted MinIO as an `mc` alias --------------------------------
log "Registering mc alias '${MC_ALIAS}' -> ${MINIO_URL}"
mc alias set "$MC_ALIAS" "$MINIO_URL" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

# ---- step 3: ensure the target bucket exists -------------------------------------------------
log "Ensuring bucket '${MINIO_BUCKET}' exists in MinIO..."
mc mb --ignore-existing "${MC_ALIAS}/${MINIO_BUCKET}"

# ---- step 4: mirror staging dir into MinIO ---------------------------------------------------
log "Mirroring ${STAGING_DIR} -> ${MC_ALIAS}/${MINIO_BUCKET} ..."
mc mirror "$STAGING_DIR" "${MC_ALIAS}/${MINIO_BUCKET}"

log "Done. Verify with: mc ls ${MC_ALIAS}/${MINIO_BUCKET}"

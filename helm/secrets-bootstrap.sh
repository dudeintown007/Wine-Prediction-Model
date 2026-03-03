#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# secrets-bootstrap.sh — One-time setup: store all credentials in AWS Secrets Manager
#
# Run this ONCE before your first deployment.
# After this, every other script reads credentials from Secrets Manager
# automatically — you never have to export env vars again.
#
# What this creates in Secrets Manager (secret: mysecret):
#   DB_PASSWORD            — password for the mlflow_abhi RDS user/database
#   AWS_ACCESS_KEY_ID      — IAM key for MLflow pods to access S3 artifacts
#   AWS_SECRET_ACCESS_KEY  — matching IAM secret
#
# Note: the DB username (mlflow_abhi) and database name (mlflow_abhi) are
# declared in infra/main.tf and helm/values.yaml — only the password is secret.
#
# Bootstrap requirement (only this once):
#   Your LOCAL AWS credentials must be configured so the script can talk to
#   Secrets Manager. Use whichever method you prefer:
#     Option A: aws configure  (writes to ~/.aws/credentials)
#     Option B: export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in your shell
#     Option C: AWS SSO / IAM Identity Center: aws sso login
#
# Usage (from project root):
#   bash helm/secrets-bootstrap.sh
#
# To rotate a value later, just re-run this script with updated values —
# it does a put-secret-value (upsert), not a create.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
SECRET_NAME="mysecret"

echo "══════════════════════════════════════════════════════"
echo "  MLflow — Secrets Manager Bootstrap"
echo "  Region : ${AWS_REGION}"
echo "  Secret : ${SECRET_NAME}"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v aws  >/dev/null 2>&1 || { echo "ERROR: aws CLI not found."; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq not found. Install: sudo apt install jq"; exit 1; }

echo "AWS identity (must point at the correct account/region):"
aws sts get-caller-identity --output table
echo ""

# ── Collect credentials ───────────────────────────────────────────────────────
echo "Enter the values to store. Input is hidden for sensitive fields."
echo ""

# DB password for mlflow_abhi user
if [[ -n "${TF_VAR_db_password:-}" ]]; then
  DB_PASSWORD="${TF_VAR_db_password}"
  echo "  DB_PASSWORD (mlflow_abhi user) : (read from \$TF_VAR_db_password)"
else
  read -r -s -p "  DB_PASSWORD (mlflow_abhi user) : " DB_PASSWORD; echo ""
fi

# IAM key for S3 artifact access (can be different from your personal bootstrap key)
if [[ -n "${MLFLOW_AWS_ACCESS_KEY_ID:-}" ]]; then
  S3_ACCESS_KEY="${MLFLOW_AWS_ACCESS_KEY_ID}"
  echo "  AWS_ACCESS_KEY_ID     : (read from \$MLFLOW_AWS_ACCESS_KEY_ID)"
else
  read -r -s -p "  AWS_ACCESS_KEY_ID     : " S3_ACCESS_KEY; echo ""
fi

if [[ -n "${MLFLOW_AWS_SECRET_ACCESS_KEY:-}" ]]; then
  S3_SECRET_KEY="${MLFLOW_AWS_SECRET_ACCESS_KEY}"
  echo "  AWS_SECRET_ACCESS_KEY : (read from \$MLFLOW_AWS_SECRET_ACCESS_KEY)"
else
  read -r -s -p "  AWS_SECRET_ACCESS_KEY : " S3_SECRET_KEY; echo ""
fi

echo ""

# ── Build JSON payload ────────────────────────────────────────────────────────
SECRET_JSON=$(jq -n \
  --arg db_pass  "${DB_PASSWORD}" \
  --arg key_id   "${S3_ACCESS_KEY}" \
  --arg key_sec  "${S3_SECRET_KEY}" \
  '{
    DB_PASSWORD:            $db_pass,
    AWS_ACCESS_KEY_ID:      $key_id,
    AWS_SECRET_ACCESS_KEY:  $key_sec
  }')

# ── Upsert into Secrets Manager ───────────────────────────────────────────────
# create-or-update: try put-secret-value on an existing secret, else create it
if aws secretsmanager describe-secret \
      --secret-id "${SECRET_NAME}" \
      --region    "${AWS_REGION}" \
      --output    text >/dev/null 2>&1; then

  echo "Secret exists — updating value..."
  aws secretsmanager put-secret-value \
    --secret-id    "${SECRET_NAME}" \
    --secret-string "${SECRET_JSON}" \
    --region        "${AWS_REGION}" \
    --output        text >/dev/null

else
  echo "Secret not found — creating it..."
  aws secretsmanager create-secret \
    --name          "${SECRET_NAME}" \
    --description   "All runtime credentials for the MLflow production stack" \
    --secret-string "${SECRET_JSON}" \
    --region        "${AWS_REGION}" \
    --output        text >/dev/null
fi

echo ""
echo "  ✓ Secret stored: ${SECRET_NAME}"
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Bootstrap complete."
echo "  All other scripts now read credentials automatically."
echo ""
echo "  Next step:"
echo "    bash helm/provision.sh"
echo "══════════════════════════════════════════════════════"

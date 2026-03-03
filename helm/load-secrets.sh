#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# load-secrets.sh — Fetch all runtime credentials from AWS Secrets Manager
#                   and export them as environment variables.
#
# SOURCE this file — do not execute it directly:
#   source helm/load-secrets.sh          # from project root
#   source "$(dirname "$0")/load-secrets.sh"   # from another helm/ script
#
# After sourcing, the following variables are available in the calling script:
#   DB_PASSWORD            — password for the mlflow_abhi RDS user
#   TF_VAR_db_password     — same value, in the form Terraform expects
#   AWS_ACCESS_KEY_ID      — IAM key for MLflow → S3 artifact access
#   AWS_SECRET_ACCESS_KEY  — matching IAM secret
#
# DB user/name (mlflow_abhi) are hardcoded in infra/main.tf and helm/values.yaml
# — only the password is secret and needs to be loaded here.
#
# Requirements:
#   ✓ aws CLI v2 installed and configured (profile, env vars, or IAM role)
#   ✓ jq installed  (sudo apt install jq)
#   ✓ Calling identity must have IAM permission: secretsmanager:GetSecretValue
#     on arn:aws:secretsmanager:ap-south-1:*:secret:wine-mlops/mlflow/all-credentials
#
# The secret is created once by: bash helm/secrets-bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────

_SM_SECRET_NAME="${SM_SECRET_NAME:-mysecret}"
_SM_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"

# ── Dependency checks ─────────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "ERROR [load-secrets.sh]: aws CLI not found." >&2
  return 1 2>/dev/null || exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "ERROR [load-secrets.sh]: jq not found. Install: sudo apt install jq" >&2
  return 1 2>/dev/null || exit 1
fi

# ── Fetch from Secrets Manager ────────────────────────────────────────────────
echo "  [secrets] Loading credentials from Secrets Manager: ${_SM_SECRET_NAME} (${_SM_REGION})"

_SM_JSON=$(aws secretsmanager get-secret-value \
  --secret-id   "${_SM_SECRET_NAME}" \
  --region      "${_SM_REGION}" \
  --query       SecretString \
  --output      text 2>&1) || {
    echo ""
    echo "ERROR [load-secrets.sh]: Failed to fetch secret '${_SM_SECRET_NAME}'." >&2
    echo "  Possible causes:" >&2
    echo "    • Secret not yet created   → run: bash helm/secrets-bootstrap.sh" >&2
    echo "    • AWS credentials missing  → run: aws configure" >&2
    echo "    • Insufficient IAM perms   → need secretsmanager:GetSecretValue" >&2
    echo "    • Wrong region             → export AWS_DEFAULT_REGION=ap-south-1" >&2
    echo ""
    return 1 2>/dev/null || exit 1
  }

# ── Export variables ──────────────────────────────────────────────────────────
export DB_PASSWORD=$(echo "${_SM_JSON}"           | jq -r '.DB_PASSWORD')
export TF_VAR_db_password="${DB_PASSWORD}"        # Terraform reads this form
export AWS_ACCESS_KEY_ID=$(echo "${_SM_JSON}"     | jq -r '.AWS_ACCESS_KEY_ID')
export AWS_SECRET_ACCESS_KEY=$(echo "${_SM_JSON}" | jq -r '.AWS_SECRET_ACCESS_KEY')

# Validate nothing came back as null (means a key is missing in the secret)
for _var in DB_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  _val="${!_var}"
  if [[ -z "${_val}" || "${_val}" == "null" ]]; then
    echo "ERROR [load-secrets.sh]: Key '${_var}' is missing in secret '${_SM_SECRET_NAME}'." >&2
    echo "  Re-run: bash helm/secrets-bootstrap.sh" >&2
    return 1 2>/dev/null || exit 1
  fi
done

echo "  [secrets] ✓ DB_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY loaded."

# Clean up temp vars so they don't leak into the environment
unset _SM_SECRET_NAME _SM_REGION _SM_JSON _var _val

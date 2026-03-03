#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# create-secrets.sh
# Creates Kubernetes Secrets for RDS + S3 credentials.
#
# Credentials are loaded automatically from AWS Secrets Manager.
# No manual env var exports required.
#
# Usage (standalone, from project root):
#   bash helm/create-secrets.sh
#
# Called automatically by helm/provision.sh (credentials already loaded).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="mlops"

# ── Load credentials from Secrets Manager (no-op if already sourced by caller) ─
if [[ -z "${DB_PASSWORD:-}" || -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=helm/load-secrets.sh
  source "${SCRIPT_DIR}/load-secrets.sh"
fi

: "${DB_PASSWORD:?DB_PASSWORD still empty after loading secrets}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID still empty after loading secrets}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY still empty after loading secrets}"

# Ensure namespace exists
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# RDS credentials — user mlflow_abhi on database mlflow_abhi
kubectl create secret generic mlflow-db-secret \
  --namespace "${NAMESPACE}" \
  --from-literal=username=mlflow_abhi \
  --from-literal=password="${DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ Secret created: mlflow-db-secret (user=mlflow_abhi, db=mlflow_abhi)"

# S3 / AWS credentials
kubectl create secret generic mlflow-s3-secret \
  --namespace "${NAMESPACE}" \
  --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ Secret created: mlflow-s3-secret (S3/IAM credentials)"
echo ""
echo "  k8s Secrets are ready. Run helm/deploy.sh to deploy MLflow."

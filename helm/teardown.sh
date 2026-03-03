#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# teardown.sh — Destroy the full production MLflow stack
#
# What this removes:
#   1. Helm release (MLflow pods, services, HPA)
#   2. Kubernetes namespace and all remaining resources in it
#   3. Terraform-managed AWS infrastructure (EKS + RDS + VPC + Secrets Manager)
#
# ⚠️  WARNING: This is DESTRUCTIVE. RDS data will be lost (skip_final_snapshot=true).
#     Run a pg_dump first if you need to keep MLflow experiment history.
#
# Prerequisites:
#   ✓ kubectl must still be pointing at the target EKS cluster
#   ✓ AWS credentials configured (aws configure / IAM role / SSO)
#   ✓ jq installed  (sudo apt install jq)
#   ✓ Secret wine-mlops/mlflow/all-credentials must still exist in Secrets Manager
#     (credentials are loaded automatically — no manual env var exports needed)
#
# Usage (from project root):
#   bash helm/teardown.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INFRA_DIR="infra"
NAMESPACE="mlops"
RELEASE="mlflow"

echo "══════════════════════════════════════════════════════"
echo "  Wine-MLops — Production TEARDOWN"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  This will permanently delete:"
echo "    • Helm release '${RELEASE}' in namespace '${NAMESPACE}'"
echo "    • All resources in namespace '${NAMESPACE}'"
echo "    • EKS cluster, RDS instance, VPC (via Terraform)"
echo ""
read -r -p "Are you sure you want to destroy everything? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted — nothing was deleted."; exit 0; }
echo ""

# ── Step 1: Helm uninstall ────────────────────────────────────────────────────
echo "[1/3] Uninstalling Helm release '${RELEASE}'..."
if helm status "${RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait
  echo "  ✓ Helm release removed."
else
  echo "  Release '${RELEASE}' not found — skipping."
fi
echo ""

# ── Step 2: Delete namespace (removes Secrets, PVCs, etc.) ───────────────────
echo "[2/3] Deleting namespace '${NAMESPACE}'..."
if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  kubectl delete namespace "${NAMESPACE}" --wait=true
  echo "  ✓ Namespace deleted."
else
  echo "  Namespace '${NAMESPACE}' not found — skipping."
fi
echo ""

# ── Step 3: Terraform destroy ────────────────────────────────────────────────
echo "[3/3] Destroying AWS infrastructure via Terraform..."
echo "  (EKS cluster, RDS, VPC, Secrets Manager — ap-south-1)"
echo ""

# Load TF_VAR_db_password from Secrets Manager so Terraform can plan the destroy
# shellcheck source=helm/load-secrets.sh
source "helm/load-secrets.sh"

terraform -chdir="${INFRA_DIR}" destroy -auto-approve
echo ""
echo "  ✓ AWS infrastructure destroyed."
echo ""

echo "══════════════════════════════════════════════════════"
echo "  Teardown complete — all resources removed."
echo "══════════════════════════════════════════════════════"

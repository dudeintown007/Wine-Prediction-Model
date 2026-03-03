#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# provision.sh — End-to-end production deployment
#
# Orchestrates the full stack in the correct order:
#   Step 1 — Terraform: provision EKS cluster + RDS PostgreSQL on AWS
#   Step 2 — kubeconfig: wire kubectl to the new EKS cluster
#   Step 3 — Secrets:   create k8s Secrets (DB password + S3 keys)
#   Step 4 — Helm:      deploy MLflow tracking server onto EKS
#
# Prerequisites (install once):
#   ✓ AWS CLI v2       — https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html
#   ✓ Terraform >= 1.5 — https://developer.hashicorp.com/terraform/install
#   ✓ Helm 3.x         — https://helm.sh/docs/intro/install/
#   ✓ kubectl          — https://kubernetes.io/docs/tasks/tools/
#   ✓ jq               — sudo apt install jq
#   ✓ AWS credentials configured (aws configure / IAM role / SSO)
#
# First time?  Create the master secret once:
#   bash helm/secrets-bootstrap.sh
#
# Every run after that:
#   bash helm/provision.sh
#
# Teardown:
#   bash helm/teardown.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INFRA_DIR="infra"
HELM_DIR="helm"
AWS_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"

# ── Preflight ─────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════"
echo "  Wine-MLops — Production Deployment"
echo "══════════════════════════════════════════════════════"
echo ""

for cmd in aws terraform helm kubectl jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: '${cmd}' not found in PATH."
    exit 1
  }
done

echo "AWS identity:"
aws sts get-caller-identity --output table
echo ""

# ── Load all credentials from AWS Secrets Manager ─────────────────────────────
source "${HELM_DIR}/load-secrets.sh"

# Stash the S3 IAM keys loaded above — they are only needed at Step 3.
# Unset them NOW so that Terraform, aws eks update-kubeconfig, and kubectl all
# fall back to ~/.aws/credentials (admin keys) for AWS API calls.
# Without this, kubectl auth fails because the S3 IAM user is not in the EKS
# cluster's access config.
_STASH_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
_STASH_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
echo ""

# ── Step 1: Terraform — provision EKS + RDS ───────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "[1/4] Terraform — provisioning EKS + RDS..."
echo "──────────────────────────────────────────────────────"

terraform -chdir="${INFRA_DIR}" init -upgrade

terraform -chdir="${INFRA_DIR}" plan -out=tfplan

echo ""
read -r -p "Apply the plan above? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

terraform -chdir="${INFRA_DIR}" apply tfplan
echo ""
echo "  ✓ Infrastructure provisioned."
echo ""

# ── Step 2: kubeconfig ────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "[2/4] Configuring kubectl for EKS..."
echo "──────────────────────────────────────────────────────"

EKS_CLUSTER_NAME=$(terraform -chdir="${INFRA_DIR}" output -raw eks_cluster_name)
RDS_ENDPOINT=$(terraform -chdir="${INFRA_DIR}" output -raw rds_endpoint)

aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name   "${EKS_CLUSTER_NAME}"

echo ""
echo "  kubectl context switched to: ${EKS_CLUSTER_NAME}"
echo ""
kubectl get nodes
echo ""

# ── Step 3: Secrets ───────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "[3/4] Creating Kubernetes Secrets..."
echo "──────────────────────────────────────────────────────"

# Restore the S3 IAM keys — create-secrets.sh needs them for mlflow-s3-secret.
export AWS_ACCESS_KEY_ID="${_STASH_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${_STASH_AWS_SECRET_ACCESS_KEY}"
unset _STASH_AWS_ACCESS_KEY_ID _STASH_AWS_SECRET_ACCESS_KEY

bash "${HELM_DIR}/create-secrets.sh"
echo ""

# ── Step 4: Helm — deploy MLflow ─────────────────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "[4/4] Deploying MLflow via Helm..."
echo "──────────────────────────────────────────────────────"

RDS_ENDPOINT="${RDS_ENDPOINT}" bash "${HELM_DIR}/deploy.sh"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════"
echo "  All done! Resources summary:"
echo ""
echo "  EKS cluster : ${EKS_CLUSTER_NAME}"
echo "  RDS endpoint: ${RDS_ENDPOINT}"
echo "  RDS database: mlflow_abhi"
echo "  RDS user    : mlflow_abhi"
echo ""
echo "  Get the MLflow NLB URL (wait ~2 min for AWS):"
echo "    kubectl get svc mlflow -n mlops"
echo ""
echo "  Teardown everything:"
echo "    bash helm/teardown.sh"
echo "══════════════════════════════════════════════════════"

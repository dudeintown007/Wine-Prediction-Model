#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Deploy MLflow to AWS EKS via Helm
#
# Run from the project root:
#   bash helm/deploy.sh
#
# When called from helm/provision.sh the RDS endpoint is injected automatically:
#   RDS_ENDPOINT="<host>" bash helm/deploy.sh
#
# When running standalone (infra already exists):
#   export RDS_ENDPOINT=$(terraform -chdir=infra output -raw rds_endpoint)
#   bash helm/deploy.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="mlops"
RELEASE="mlflow"
VALUES="helm/values.yaml"

# ── Resolve RDS endpoint ──────────────────────────────────────────────────────
# Priority: env var RDS_ENDPOINT → terraform output → fail with helpful message
if [[ -z "${RDS_ENDPOINT:-}" ]]; then
  echo "RDS_ENDPOINT not set — attempting to read from terraform output..."
  RDS_ENDPOINT=$(terraform -chdir=infra output -raw rds_endpoint 2>/dev/null) || true
fi

if [[ -z "${RDS_ENDPOINT:-}" ]] || [[ "${RDS_ENDPOINT}" == "CHANGE_ME"* ]]; then
  echo "ERROR: Cannot determine RDS endpoint."
  echo "  Run full provisioning:  bash helm/provision.sh"
  echo "  Or set manually:        export RDS_ENDPOINT=<your-rds-host>"
  exit 1
fi

echo "  RDS endpoint: ${RDS_ENDPOINT}"

echo "Adding community-charts Helm repo..."
helm repo add community-charts https://community-charts.github.io/helm-charts 2>/dev/null || true
helm repo update

echo "Creating namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying MLflow..."

# If a previous release is stuck in 'failed' state, helm upgrade will immediately
# error with "context deadline exceeded". Detect and clean it up first.
RELEASE_STATUS=$(helm status "${RELEASE}" --namespace "${NAMESPACE}" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || echo "not-found")
if [[ "${RELEASE_STATUS}" == "failed" || "${RELEASE_STATUS}" == "pending-upgrade" || "${RELEASE_STATUS}" == "pending-install" ]]; then
  echo "  Release '${RELEASE}' is in '${RELEASE_STATUS}' state — uninstalling before fresh install..."
  helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait 2>/dev/null || true
  sleep 5
fi

helm upgrade --install "${RELEASE}" community-charts/mlflow \
  --namespace "${NAMESPACE}" \
  --values "${VALUES}" \
  --set backendStore.postgres.host="${RDS_ENDPOINT}" \
  --set backendStore.postgres.database="mlflow_abhi" \
  --set backendStore.postgres.user="mlflow_abhi" \
  --wait --timeout 10m --cleanup-on-fail

echo ""
echo "──────────────────────────────────────────────────────"
echo " Deployment complete!"
echo ""
echo " Get the LoadBalancer URL (wait ~2 min for AWS to provision):"
echo "   kubectl get svc mlflow -n ${NAMESPACE}"
echo ""
echo " Watch pods:"
echo "   kubectl get pods -n ${NAMESPACE} -w"
echo ""
echo " Logs:"
echo "   kubectl logs -f deployment/mlflow -n ${NAMESPACE}"
echo "──────────────────────────────────────────────────────"

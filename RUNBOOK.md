# Wine Prediction Model — MLOps Runbook

## Table of Contents
1. [Project Overview](#1-project-overview)
2. [Repository Structure](#2-repository-structure)
3. [ML Workflow — What the Code Does](#3-ml-workflow--what-the-code-does)
4. [Infrastructure — What Gets Created on AWS](#4-infrastructure--what-gets-created-on-aws)
5. [How Everything Connects](#5-how-everything-connects)
6. [Prerequisites — Install Once](#6-prerequisites--install-once)
7. [Step-by-Step Execution Guide](#7-step-by-step-execution-guide)
8. [Running the ML Training Job](#8-running-the-ml-training-job)
9. [Destroy Everything — Zero AWS Cost](#9-destroy-everything--zero-aws-cost)

---

## 1. Project Overview

This project trains a **wine quality prediction model** (RandomForest) and tracks all experiments using **MLflow**, deployed on AWS production infrastructure.

| Component | Technology | Purpose |
|-----------|-----------|---------|
| ML model | scikit-learn RandomForest | Predicts wine quality score |
| Experiment tracking | MLflow | Logs params, metrics, model artifacts |
| Backend store | AWS RDS PostgreSQL | Stores run metadata (params, metrics, tags) |
| Artifact store | AWS S3 (`dvc-abhi-test`) | Stores trained model files and plots |
| MLflow server | Kubernetes pod on EKS | Serves the MLflow UI and tracking API |
| Data versioning | DVC + S3 | Versions the training dataset |
| Secrets | AWS Secrets Manager | Stores all credentials securely |

---

## 2. Repository Structure

```
Wine-Prediction-Model/
│
├── train.py                    # ML training script — run this to train the model
├── utils.py                    # Helper: load CSV, split features/target
├── requirements.txt            # Python dependencies
│
├── data/
│   ├── wine_sample.csv         # Training dataset (wine features + quality score)
│   └── wine_sample.csv.dvc     # DVC pointer — tracks dataset version in S3
│
├── infra/                      # Terraform — provisions all AWS infrastructure
│   ├── main.tf                 # VPC, EKS cluster, RDS PostgreSQL, Secrets Manager
│   ├── variables.tf            # Input variables (region, instance types, passwords)
│   └── outputs.tf              # Outputs: EKS cluster name, RDS endpoint, etc.
│
├── helm/                       # Kubernetes deployment scripts
│   ├── values.yaml             # MLflow Helm chart configuration
│   ├── secrets-bootstrap.sh    # STEP 1 — store credentials in Secrets Manager (once)
│   ├── load-secrets.sh         # Sourced by other scripts — reads creds from Secrets Manager
│   ├── provision.sh            # STEP 2 — full deploy: Terraform + kubectl + Helm
│   ├── create-secrets.sh       # Called by provision.sh — creates k8s Secrets
│   ├── deploy.sh               # Called by provision.sh — deploys MLflow via Helm
│   └── teardown.sh             # DESTROY — removes all AWS resources
│
└── RUNBOOK.md                  # This file
```

---

## 3. ML Workflow — What the Code Does

### `data/wine_sample.csv`
Training dataset. Each row is a wine sample with physicochemical features:
`fixed acidity`, `volatile acidity`, `citric acid`, `residual sugar`, `chlorides`,
`free sulfur dioxide`, `total sulfur dioxide`, `density`, `pH`, `sulphates`, `alcohol`
→ Target: `quality` (score 0–10)

### `utils.py`
Two helper functions used by `train.py`:
- `load_data(path)` — reads the CSV, validates the `quality` column exists
- `features_and_target(df)` — splits DataFrame into `X` (features) and `y` (quality)

### `train.py`
The main training script. What it does end-to-end:

```
1. Connect to MLflow server (MLFLOW_TRACKING_URI env var)
2. Set experiment name (default: "wine-prediction")
3. Load data/wine_sample.csv
4. Split into train/test sets
5. Train RandomForestRegressor
6. Log to MLflow:
   - Params : n_estimators, max_depth, test_size, random_state, train_rows, test_rows
   - Metrics: mse, rmse, r2
7. Save trained model artifact → S3 via MLflow
```

Run with defaults:
```bash
export MLFLOW_TRACKING_URI="http://<mlflow-nlb-url>"
python train.py
```

Run with custom hyperparameters:
```bash
python train.py \
  --n-estimators 100 \
  --max-depth 8 \
  --test-size 0.2 \
  --experiment "wine-prediction" \
  --run "run-v2"
```

---

## 4. Infrastructure — What Gets Created on AWS

> Region: **ap-south-1 (Mumbai)**
> All resource names are prefixed with `wine-mlops` (set in `infra/variables.tf`)

### Networking (VPC)

| Resource | Name | Details |
|----------|------|---------|
| VPC | `wine-mlops-vpc` | CIDR: `10.0.0.0/16` |
| Private subnets | `wine-mlops-vpc-private-ap-south-1a/b` | `10.0.1.0/24`, `10.0.2.0/24` — EKS nodes + RDS live here |
| Public subnets | `wine-mlops-vpc-public-ap-south-1a/b` | `10.0.101.0/24`, `10.0.102.0/24` — Load balancer |
| NAT Gateway | `wine-mlops-vpc` | Allows private subnet outbound internet |
| Internet Gateway | auto-named | Public subnet internet access |

### Kubernetes (EKS)

| Resource | Name | Details |
|----------|------|---------|
| EKS Cluster | `wine-mlops-cluster` | Kubernetes v1.29 |
| Node Group | `mlops` | 2× `t3.medium` (min 1, max 3) |
| Security Group | auto by EKS | Node-to-node communication |

### Database (RDS)

| Resource | Name | Details |
|----------|------|---------|
| RDS Instance | `wine-mlops-mlflow-db` | PostgreSQL 15, `db.t3.micro` |
| Database name | `mlflow_abhi` | MLflow stores run metadata here |
| DB username | `mlflow_abhi` | MLflow connects as this user |
| RDS Subnet Group | `wine-mlops-rds-subnet-group` | Spans both private subnets |
| Security Group | `wine-mlops-rds-sg` | Only allows port 5432 from EKS nodes |
| Storage | 20 GB gp3 (auto-scales to 100 GB) | Encrypted at rest |

### Secrets Manager

| Resource | Secret Name | Stores |
|----------|------------|--------|
| DB credentials | `wine-mlops/mlflow/db-credentials` | username, password, host, port, dbname, postgres_url |
| All runtime credentials | `mysecret` | DB_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY |

### S3 (pre-existing)

| Bucket | Usage |
|--------|-------|
| `dvc-abhi-test` | DVC dataset versioning + MLflow model artifacts + Terraform state |

### Kubernetes Resources (created inside EKS)

| Resource | Name | Namespace |
|----------|------|-----------|
| Namespace | `mlops` | — |
| k8s Secret | `mlflow-db-secret` | `mlops` |
| k8s Secret | `mlflow-s3-secret` | `mlops` |
| Helm Release | `mlflow` | `mlops` |
| Deployment | `mlflow` | `mlops` — 2 pods |
| Service (NLB) | `mlflow` | `mlops` — internet-facing, port 80 |
| HPA | `mlflow` | `mlops` — scales 2→5 pods on CPU/memory |

---

## 5. How Everything Connects

```
Your laptop
    │
    ├── train.py ──────────────────────────────────────────────────────────┐
    │       │  MLFLOW_TRACKING_URI=http://<NLB-url>                        │
    │       ▼                                                               │
    │   MLflow client (python)                                             │
    │       │                                                               │
    │       ▼                                                               │
    │   ┌─────────────────────────────────────────────┐                    │
    │   │  AWS EKS — namespace: mlops                 │                    │
    │   │                                             │                    │
    │   │  MLflow Server Pod (×2)                     │                    │
    │   │       │                 │                   │                    │
    │   │       ▼                 ▼                   │                    │
    │   │  RDS PostgreSQL    S3 dvc-abhi-test         │                    │
    │   │  mlflow_abhi DB    mlflow-artifacts/        │                    │
    │   │  (params/metrics)  (model .pkl files)       │                    │
    │   │                                             │                    │
    │   │  Exposed via: AWS NLB (port 80) ◀───────────┼────────────────────┘
    │   └─────────────────────────────────────────────┘
    │
    ├── Secrets Manager (mysecret)
    │       └── read by: provision.sh, create-secrets.sh, teardown.sh
    │
    └── Terraform state ──▶ S3: dvc-abhi-test/mlops/infra/terraform.tfstate
```

---

## 6. Prerequisites — Install Once

```bash
# 1. AWS CLI v2
aws --version
# install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html

# 2. Terraform >= 1.5
terraform --version
# install: https://developer.hashicorp.com/terraform/install

# 3. Helm 3.x
helm version
# install: https://helm.sh/docs/intro/install/

# 4. kubectl
kubectl version --client
# install: https://kubernetes.io/docs/tasks/tools/

# 5. jq
jq --version
# install: sudo apt install jq

# 6. Configure AWS credentials (your personal admin keys)
aws configure
# Enter: AWS Access Key ID, AWS Secret Access Key, region: ap-south-1, format: json
```

---

## 7. Step-by-Step Execution Guide

> All commands are run from the **project root**: `Wine-Prediction-Model/`

---

### STEP 1 — Store credentials in Secrets Manager *(run once, ever)*

```bash
bash helm/secrets-bootstrap.sh
```

**What it asks you to enter (hidden input):**
| Prompt | What to enter |
|--------|--------------|
| `DB_PASSWORD (mlflow_abhi user)` | A strong password you choose for the RDS database (e.g. `MyStr0ng#Pass`) |
| `AWS_ACCESS_KEY_ID` | Your AWS access key (same as `~/.aws/credentials` or from IAM console) |
| `AWS_SECRET_ACCESS_KEY` | Your AWS secret key (matching the above) |

**What it creates:**
- AWS Secrets Manager secret named `mysecret` in `ap-south-1`
- Contains: `DB_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

> After this step, **you never type credentials again** — all other scripts read from `mysecret` automatically via `helm/load-secrets.sh`.

---

### STEP 2 — Provision everything *(~15–20 min)*

```bash
bash helm/provision.sh
```

**Internally runs in this order:**

```
[load]   helm/load-secrets.sh       → reads credentials from mysecret
[1/4]    terraform init + plan       → shows you what will be created, asks y/N
[1/4]    terraform apply             → creates all AWS resources (see Section 4)
[2/4]    aws eks update-kubeconfig  → wires kubectl to wine-mlops-cluster
[3/4]    helm/create-secrets.sh     → creates mlflow-db-secret + mlflow-s3-secret in k8s
[4/4]    helm/deploy.sh             → deploys MLflow Helm chart onto EKS
```

**When Terraform shows the plan, review it and type `y` to apply.**

**After it completes:**
```bash
# Wait ~2 minutes for AWS to provision the NLB, then:
kubectl get svc mlflow -n mlops

# Output:
# NAME     TYPE           CLUSTER-IP   EXTERNAL-IP                     PORT(S)
# mlflow   LoadBalancer   10.x.x.x    <abc123>.elb.ap-south-1.amazonaws.com   80:xxxxx/TCP

# Open in browser: http://<EXTERNAL-IP>
# That is your MLflow UI
```

---

### STEP 3 — Verify everything is running

```bash
# Check all pods are Running
kubectl get pods -n mlops

# Expected output:
# NAME                      READY   STATUS    RESTARTS
# mlflow-xxxxxxxxx-xxxxx    1/1     Running   0
# mlflow-xxxxxxxxx-xxxxx    1/1     Running   0

# Check MLflow service
kubectl get svc mlflow -n mlops

# See MLflow logs
kubectl logs -f deployment/mlflow -n mlops
```

---

### STEP 4 — (Subsequent deploys only) Re-deploy MLflow without reprovisioning infra

```bash
# If you change helm/values.yaml or want to upgrade the MLflow chart:
export RDS_ENDPOINT=$(terraform -chdir=infra output -raw rds_endpoint)
RDS_ENDPOINT="${RDS_ENDPOINT}" bash helm/deploy.sh
```

---

## 8. Running the ML Training Job

Once the MLflow server is running:

```bash
# 1. Install Python dependencies
pip install -r requirements.txt

# 2. Get the MLflow UI URL
kubectl get svc mlflow -n mlops
# Copy the EXTERNAL-IP value

# 3. Run training (point at your MLflow server)
export MLFLOW_TRACKING_URI="http://<EXTERNAL-IP>"

python train.py \
  --csv data/wine_sample.csv \
  --experiment "wine-prediction" \
  --run "run-1" \
  --n-estimators 100 \
  --max-depth 8 \
  --test-size 0.2

# 4. Open MLflow UI in browser
# http://<EXTERNAL-IP>
# → Experiments → wine-prediction → see your run with metrics
```

**What gets logged per run:**

| Type | Key | Example Value |
|------|-----|---------------|
| Param | `n_estimators` | `100` |
| Param | `max_depth` | `8` |
| Param | `test_size` | `0.2` |
| Param | `random_state` | `42` |
| Param | `train_rows` | `1040` |
| Param | `test_rows` | `260` |
| Metric | `mse` | `0.34` |
| Metric | `rmse` | `0.58` |
| Metric | `r2` | `0.41` |
| Artifact | `wine-model/` | Serialised model in S3 |

---

## 9. Destroy Everything — Zero AWS Cost

> ⚠️ This permanently deletes all AWS resources. If you want to keep MLflow experiment history, dump the database first.

### Optional: Backup database before destroying

```bash
# Get RDS endpoint
RDS_ENDPOINT=$(terraform -chdir=infra output -raw rds_endpoint)

# Run pg_dump via a temporary pod
kubectl run pg-dump --rm -it --image=postgres:15 --namespace=mlops \
  --env="PGPASSWORD=<your-db-password>" -- \
  pg_dump -h "${RDS_ENDPOINT}" -U mlflow_abhi -d mlflow_abhi > backup.sql

echo "Database backed up to backup.sql"
```

### Destroy all resources

```bash
bash helm/teardown.sh
```

**Internally runs in this order:**

```
[confirm]  asks y/N — nothing deleted until you confirm
[1/3]      helm uninstall mlflow          → removes MLflow pods, NLB, HPA
[2/3]      kubectl delete namespace mlops → removes k8s Secrets, all namespace resources
[3/3]      terraform destroy              → destroys all AWS resources listed below
```

### AWS resources destroyed by `terraform destroy`

| Resource | Name |
|----------|------|
| RDS instance | `wine-mlops-mlflow-db` |
| RDS subnet group | `wine-mlops-rds-subnet-group` |
| Security group | `wine-mlops-rds-sg` |
| EKS node group | `mlops` |
| EKS cluster | `wine-mlops-cluster` |
| NAT Gateway | `wine-mlops-vpc` |
| Private subnets (×2) | `wine-mlops-vpc-private-*` |
| Public subnets (×2) | `wine-mlops-vpc-public-*` |
| Internet Gateway | `wine-mlops-vpc` |
| VPC | `wine-mlops-vpc` |
| Secrets Manager | `wine-mlops/mlflow/db-credentials` |
| Secrets Manager | `mysecret` |

> **Note:** The S3 bucket `dvc-abhi-test` is **NOT** destroyed by Terraform — it was pre-existing and holds your DVC data and Terraform state. Delete it manually from the AWS console only if you want to remove it entirely.

### Verify zero cost — check nothing remains

```bash
# Confirm EKS is gone
aws eks list-clusters --region ap-south-1

# Confirm RDS is gone
aws rds describe-db-instances --region ap-south-1

# Confirm Secrets Manager is clean
aws secretsmanager list-secrets --region ap-south-1

# Confirm no running NAT Gateways (these cost ~$32/month if left running)
aws ec2 describe-nat-gateways --region ap-south-1 \
  --filter Name=state,Values=available
```

---

## Quick Reference Card

```
FIRST TIME EVER:
  bash helm/secrets-bootstrap.sh        # store credentials in AWS

DEPLOY:
  bash helm/provision.sh                # full deploy (~15 min)

TRAIN MODEL:
  export MLFLOW_TRACKING_URI="http://<nlb-url>"
  python train.py

CHECK STATUS:
  kubectl get pods -n mlops
  kubectl get svc mlflow -n mlops

RE-DEPLOY HELM ONLY (infra already up):
  bash helm/deploy.sh

DESTROY EVERYTHING:
  bash helm/teardown.sh
```

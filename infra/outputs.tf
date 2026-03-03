output "eks_cluster_name" {
  description = "EKS cluster name — use in: aws eks update-kubeconfig --name <value>"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "rds_endpoint" {
  description = "RDS PostgreSQL hostname — injected automatically by helm/deploy.sh"
  value       = aws_db_instance.mlflow.address
}

output "rds_port" {
  value = aws_db_instance.mlflow.port
}

output "rds_db_name" {
  description = "RDS database name (mlflow_abhi)"
  value       = aws_db_instance.mlflow.db_name
}

output "rds_db_user" {
  description = "RDS master user (mlflow_abhi) — MLflow connects as this user"
  value       = aws_db_instance.mlflow.username
}

output "secrets_manager_arn" {
  description = "ARN of the Secrets Manager secret holding DB credentials"
  value       = aws_secretsmanager_secret.mlflow_db.arn
}

output "all_credentials_secret_name" {
  description = "Secrets Manager secret name for all runtime credentials — used by helm/load-secrets.sh"
  value       = "mysecret"   # created by helm/secrets-bootstrap.sh, not Terraform
}

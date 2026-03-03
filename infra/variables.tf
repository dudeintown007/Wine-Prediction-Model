variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project prefix for all resource names"
  type        = string
  default     = "wine-mlops"
}

variable "node_instance_type" {
  description = "EKS worker node instance type"
  type        = string
  default     = "t3.medium"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_password" {
  description = "Password for the mlflow_abhi RDS user — pass via: export TF_VAR_db_password=yourpassword (or store in Secrets Manager via helm/secrets-bootstrap.sh)"
  type        = string
  sensitive   = true
}

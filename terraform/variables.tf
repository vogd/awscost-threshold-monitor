# ── Required: CUDOS environment ───────────────────────────────────────────────

variable "ses_sender" {
  description = "From address for alert emails (must be SES-verified)"
  type        = string
}

variable "region" {
  description = "AWS region where CUDOS is deployed"
  type        = string
}

variable "athena_workgroup" {
  description = "Athena workgroup where CUDOS/CID is deployed"
  type        = string
}

variable "database" {
  description = "Athena database name created by CUDOS"
  type        = string
}

variable "cid_data_bucket" {
  description = "S3 bucket where CUR data exports are stored"
  type        = string
}

variable "data_export_name" {
  description = "CUR 2.0 data export name (S3 path: s3://<bucket>/cur2/<data_export_name>/data/)"
  type        = string
}

# ── Optional: read from CUDOS workgroup ──────────────────────────────────────

variable "profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = null
}

# ── Optional: Lambda configuration (sensible defaults) ───────────────────────

variable "function_name" {
  description = "Lambda function name"
  type        = string
  default     = "cost-threshold-monitor"
}

variable "role_name" {
  description = "IAM role name for the Lambda"
  type        = string
  default     = "cost-monitor-lambda-role"
}

variable "schedule" {
  description = "EventBridge schedule expression"
  type        = string
  default     = "rate(1 hour)"
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 300
}

variable "lambda_memory" {
  description = "Lambda memory in MB"
  type        = number
  default     = 128
}

variable "top_services" {
  description = "Number of top services to include in alert email"
  type        = number
  default     = 5
}

variable "top_resources" {
  description = "Number of top resource ARNs to include in alert email"
  type        = number
  default     = 10
}

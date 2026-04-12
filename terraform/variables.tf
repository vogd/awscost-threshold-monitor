variable "ses_sender" {
  description = "From address for alert emails (must be SES-verified)"
  type        = string
}

variable "profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = null
}

variable "region" {
  description = "AWS region for deployment and runtime"
  type        = string
  default     = "us-east-1"
}

variable "athena_workgroup" {
  description = "Athena workgroup where CUDOS/CID is deployed"
  type        = string
  default     = "CID"
}

variable "database" {
  description = "Athena database name"
  type        = string
  default     = "cid_data_export"
}

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

variable "env" {
  description = "Deployment environment (beta or prod)"
  type        = string

  validation {
    condition     = contains(["beta", "prod"], var.env)
    error_message = "env must be 'beta' or 'prod'."
  }
}

variable "aws_region" {
  description = "Region for core infra (S3/Lambda/APIGW/SFN)"
  type        = string
  default     = "us-east-1"
}

variable "bedrock_region" {
  description = "Bedrock region"
  type        = string
  default     = "us-west-2"
}

variable "bedrock_model_id" {
  description = "Bedrock model id"
  type        = string
  default     = "anthropic.claude-3-sonnet-20240229-v1:0"
}

variable "bedrock_max_retries" {
  description = "Max retries for Bedrock invoke"
  type        = number
  default     = 6
}

variable "bedrock_base_delay_seconds" {
  description = "Base delay for Bedrock retry backoff"
  type        = number
  default     = 1.5
}

variable "outputs_retention_days" {
  description = "Expire outputs after N days (0 disables lifecycle rule)"
  type        = number
  default     = 30
}

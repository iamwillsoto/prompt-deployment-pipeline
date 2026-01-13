variable "env" {
  description = "Deployment environment: beta or prod"
  type        = string
  validation {
    condition     = contains(["beta", "prod"], var.env)
    error_message = "env must be beta or prod"
  }
}

variable "aws_region" {
  description = "Region for Lambda/S3/SFN/API resources"
  type        = string
  default     = "us-east-1"
}

variable "bedrock_region" {
  description = "Region for Bedrock runtime (often us-west-2)"
  type        = string
  default     = "us-west-2"
}

variable "owner_suffix" {
  description = "Uniqueness suffix used in bucket name (e.g., iamwillsoto)"
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock model id"
  type        = string
  default     = "anthropic.claude-3-sonnet-20240229-v1:0"
}

variable "outputs_ttl_days" {
  description = "Days until outputs expire"
  type        = number
  default     = 30
}

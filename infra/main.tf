locals {
  bucket_name       = "pixel-prompts-${var.env}-${var.owner_suffix}"
  function_prefix   = "pixel-prompts-${var.env}"
  prompt_inputs_key = "prompt_inputs/"
  outputs_prefix    = "${var.env}/outputs/"
}

# ----------------------------
# S3 Bucket + Lifecycle
# ----------------------------
resource "aws_s3_bucket" "prompts" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.prompts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.prompts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Optional enhancement: expire outputs after N days
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.prompts.id

  rule {
    id     = "expire-outputs"
    status = "Enabled"

    filter {
      prefix = local.outputs_prefix
    }

    expiration {
      days = var.outputs_ttl_days
    }
  }
}

# ----------------------------
# Lambda Packaging (zip)
# ----------------------------
data "archive_file" "starter_zip" {
  type        = "zip"
  source_file = "${path.module}/lambdas/starter.py"
  output_path = "${path.module}/.build/starter.zip"
}

data "archive_file" "render_zip" {
  type        = "zip"
  source_file = "${path.module}/lambdas/render.py"
  output_path = "${path.module}/.build/render.zip"
}

data "archive_file" "invoke_zip" {
  type        = "zip"
  source_file = "${path.module}/lambdas/invoke_bedrock.py"
  output_path = "${path.module}/.build/invoke.zip"
}

data "archive_file" "publish_zip" {
  type        = "zip"
  source_file = "${path.module}/lambdas/publish.py"
  output_path = "${path.module}/.build/publish.zip"
}

data "archive_file" "api_zip" {
  type        = "zip"
  source_file = "${path.module}/lambdas/api.py"
  output_path = "${path.module}/.build/api.zip"
}

# ----------------------------
# IAM (least privilege)
# ----------------------------
resource "aws_iam_role" "lambda_role" {
  name               = "${local.function_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# CloudWatch logs for Lambdas
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda inline policy (S3 scoped + Bedrock InvokeModel)
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${local.function_prefix}-lambda-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read prompt inputs + templates
      {
        Sid    = "ReadPromptInputsAndTemplates"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:HeadObject"]
        Resource = [
          "${aws_s3_bucket.prompts.arn}/${local.prompt_inputs_key}*",
          "${aws_s3_bucket.prompts.arn}/prompt_templates/*"
        ]
      },
      # List ONLY within prompt_inputs/
      {
        Sid      = "ListPromptInputsPrefixOnly"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.prompts.arn
        Condition = {
          StringLike = { "s3:prefix" = ["${local.prompt_inputs_key}*"] }
        }
      },
      # Write outputs ONLY for this env prefix
      {
        Sid    = "WriteOutputsPrefixOnly"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = [
          "${aws_s3_bucket.prompts.arn}/${local.outputs_prefix}*"
        ]
      },
      # Bedrock invoke (scoped to the selected model in the chosen bedrock region)
      {
        Sid    = "InvokeBedrockModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.bedrock_region}::foundation-model/${var.bedrock_model_id}"
      }
    ]
  })
}

# Step Functions role: can invoke the three task Lambdas
resource "aws_iam_role" "sfn_role" {
  name               = "${local.function_prefix}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_trust.json
}

data "aws_iam_policy_document" "sfn_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "sfn_policy" {
  name = "${local.function_prefix}-sfn-policy"
  role = aws_iam_role.sfn_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeTaskLambdas"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.render.arn,
          aws_lambda_function.invoke.arn,
          aws_lambda_function.publish.arn
        ]
      }
    ]
  })
}

# ----------------------------
# Lambda Functions
# ----------------------------
resource "aws_lambda_function" "starter" {
  function_name = "${local.function_prefix}-starter"
  role          = aws_iam_role.lambda_role.arn
  handler       = "starter.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.starter_zip.output_path
  timeout       = 15
  memory_size   = 256

  environment {
    variables = {
      BUCKET          = aws_s3_bucket.prompts.bucket
      DEFAULT_ENV     = var.env
      STATE_MACHINE_ARN = aws_sfn_state_machine.pipeline.arn
    }
  }
}

resource "aws_lambda_function" "render" {
  function_name = "${local.function_prefix}-render"
  role          = aws_iam_role.lambda_role.arn
  handler       = "render.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.render_zip.output_path
  timeout       = 15
  memory_size   = 256

  environment {
    variables = {
      BUCKET      = aws_s3_bucket.prompts.bucket
      DEFAULT_ENV = var.env
    }
  }
}

resource "aws_lambda_function" "invoke" {
  function_name = "${local.function_prefix}-invoke-bedrock"
  role          = aws_iam_role.lambda_role.arn
  handler       = "invoke_bedrock.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.invoke_zip.output_path
  timeout       = 30
  memory_size   = 512

  environment {
    variables = {
      BEDROCK_REGION           = var.bedrock_region
      BEDROCK_MODEL_ID         = var.bedrock_model_id
      BEDROCK_MAX_RETRIES      = "6"
      BEDROCK_BASE_DELAY_SECONDS = "1.5"
    }
  }
}

resource "aws_lambda_function" "publish" {
  function_name = "${local.function_prefix}-publish"
  role          = aws_iam_role.lambda_role.arn
  handler       = "publish.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.publish_zip.output_path
  timeout       = 15
  memory_size   = 256

  environment {
    variables = {
      BUCKET      = aws_s3_bucket.prompts.bucket
      DEFAULT_ENV = var.env
    }
  }
}

resource "aws_lambda_function" "api" {
  function_name = "${local.function_prefix}-api"
  role          = aws_iam_role.lambda_role.arn
  handler       = "api.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.api_zip.output_path
  timeout       = 15
  memory_size   = 256

  environment {
    variables = {
      BUCKET          = aws_s3_bucket.prompts.bucket
      DEFAULT_ENV     = var.env
      STATE_MACHINE_ARN = aws_sfn_state_machine.pipeline.arn
    }
  }
}

# Allow API Lambda to start executions too (tightly scoped)
resource "aws_iam_role_policy" "api_start_sfn" {
  name = "${local.function_prefix}-api-start-sfn"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StartPipelineExecutions"
        Effect = "Allow"
        Action = ["states:StartExecution"]
        Resource = aws_sfn_state_machine.pipeline.arn
      }
    ]
  })
}

# ----------------------------
# Step Functions (render -> invoke -> publish)
# ----------------------------
resource "aws_sfn_state_machine" "pipeline" {
  name     = "${local.function_prefix}-pipeline"
  role_arn = aws_iam_role.sfn_role.arn

  definition = templatefile("${path.module}/stepfunctions.asl.json.tftpl", {
    render_arn  = aws_lambda_function.render.arn
    invoke_arn  = aws_lambda_function.invoke.arn
    publish_arn = aws_lambda_function.publish.arn
  })
}

# ----------------------------
# S3 Trigger -> Starter Lambda (restricted to prompt_inputs/ and .json)
# ----------------------------
resource "aws_lambda_permission" "allow_s3_invoke_starter" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.starter.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.prompts.arn
}

resource "aws_s3_bucket_notification" "this" {
  bucket = aws_s3_bucket.prompts.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.starter.arn
    events              = ["s3:ObjectCreated:Put"]
    filter_prefix       = local.prompt_inputs_key
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke_starter]
}

# ----------------------------
# API Gateway (HTTP API) -> api Lambda
# ----------------------------
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${local.function_prefix}-http-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "list_outputs" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /outputs"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "regenerate" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /regenerate"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_apigw_invoke_api" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

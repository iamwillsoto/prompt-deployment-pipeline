############################################
# infra/main.tf (RESOURCES ONLY)
# - NO terraform/provider blocks here
# - NO variable blocks here
# - NO output blocks here
############################################

locals {
  env         = var.env
  name_prefix = "pixel-prompts-${var.env}"
  bucket_name = "pixel-prompts-${var.env}-iamwillsoto"

  inputs_prefix    = "prompt_inputs/"
  templates_prefix = "prompt_templates/"
  outputs_prefix   = "${var.env}/outputs/"

  lambdas_dir = "${path.module}/../lambdas"
  build_dir   = "${path.module}/build"

  bedrock_model_arn = "arn:aws:bedrock:${var.bedrock_region}::foundation-model/${var.bedrock_model_id}"
}

############################
# Build dir for zip outputs
############################
resource "null_resource" "build_dir" {
  triggers = {
    always = timestamp()
  }

  provisioner "local-exec" {
    command = "mkdir -p ${local.build_dir}"
  }
}

############################
# Package Lambdas (repo-root /lambdas)
############################
data "archive_file" "starter_zip" {
  depends_on  = [null_resource.build_dir]
  type        = "zip"
  source_file = "${local.lambdas_dir}/starter.py"
  output_path = "${local.build_dir}/starter.zip"
}

data "archive_file" "render_zip" {
  depends_on  = [null_resource.build_dir]
  type        = "zip"
  source_file = "${local.lambdas_dir}/render.py"
  output_path = "${local.build_dir}/render.zip"
}

data "archive_file" "invoke_zip" {
  depends_on  = [null_resource.build_dir]
  type        = "zip"
  source_file = "${local.lambdas_dir}/invoke_bedrock.py"
  output_path = "${local.build_dir}/invoke.zip"
}

data "archive_file" "publish_zip" {
  depends_on  = [null_resource.build_dir]
  type        = "zip"
  source_file = "${local.lambdas_dir}/publish.py"
  output_path = "${local.build_dir}/publish.zip"
}

data "archive_file" "api_zip" {
  depends_on  = [null_resource.build_dir]
  type        = "zip"
  source_file = "${local.lambdas_dir}/api.py"
  output_path = "${local.build_dir}/api.zip"
}

############################
# S3 Bucket
############################
resource "aws_s3_bucket" "prompts" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.prompts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.prompts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "outputs_expire" {
  count  = var.outputs_retention_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.prompts.id

  rule {
    id     = "expire-outputs"
    status = "Enabled"

    filter {
      prefix = local.outputs_prefix
    }

    expiration {
      days = var.outputs_retention_days
    }
  }
}

############################
# IAM Trust Policies
############################
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

############################
# IAM Roles
############################
resource "aws_iam_role" "lambda_role" {
  name               = "${local.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role" "sfn_role" {
  name               = "${local.name_prefix}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_trust.json
}

############################
# Lambda Core Policy (NO SFN ARN in here to avoid cycles)
############################
data "aws_iam_policy_document" "lambda_core_policy" {
  statement {
    sid    = "ReadInputsAndTemplates"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:HeadObject"
    ]
    resources = [
      "${aws_s3_bucket.prompts.arn}/${local.inputs_prefix}*",
      "${aws_s3_bucket.prompts.arn}/${local.templates_prefix}*"
    ]
  }

  statement {
    sid       = "ListInputsPrefixOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.prompts.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.inputs_prefix}*"]
    }
  }

  statement {
    sid     = "WriteOutputsPrefixOnly"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.prompts.arn}/${local.outputs_prefix}*"
    ]
  }

  statement {
    sid       = "InvokeBedrockModel"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = [local.bedrock_model_arn]
  }
}

resource "aws_iam_role_policy" "lambda_core_policy" {
  name   = "${local.name_prefix}-lambda-core"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_core_policy.json
}

############################
# Lambda Functions (render/invoke/publish first)
############################
resource "aws_lambda_function" "render" {
  function_name    = "${local.name_prefix}-render"
  role             = aws_iam_role.lambda_role.arn
  handler          = "render.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.render_zip.output_path
  source_code_hash = data.archive_file.render_zip.output_base64sha256
  timeout          = 15
  memory_size      = 256

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_core_policy
  ]

  environment {
    variables = {
      DEFAULT_ENV      = var.env
      BUCKET           = aws_s3_bucket.prompts.bucket
      TEMPLATES_PREFIX = local.templates_prefix
      OUTPUTS_PREFIX   = local.outputs_prefix
    }
  }
}

resource "aws_lambda_function" "invoke" {
  function_name    = "${local.name_prefix}-invoke-bedrock"
  role             = aws_iam_role.lambda_role.arn
  handler          = "invoke_bedrock.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.invoke_zip.output_path
  source_code_hash = data.archive_file.invoke_zip.output_base64sha256
  timeout          = 30
  memory_size      = 256

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_core_policy
  ]

  environment {
    variables = {
      DEFAULT_ENV                = var.env
      BEDROCK_REGION             = var.bedrock_region
      BEDROCK_MODEL_ID           = var.bedrock_model_id
      BEDROCK_MAX_RETRIES        = tostring(var.bedrock_max_retries)
      BEDROCK_BASE_DELAY_SECONDS = tostring(var.bedrock_base_delay_seconds)
    }
  }
}

resource "aws_lambda_function" "publish" {
  function_name    = "${local.name_prefix}-publish"
  role             = aws_iam_role.lambda_role.arn
  handler          = "publish.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.publish_zip.output_path
  source_code_hash = data.archive_file.publish_zip.output_base64sha256
  timeout          = 15
  memory_size      = 256

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_core_policy
  ]

  environment {
    variables = {
      DEFAULT_ENV    = var.env
      BUCKET         = aws_s3_bucket.prompts.bucket
      OUTPUTS_PREFIX = local.outputs_prefix
    }
  }
}

############################
# Step Functions policy + state machine
############################
data "aws_iam_policy_document" "sfn_policy" {
  statement {
    sid     = "InvokePipelineLambdas"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.render.arn,
      aws_lambda_function.invoke.arn,
      aws_lambda_function.publish.arn
    ]
  }
}

resource "aws_iam_role_policy" "sfn_policy" {
  name   = "${local.name_prefix}-sfn-policy"
  role   = aws_iam_role.sfn_role.id
  policy = data.aws_iam_policy_document.sfn_policy.json
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${local.name_prefix}-pipeline"
  role_arn = aws_iam_role.sfn_role.arn

  definition = templatefile("${path.module}/stepfunctions.asl.json.tftpl", {
    render_arn  = aws_lambda_function.render.arn
    invoke_arn  = aws_lambda_function.invoke.arn
    publish_arn = aws_lambda_function.publish.arn
  })

  depends_on = [aws_iam_role_policy.sfn_policy]
}

############################
# StartExecution permission (separate, AFTER SFN exists)
############################
data "aws_iam_policy_document" "lambda_start_sfn" {
  statement {
    sid       = "StartExecution"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.pipeline.arn]
  }
}

resource "aws_iam_role_policy" "lambda_start_sfn" {
  name   = "${local.name_prefix}-lambda-start-sfn"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_start_sfn.json

  depends_on = [aws_sfn_state_machine.pipeline]
}

############################
# Starter Lambda (depends on SFN for env var)
############################
resource "aws_lambda_function" "starter" {
  function_name    = "${local.name_prefix}-starter"
  role             = aws_iam_role.lambda_role.arn
  handler          = "starter.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.starter_zip.output_path
  source_code_hash = data.archive_file.starter_zip.output_base64sha256
  timeout          = 15
  memory_size      = 256

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_core_policy,
    aws_iam_role_policy.lambda_start_sfn
  ]

  environment {
    variables = {
      DEFAULT_ENV       = var.env
      BUCKET            = aws_s3_bucket.prompts.bucket
      OUTPUTS_PREFIX    = local.outputs_prefix
      STATE_MACHINE_ARN = aws_sfn_state_machine.pipeline.arn
    }
  }
}

############################
# S3 -> Starter trigger
############################
resource "aws_lambda_permission" "allow_s3_invoke_starter" {
  statement_id  = "AllowExecutionFromS3-${var.env}"
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
    filter_prefix       = local.inputs_prefix
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke_starter]
}

############################
# Optional HTTP API (kept because your outputs.tf references it)
############################
resource "aws_lambda_function" "api" {
  function_name    = "${local.name_prefix}-api"
  role             = aws_iam_role.lambda_role.arn
  handler          = "api.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256
  timeout          = 15
  memory_size      = 256

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_core_policy,
    aws_iam_role_policy.lambda_start_sfn
  ]

  environment {
    variables = {
      DEFAULT_ENV       = var.env
      BUCKET            = aws_s3_bucket.prompts.bucket
      OUTPUTS_PREFIX    = local.outputs_prefix
      STATE_MACHINE_ARN = aws_sfn_state_machine.pipeline.arn
    }
  }
}

resource "aws_apigatewayv2_api" "http_api" {
  name          = "${local.name_prefix}-http-api"
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
  statement_id  = "AllowExecutionFromAPIGW"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

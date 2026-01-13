output "bucket_name" {
  value = aws_s3_bucket.prompts.bucket
}

output "outputs_prefix" {
  value = "${var.env}/outputs/"
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline.arn
}

output "http_api_url" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}

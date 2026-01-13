Prompt Deployment Pipeline (Beta → Prod)

Terraform + Event-Driven Amazon Bedrock Rendering

A Terraform-managed prompt deployment platform that converts JSON prompt configurations into rendered HTML/Markdown outputs using an event-driven AWS architecture. Prompt configs are uploaded to S3, processed by Lambda, optionally invoked through Amazon Bedrock, and published to environment-scoped prefixes (beta/ and prod/). CI/CD enforces strict PR → Beta and Merge → Prod promotion.

Outcomes

Environment isolation
Beta and Prod are separated via strict S3 prefixes and least-privilege IAM scoping.

Event-driven execution
S3 ObjectCreated:Put events automatically trigger prompt processing.

Model-backed generation
Lambda invokes Amazon Bedrock (InvokeModel) to generate AI-backed content.

Infrastructure as Code
All resources (S3, Lambda, IAM, Step Functions, API Gateway) are defined and managed in Terraform.

Secure by default
IAM policies are scoped to required bucket paths and specific Bedrock model ARNs.

Promotion discipline
Pull Requests deploy to beta; merges to main deploy to prod.

Architecture (High Level)

A developer uploads a prompt config JSON to:
s3://<env-bucket>/prompt_inputs/

An S3 event notification triggers the environment-specific Lambda entrypoint.

Lambda:

Fetches the prompt config and template from S3

Renders the final prompt using variables

Invokes Amazon Bedrock (Claude / Titan)

Writes the output to:
s3://<env-bucket>/<env>/outputs/<slug>.(html|md)

Optional workflow
Step Functions orchestrates render → invoke → publish with retries and error handling.

Optional API
API Gateway exposes list, preview, and regenerate endpoints.

Repository Layout
infra/                  # Terraform IaC
  main.tf
  variables.tf
  versions.tf
  outputs.tf
  stepfunctions.asl.json.tftpl

lambdas/                # Lambda sources (packaged by Terraform)
  starter.py            # S3 trigger entrypoint
  render.py             # Template rendering utilities
  invoke_bedrock.py     # Bedrock client + retries
  publish.py            # Writes outputs to S3
  api.py                # Optional API routes

prompt_templates/       # Prompt template files
prompts/                # Sample prompt configs
validation-screenshots/ # Execution proof screenshots

Environments
Beta

Triggered by Pull Requests

Outputs written to beta/outputs/

Prod

Triggered by merges to main

Outputs written to prod/outputs/

Environment selection is derived from:

Filename convention (beta-*.json, prod-*.json)

S3 object metadata (env=beta|prod)

Fallback to DEFAULT_ENV

Deploy

From infra/:
terraform init
terraform apply

Key inputs

env = beta | prod

bucket_name

bedrock_region

bedrock_model_id

CI/CD
PR → Beta

Deploys infrastructure changes to beta

Publishes prompt configs for validation

Merge → Prod

Deploys infrastructure changes to prod

Publishes final outputs

This enforces promotion discipline: only reviewed changes reach production.

Summary

This project demonstrates production-ready Infrastructure as Code, event-driven serverless design, and disciplined environment promotion for AI-backed workloads on AWS.

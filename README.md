# Prompt Deployment Pipeline (Beta → Prod)

## Terraform + Event-Driven Amazon Bedrock Rendering

A production-oriented prompt deployment platform built on AWS and fully managed with Terraform. This system converts JSON prompt configurations into rendered HTML/Markdown outputs using an event-driven serverless architecture, with strict **Beta → Prod** promotion enforced via CI/CD.

Prompt configurations are uploaded to Amazon S3, processed by AWS Lambda, optionally invoked through Amazon Bedrock, and published to environment-scoped prefixes (`beta/` and `prod/`). Infrastructure, permissions, and orchestration are defined entirely as code.

---

## Outcomes

### Environment Isolation
Beta and Prod environments are isolated using strict S3 prefixes and least-privilege IAM boundaries.

### Event-Driven Execution
S3 `ObjectCreated:Put` events automatically trigger prompt processing without manual invocation.

### Model-Backed Generation
Lambda invokes Amazon Bedrock (`InvokeModel`) to generate AI-backed content.

### Infrastructure as Code
All resources (S3, Lambda, IAM, Step Functions, API Gateway) are provisioned and managed via Terraform.

### Promotion Discipline
Pull Requests deploy to **beta**; merges to `main` deploy to **prod**, ensuring only reviewed changes reach production.

---

## Architecture (High Level)

### End-to-End Flow

1. A developer uploads a prompt config JSON to:
s3://<env-bucket>/prompt_inputs/

2. An S3 event notification triggers the environment-specific **starter** Lambda.

3. The starter Lambda initiates a Step Functions execution.

4. Step Functions orchestrates the following stages:
- Render prompt from template
- Invoke Amazon Bedrock
- Publish rendered output

5. Final artifacts are written to:
s3://<env-bucket>/<env>/outputs/<slug>.(html|md)

6. *(Optional)* API Gateway exposes list, preview, and regenerate endpoints.

---

## Repository Layout

```text
infra/                          # Terraform IaC
main.tf
variables.tf
versions.tf
outputs.tf
stepfunctions.asl.json.tftpl

lambdas/                        # Lambda sources (packaged by Terraform)
starter.py                    # S3 trigger entrypoint
render.py                     # Template rendering logic
invoke_bedrock.py             # Bedrock client + retries
publish.py                    # Writes outputs to S3
api.py                        # Optional API routes

prompt_templates/               # Prompt templates
prompts/                        # Sample prompt configs
validation-screenshots/         # Execution proof screenshots
```

### Environments
## Beta

Deployed via Pull Requests

Outputs written to:
```
beta/outputs/
```
## Prod

Deployed via merges to main

Outputs written to:
```
prod/outputs/
```

### Environment Resolution

Environment selection is derived from:

Filename convention (beta-*.json, prod-*.json)

S3 object metadata (env=beta|prod)

Fallback to DEFAULT_ENV

### Deploy (Terraform)
## Local Deployment

From the infra/ directory:
```
terraform init
terraform apply
```

## Key Inputs
```
env                = beta | prod
bucket_name        = <environment-specific bucket>
bedrock_region     = us-east-1
bedrock_model_id   = <model-id>
```

### CI/CD
## PR → Beta

Deploys infrastructure changes to beta

Publishes prompt configs for validation

## Merge → Prod

Deploys infrastructure changes to prod

Publishes final rendered outputs

This enforces controlled promotion: only reviewed changes reach production.

### Validation Artifacts

Recommended high-signal proof screenshots included in validation-screenshots/:

GitHub Actions PR → Beta success

GitHub Actions Merge → Prod success

Step Functions execution graph

S3 prod/outputs/ listing

CloudWatch logs showing event-triggered execution

### Summary

This project demonstrates production-grade Infrastructure as Code, event-driven serverless design, secure IAM practices, and disciplined environment promotion for AI-backed workloads on AWS.

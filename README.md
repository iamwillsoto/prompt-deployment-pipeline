# Prompt Deployment Pipeline (Beta → Prod) — Terraform + Event-Driven Bedrock Rendering

A Terraform-managed prompt processing platform that converts JSON prompt configs into rendered HTML/Markdown outputs using an event-driven AWS architecture. Prompt configs are uploaded to S3, processed by Lambda, optionally invoked through Amazon Bedrock, and published to environment-scoped prefixes (`beta/` and `prod/`). CI/CD enforces **PR → Beta** and **Merge → Prod** promotion.

---

## Outcomes

- **Environment isolation:** Beta and Prod are separated via distinct buckets and/or strict prefixes.
- **Event-driven processing:** S3 `ObjectCreated:Put` triggers prompt rendering automatically.
- **Model-backed generation:** Lambda calls **Amazon Bedrock InvokeModel** to generate content.
- **Infrastructure as Code:** All resources (S3, Lambda, IAM, API Gateway, Step Functions) are defined in Terraform.
- **Secure-by-default:** Least-privilege IAM scoped to required bucket paths and Bedrock model ARN.
- **CI/CD promotion gates:**
  - Pull Requests deploy to **beta**
  - Merges to `main` deploy to **prod**

---

## Architecture (High Level)

1. Developer submits a prompt config JSON to `s3://<env-bucket>/prompt_inputs/`.
2. S3 event notification triggers the environment-specific Lambda entrypoint (starter/process).
3. Lambda:
   - Fetches prompt config + template from S3
   - Renders a final prompt using variables
   - Invokes Bedrock (Claude/Titan) to generate content
   - Writes the output to `s3://<env-bucket>/<env>/outputs/<slug>.(html|md)`
4. Optional endpoints:
   - API Gateway provides list/preview/regenerate routes.
5. Optional workflow:
   - Step Functions orchestrates render → invoke → publish with retries and error handling.

---

## Repo Layout

- `infra/` — Terraform IaC
  - `main.tf`, `variables.tf`, `versions.tf`, `outputs.tf`
  - `stepfunctions.asl.json.tftpl` (optional workflow definition)
- `lambdas/` — Lambda function sources (packaged by Terraform)
  - `starter.py` (S3 trigger entry)
  - `render.py` (template rendering utilities)
  - `invoke_bedrock.py` (Bedrock client + retries)
  - `publish.py` (writes outputs to S3 / optional site publish)
  - `api.py` (optional API routes: list/preview/regenerate)
- `prompt_templates/` — prompt template files (e.g., `welcome_email.txt`)
- `prompts/` — sample prompt configs
- `validation-screenshots/` — proof screenshots used in documentation

---

## Environments

- **Beta**
  - Triggered by PR deployments
  - Writes to `beta/outputs/`
- **Prod**
  - Triggered by merges to `main`
  - Writes to `prod/outputs/`

Environment selection is derived from:
- filename convention (e.g., `beta-welcome.json`, `prod-welcome.json`) and/or
- S3 object metadata `env=beta|prod`, with fallback to `DEFAULT_ENV`.

---

## Terraform: Deploy

From `infra/`:

```bash
terraform init
terraform plan
terraform apply

Key inputs (example):

env = beta or prod

bucket_name (or naming pattern)

bedrock_region, bedrock_model_id

CI/CD
PR → Beta

Workflow: .github/workflows/on_pull_request.yml

Action: deploys infra changes to beta, then publishes prompt config(s) for validation

Merge → Prod

Workflow: .github/workflows/on_merge.yml

Action: deploys infra changes to prod, then publishes prompt config(s) for validation

This enforces promotion discipline: only reviewed changes reach production.

Prompt Deployment Pipeline (Beta → Prod)

Terraform + Event-Driven Amazon Bedrock Rendering

A Terraform-managed prompt processing platform that converts JSON prompt configurations into rendered HTML/Markdown outputs using an event-driven AWS architecture. The system eliminates manual publishing, enforces promotion discipline, and enables safe AI-backed content generation across beta and production environments.

Prompt configs are uploaded to S3, processed by Lambda, optionally invoked through Amazon Bedrock, and published to environment-scoped prefixes (beta/ and prod/). CI/CD enforces PR → Beta and Merge → Prod promotion.

Outcomes

Environment isolation
Beta and Prod are separated via distinct buckets and/or strict S3 prefixes.

Event-driven processing
S3 ObjectCreated:Put events automatically trigger prompt rendering.

Model-backed generation
Lambda invokes Amazon Bedrock (InvokeModel) to generate content.

Infrastructure as Code
All resources (S3, Lambda, IAM, API Gateway, Step Functions) are defined and managed in Terraform.

Secure by default
Least-privilege IAM scoped to required bucket paths and Bedrock model ARNs.

CI/CD promotion gates

Pull Requests deploy to beta

Merges to main deploy to prod

Architecture (High Level)

Developer uploads a prompt config JSON to:
s3://<env-bucket>/prompt_inputs/

S3 event notification triggers the environment-specific Lambda entrypoint.

Lambda:

Fetches prompt config and template from S3

Renders the final prompt using variables

Invokes Amazon Bedrock (Claude / Titan)

Writes output to:
s3://<env-bucket>/<env>/outputs/<slug>.(html|md)

Optional workflow:

Step Functions orchestrates render → invoke → publish

Retries and error handling applied per step

Optional API:

API Gateway exposes list / preview / regenerate endpoints

Repository Layout

```infra/                     # Terraform IaC
  main.tf
  variables.tf
  versions.tf
  outputs.tf
  stepfunctions.asl.json.tftpl

lambdas/                   # Lambda sources (packaged by Terraform)
  starter.py
  render.py
  invoke_bedrock.py
  publish.py
  api.py

prompt_templates/          # Prompt templates
prompts/                   # Sample prompt configs
validation-screenshots/    # Execution proof screenshots
```

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

Terraform: Deploy

From infra/:

```
terraform init
terraform plan
terraform apply
```

Key inputs:

env = beta | prod

bucket_name (or naming pattern)

bedrock_region, bedrock_model_id

CI/CD
PR → Beta

Workflow: .github/workflows/on_pull_request.yml

Deploys infrastructure to beta

Publishes prompt configs for validation

Merge → Prod

Workflow: .github/workflows/on_merge.yml

Deploys infrastructure to prod

Publishes prompt configs for final output

This enforces promotion discipline: only reviewed changes reach production.

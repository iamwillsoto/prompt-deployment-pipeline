#!/usr/bin/env python3
import argparse
import json
import os
import random
import re
import time
from pathlib import Path
from typing import Dict, Any, Optional

import boto3
from botocore.exceptions import ClientError

MODEL_ID = "anthropic.claude-3-sonnet-20240229-v1:0"


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def load_text(path: Path) -> str:
    with path.open("r", encoding="utf-8") as f:
        return f.read()


def render_template(template: str, variables: Dict[str, Any]) -> str:
    rendered = template
    for k, v in variables.items():
        rendered = rendered.replace(f"{{{{{k}}}}}", str(v))

    leftovers = re.findall(r"{{\s*[\w\-]+\s*}}", rendered)
    if leftovers:
        raise ValueError(f"Unresolved template variables found: {sorted(set(leftovers))}")
    return rendered


def extract_anthropic_text(payload: Dict[str, Any]) -> Optional[str]:
    content = payload.get("content")
    if isinstance(content, list) and content:
        texts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                t = item.get("text")
                if isinstance(t, str) and t.strip():
                    texts.append(t)
        if texts:
            return "\n".join(texts)

    completion = payload.get("completion")
    if isinstance(completion, str) and completion.strip():
        return completion

    output = payload.get("output")
    if isinstance(output, dict):
        msg = output.get("message")
        if isinstance(msg, dict):
            msg_content = msg.get("content")
            if isinstance(msg_content, list) and msg_content:
                texts = []
                for item in msg_content:
                    if isinstance(item, dict):
                        t = item.get("text")
                        if isinstance(t, str) and t.strip():
                            texts.append(t)
                if texts:
                    return "\n".join(texts)

    return None


def bedrock_infer(prompt: str, max_tokens: int) -> str:
    region = os.environ.get("AWS_REGION")
    if not region:
        raise EnvironmentError("Missing AWS_REGION environment variable.")

    client = boto3.client("bedrock-runtime", region_name=region)

    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "messages": [
            {
                "role": "user",
                "content": f"""Human: {prompt}"""
            }
        ]
    }

    max_attempts = 10  # increase attempts
    for attempt in range(1, max_attempts + 1):
        try:
            resp = client.invoke_model(
                modelId=MODEL_ID,
                body=json.dumps(body).encode("utf-8"),
                contentType="application/json",
                accept="application/json",
            )

            payload = json.loads(resp["body"].read().decode("utf-8"))
            text = extract_anthropic_text(payload)
            if not text or not str(text).strip():
                preview = json.dumps(payload, ensure_ascii=False)[:800]
                raise RuntimeError(f"Bedrock response contained no usable text. Payload (trimmed): {preview}")
            return text

        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "")
            msg = e.response.get("Error", {}).get("Message", "")

            if code in ("ThrottlingException", "TooManyRequestsException"):
                # gentler backoff: start higher, cap higher
                sleep_s = min((3 ** (attempt / 2)), 45) + random.uniform(0, 2.0)
                print(f"[WARN] Bedrock throttled ({code}) attempt {attempt}/{max_attempts}. Sleeping {sleep_s:.1f}s...")
                time.sleep(sleep_s)
                continue

            raise RuntimeError(f"Bedrock InvokeModel failed: {code} - {msg}") from e

    raise RuntimeError("Bedrock did not return a response after retries.")


def wrap_html(title: str, body_text: Any) -> str:
    body_text = "" if body_text is None else str(body_text)
    safe_title = str(title).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    safe_body = body_text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br/>\n")

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>{safe_title}</title>
</head>
<body style="font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif; line-height: 1.5; margin: 2rem;">
  <h1>{safe_title}</h1>
  <div>{safe_body}</div>
</body>
</html>
"""


def upload_to_s3(bucket: str, key: str, content: str, content_type: str) -> None:
    region = os.environ.get("AWS_REGION")
    s3 = boto3.client("s3", region_name=region)
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=content.encode("utf-8"),
        ContentType=content_type,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Render prompt template, invoke Bedrock, publish output to S3.")
    parser.add_argument("--env", required=True, choices=["beta", "prod"], help="Deployment environment.")
    parser.add_argument("--config", default="prompts/welcome_prompt.json", help="Path to prompt config JSON.")
    parser.add_argument("--dry-run", action="store_true", help="Skip Bedrock call and publish deterministic placeholder.")
    args = parser.parse_args()

    env = args.env
    config_path = Path(args.config)

    bucket_beta = os.environ.get("S3_BUCKET_BETA")
    bucket_prod = os.environ.get("S3_BUCKET_PROD")
    if not bucket_beta or not bucket_prod:
        raise EnvironmentError("Missing S3_BUCKET_BETA and/or S3_BUCKET_PROD environment variables.")

    bucket = bucket_beta if env == "beta" else bucket_prod

    cfg = load_json(config_path)
    template_name = cfg["template"]
    output_format = str(cfg.get("output_format", "html")).lower()
    output_slug = cfg["output_slug"]
    variables = cfg.get("variables", {})
    max_tokens = int(cfg.get("max_tokens", 64))

    template_path = Path("prompt_templates") / template_name
    if not template_path.exists():
        raise FileNotFoundError(f"Template not found: {template_path}")

    template_text = load_text(template_path)
    rendered_prompt = render_template(template_text, variables)

    if args.dry_run:
        model_text = (
            "DRY RUN (no Bedrock call)\n\n"
            "This output validates template rendering, file generation, and S3 publishing.\n\n"
            f"Environment: {env}\n"
            f"ModelId (required by spec): {MODEL_ID}\n\n"
            "Rendered prompt preview:\n"
            "------------------------\n"
            + rendered_prompt[:800]
        )
    else:
        model_text = bedrock_infer(rendered_prompt, max_tokens=max_tokens)

    outputs_dir = Path("outputs")
    outputs_dir.mkdir(parents=True, exist_ok=True)

    if output_format == "html":
        filename = f"{output_slug}.html"
        content = wrap_html(title=output_slug, body_text=model_text)
        content_type = "text/html"
    elif output_format == "md":
        filename = f"{output_slug}.md"
        content = model_text
        content_type = "text/markdown"
    else:
        raise ValueError("output_format must be 'html' or 'md'")

    local_out = outputs_dir / filename
    local_out.write_text(content, encoding="utf-8")

    s3_key = f"{env}/outputs/{filename}"
    upload_to_s3(bucket=bucket, key=s3_key, content=content, content_type=content_type)

    print(f"[OK] env={env}")
    print(f"[OK] model_id={MODEL_ID}")
    print(f"[OK] dry_run={args.dry_run}")
    print(f"[OK] wrote_local={local_out}")
    print(f"[OK] uploaded=s3://{bucket}/{s3_key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

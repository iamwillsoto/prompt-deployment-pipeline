import json
import os
import boto3
import logging

log = logging.getLogger()
log.setLevel(logging.INFO)

s3 = boto3.client("s3")

def _read_json(bucket, key):
    obj = s3.get_object(Bucket=bucket, Key=key)
    return json.loads(obj["Body"].read().decode("utf-8"))

def _read_text(bucket, key):
    obj = s3.get_object(Bucket=bucket, Key=key)
    return obj["Body"].read().decode("utf-8")

def handler(event, context):
    bucket = event["bucket"]
    key    = event["key"]
    env    = event.get("env", os.environ.get("DEFAULT_ENV", "beta"))

    prompt_cfg = _read_json(bucket, key)

    template_name = prompt_cfg.get("template", "welcome_email.txt")
    template_key  = f"prompt_templates/{template_name}"

    template = _read_text(bucket, template_key)
    variables = prompt_cfg.get("variables", {})
    rendered = template.format(**variables)

    # output slug + format
    slug = prompt_cfg.get("output_slug") or prompt_cfg.get("slug") or key.split("/")[-1].replace(".json", "")
    output_format = prompt_cfg.get("output_format", "html").lower()
    if output_format not in ["html", "md"]:
        output_format = "html"

    max_tokens = int(prompt_cfg.get("max_tokens", 200))

    out = {
        "bucket": bucket,
        "key": key,
        "env": env,
        "slug": slug,
        "output_format": output_format,
        "max_tokens": max_tokens,
        "rendered_prompt": rendered,
        "prompt_config": prompt_cfg
    }

    log.info("Rendered prompt. env=%s slug=%s format=%s", env, slug, output_format)
    return out

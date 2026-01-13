import os
import json
import boto3
import logging

log = logging.getLogger()
log.setLevel(logging.INFO)

s3 = boto3.client("s3")

def handler(event, context):
    bucket = event["bucket"]
    env    = event.get("env", os.environ.get("DEFAULT_ENV", "beta"))
    slug   = event["slug"]
    fmt    = event.get("output_format", "html")
    model_output = event.get("model_output", "")

    # Minimal formatting: HTML or Markdown
    if fmt == "md":
        body = f"# {slug}\n\n{model_output}\n"
        content_type = "text/markdown"
        ext = "md"
    else:
        body = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{slug}</title></head>
<body><pre style="white-space:pre-wrap">{model_output}</pre></body></html>"""
        content_type = "text/html"
        ext = "html"

    out_key = f"{env}/outputs/{slug}.{ext}"

    s3.put_object(
        Bucket=bucket,
        Key=out_key,
        Body=body.encode("utf-8"),
        ContentType=content_type
    )

    log.info("Wrote output: s3://%s/%s", bucket, out_key)
    event["output_key"] = out_key
    return event

import json
import os
import time
import random
import boto3
import logging

log = logging.getLogger()
log.setLevel(logging.INFO)

def _bedrock_client():
    region = os.environ.get("BEDROCK_REGION", "us-west-2")
    return boto3.client("bedrock-runtime", region_name=region)

def _invoke_claude(model_id: str, prompt: str, max_tokens: int):
    br = _bedrock_client()

    # Claude 3 messages API payload (Bedrock)
    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}]
    }

    resp = br.invoke_model(
        modelId=model_id,
        body=json.dumps(body).encode("utf-8"),
        contentType="application/json",
        accept="application/json"
    )

    raw = resp["body"].read().decode("utf-8")
    data = json.loads(raw)

    # Extract text
    pieces = []
    for block in data.get("content", []):
        if block.get("type") == "text":
            pieces.append(block.get("text", ""))
    return "".join(pieces).strip()

def handler(event, context):
    model_id = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-sonnet-20240229-v1:0")
    max_retries = int(os.environ.get("BEDROCK_MAX_RETRIES", "6"))
    base_delay = float(os.environ.get("BEDROCK_BASE_DELAY_SECONDS", "1.5"))

    prompt = event["rendered_prompt"]
    max_tokens = int(event.get("max_tokens", 200))

    last_err = None
    for attempt in range(1, max_retries + 1):
        try:
            log.info("Invoking Bedrock model=%s attempt=%s/%s", model_id, attempt, max_retries)
            text = _invoke_claude(model_id, prompt, max_tokens)
            event["model_output"] = text
            event["model_id"] = model_id
            return event
        except Exception as e:
            last_err = e
            # exponential backoff + jitter
            sleep_s = min(30.0, base_delay * (2 ** (attempt - 1)) + random.uniform(0, 0.25))
            log.warning("Bedrock invoke failed: %s. Sleeping %.2fs", repr(e), sleep_s)
            time.sleep(sleep_s)

    raise RuntimeError(f"Bedrock did not return a response after retries. Last error: {repr(last_err)}")

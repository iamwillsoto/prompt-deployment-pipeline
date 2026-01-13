import json
import os
import boto3
import logging

log = logging.getLogger()
log.setLevel(logging.INFO)

s3 = boto3.client("s3")
sfn = boto3.client("stepfunctions")

def _response(code, body):
    return {
        "statusCode": code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body)
    }

def handler(event, context):
    bucket = os.environ["BUCKET"]
    default_env = os.environ.get("DEFAULT_ENV", "beta")
    sm_arn = os.environ["STATE_MACHINE_ARN"]

    route = event.get("routeKey", "")
    qs = event.get("queryStringParameters") or {}
    env = qs.get("env", default_env)

    if env not in ["beta", "prod"]:
        return _response(400, {"error": "env must be beta or prod"})

    if route == "GET /outputs":
        prefix = f"{env}/outputs/"
        resp = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
        items = []
        for obj in resp.get("Contents", []):
            items.append({"key": obj["Key"], "size": obj["Size"], "last_modified": obj["LastModified"].isoformat()})
        return _response(200, {"bucket": bucket, "prefix": prefix, "items": items})

    if route == "POST /regenerate":
        body = event.get("body") or "{}"
        try:
            payload = json.loads(body)
        except Exception:
            return _response(400, {"error": "invalid JSON body"})

        key = payload.get("key")
        if not key or not key.startswith("prompt_inputs/") or not key.endswith(".json"):
            return _response(400, {"error": "body.key must be a prompt_inputs/*.json key"})

        input_payload = {"bucket": bucket, "key": key, "env": env}
        resp = sfn.start_execution(stateMachineArn=sm_arn, input=json.dumps(input_payload))
        return _response(200, {"started": True, "executionArn": resp["executionArn"], "input": input_payload})

    return _response(404, {"error": "route not found"})

import json
import os
import boto3
import logging

log = logging.getLogger()
log.setLevel(logging.INFO)

sfn = boto3.client("stepfunctions")

def handler(event, context):
    log.info("Received event: %s", json.dumps(event))

    bucket = os.environ["BUCKET"]
    default_env = os.environ.get("DEFAULT_ENV", "beta")
    sm_arn = os.environ["STATE_MACHINE_ARN"]

    record = event["Records"][0]
    key = record["s3"]["object"]["key"]

    # Env detection:
    # - metadata env (preferred)
    # - filename prefix beta- / prod-
    env = default_env
    head = boto3.client("s3").head_object(Bucket=bucket, Key=key)
    meta_env = (head.get("Metadata") or {}).get("env")
    if meta_env in ["beta", "prod"]:
        env = meta_env
    else:
        filename = key.split("/")[-1]
        if filename.startswith("beta-"):
            env = "beta"
        elif filename.startswith("prod-"):
            env = "prod"

    input_payload = {
        "bucket": bucket,
        "key": key,
        "env": env
    }

    log.info("Starting SFN execution: %s", json.dumps(input_payload))
    resp = sfn.start_execution(
        stateMachineArn=sm_arn,
        input=json.dumps(input_payload)
    )

    return {"ok": True, "executionArn": resp["executionArn"]}

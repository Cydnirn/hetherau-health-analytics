"""
Hetherau InvokeEndpoint Lambda – Step Function Step 2.
Receives raw citizen data from the previous step, invokes the SageMaker
endpoint for each record, enriches the data with health classification,
stores results to DynamoDB (Analytics table), and saves CSV to S3.

Configuration from environment variables:
    ENDPOINT_NAME         – SageMaker endpoint name
    ANALYTICS_TABLE_NAME  – DynamoDB analytics table name
    BUCKET_NAME           – S3 bucket name for CSV output
    LOG_LEVEL             – Logging level (default: INFO)
"""

import csv
import io
import json
import logging
import os
from datetime import datetime, timezone

import boto3

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

sagemaker_runtime = boto3.client("sagemaker-runtime")
dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")

ENDPOINT_NAME = os.environ["ENDPOINT_NAME"]
ANALYTICS_TABLE = dynamodb.Table(os.environ["ANALYTICS_TABLE_NAME"])
BUCKET = os.environ["BUCKET_NAME"]


def lambda_handler(event, context):
    """Invoke SageMaker endpoint for batch inference and store enriched results."""
    logger.info("Starting batch inference...")

    body = event.get("body", "[]")
    if isinstance(body, str):
        data = json.loads(body)
    else:
        data = body

    results = []
    for record in data:
        try:
            # Prepare features in order: [heart_rate, o2, sleep, calories]
            features = [
                record.get("average_heart_beat_rate", 0),
                record.get("o2_content", 0),
                record.get("sleep_time", 0),
                record.get("calories_burned", 0),
            ]
            payload = json.dumps(features)

            logger.debug(f"Invoking endpoint for citizen_id={record.get('citizen_id')}")
            response = sagemaker_runtime.invoke_endpoint(
                EndpointName=ENDPOINT_NAME, ContentType="application/json", Body=payload
            )
            prediction = json.loads(response["Body"].read().decode())
            classification = "healthy" if prediction[0] < 0.5 else "unhealthy"

            inference_ts = (
                datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
            )

            enriched = {
                "citizen_id": record.get("citizen_id"),
                "timestamp": record.get("timestamp"),
                "average_heart_beat_rate": record.get("average_heart_beat_rate"),
                "o2_content": record.get("o2_content"),
                "sleep_time": record.get("sleep_time"),
                "calories_burned": record.get("calories_burned"),
                "classification": classification,
                "inference_timestamp": inference_ts,
            }
            results.append(enriched)
            ANALYTICS_TABLE.put_item(Item=enriched)
            logger.debug(f"Stored enriched record for {record.get('citizen_id')}")

        except Exception as e:
            logger.error(f"Error processing record {record.get('citizen_id')}: {e}")

    if results:
        csv_buffer = io.StringIO()
        writer = csv.DictWriter(csv_buffer, fieldnames=results[0].keys())
        writer.writeheader()
        writer.writerows(results)
        csv_key = (
            f"data/hetherau/results_"
            f"{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}.csv"
        )
        s3.put_object(Bucket=BUCKET, Key=csv_key, Body=csv_buffer.getvalue())
        logger.info(f"Saved {len(results)} results to s3://{BUCKET}/{csv_key}")

    return {"statusCode": 200, "body": json.dumps({"processed_count": len(results)})}

"""
Hetherau Kinesis Consumer Lambda.
Triggered by Kinesis Data Stream records. Validates incoming health data,
drops anomalous records, and writes clean data to DynamoDB (RawCitizenData).

Configuration from environment variables:
    TABLE_NAME  – DynamoDB table name for raw citizen data
    LOG_LEVEL   – Logging level (default: INFO)
"""

import base64
import json
import logging
import os

import boto3

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["TABLE_NAME"]
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    """Process Kinesis records and store valid citizen health data."""
    processed_count = 0
    dropped_count = 0

    for record in event["Records"]:
        try:
            payload = base64.b64decode(record["kinesis"]["data"]).decode("utf-8")
            data = json.loads(payload)

            # Anomaly detection: filter out unrealistic heart rate values
            heart_rate = data.get("average_heart_beat_rate", 0)
            if heart_rate < 40 or heart_rate > 200:
                logger.info(
                    f"Dropping anomaly: citizen_id={data.get('citizen_id')}, "
                    f"heart_rate={heart_rate}"
                )
                dropped_count += 1
                continue

            # Store clean data
            item = {
                "citizen_id": data["citizen_id"],
                "timestamp": data["timestamp"],
                "average_heart_beat_rate": heart_rate,
                "o2_content": data.get("o2_content"),
                "sleep_time": data.get("sleep_time"),
                "calories_burned": data.get("calories_burned"),
            }
            table.put_item(Item=item)
            processed_count += 1

        except Exception as e:
            logger.error(f"Error processing record: {e}")

    logger.info(f"Batch complete: {processed_count} stored, {dropped_count} dropped")
    return {"statusCode": 200}

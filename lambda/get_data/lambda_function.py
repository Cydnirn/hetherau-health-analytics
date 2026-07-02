"""
Hetherau GetData Lambda – Step Function Step 1.
Scans the RawCitizenData DynamoDB table and returns all records
as JSON for the next step (InvokeEndpoint).

Configuration from environment variables:
    TABLE_NAME  – DynamoDB table name for raw citizen data
    LOG_LEVEL   – Logging level (default: INFO)
"""

import json
import logging
import os
from decimal import Decimal

import boto3

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["TABLE_NAME"]
table = dynamodb.Table(TABLE_NAME)


def decimal_to_native(obj):
    """Recursively convert Decimal types to native Python types for JSON serialization."""
    if isinstance(obj, list):
        return [decimal_to_native(i) for i in obj]
    elif isinstance(obj, dict):
        return {k: decimal_to_native(v) for k, v in obj.items()}
    elif isinstance(obj, Decimal):
        return float(obj)
    return obj


def lambda_handler(event, context):
    """Scan the raw citizen data table and return all records."""
    logger.info("Scanning raw citizen data table...")

    response = table.scan()
    items = response["Items"]

    # Paginate through all results
    while "LastEvaluatedKey" in response:
        response = table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
        items.extend(response["Items"])

    items = decimal_to_native(items)
    logger.info(f"Retrieved {len(items)} records from raw table.")

    return {"statusCode": 200, "body": json.dumps(items)}

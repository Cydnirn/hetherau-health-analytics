"""
Hetherau GetAnalytics Lambda – API Gateway Backend.
Queries the Analytics DynamoDB table and returns all enriched records
(with health classification) as JSON for the web dashboard.

Configuration from environment variables:
    TABLE_NAME  – DynamoDB analytics table name
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
    """Scan the analytics table and return all enriched records."""
    logger.info("Fetching analytics data...")

    response = table.scan()
    items = response["Items"]

    # Paginate through all results
    while "LastEvaluatedKey" in response:
        response = table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
        items.extend(response["Items"])

    items = decimal_to_native(items)
    logger.info(f"Returning {len(items)} records from analytics table.")

    return {
        "statusCode": 200,
        "headers": {
            "Access-Control-Allow-Origin": "*",
            "Content-Type": "application/json",
        },
        "body": json.dumps(items),
    }

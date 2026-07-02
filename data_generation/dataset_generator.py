#!/usr/bin/env python3
"""
Hetherau Synthetic Dataset Generator.
Generates labelled citizen health data for training the LightGBM classifier
and uploads the CSV to the project S3 bucket.

Configuration via environment variables:
    S3_BUCKET       – Target S3 bucket name (auto-detected from CloudFormation if not set)
    S3_KEY          – S3 object key (default: data/training/training_data.csv)
    NUM_RECORDS     – Number of synthetic records to generate (default: 10000)
    RANDOM_SEED     – Random seed for reproducibility (default: 42)
"""

import logging
import os

import boto3
import numpy as np
import pandas as pd

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)


def generate_labelled_data(n=10000, random_seed=42):
    """Generate synthetic labelled citizen health data."""
    np.random.seed(random_seed)
    citizen_ids = [f"C{i:03d}" for i in range(1, n + 1)]
    heart_rate = np.random.normal(75, 15, n).clip(40, 200)
    o2 = np.random.normal(0.97, 0.02, n).clip(0.92, 1.0)
    sleep = np.random.normal(7, 1.5, n).clip(3, 12)
    calories = np.random.normal(500, 150, n).clip(200, 900)

    # Simple rule: unhealthy if heart_rate > 100 OR o2 < 0.95 OR sleep < 5
    label = np.where((heart_rate > 100) | (o2 < 0.95) | (sleep < 5), 1, 0)

    df = pd.DataFrame(
        {
            "citizen_id": citizen_ids,
            "average_heart_beat_rate": heart_rate.astype(int),
            "o2_content": o2.round(4),
            "sleep_time": sleep.round(2),
            "calories_burned": calories.astype(int),
            "label": label,
        }
    )

    return df


def find_bucket_name():
    """Try to find the Hetherau S3 bucket via CloudFormation stack outputs."""
    try:
        cf = boto3.client("cloudformation")
        stacks = cf.describe_stacks(StackName="hetherau-core")
        for output in stacks["Stacks"][0].get("Outputs", []):
            if output["OutputKey"] == "S3BucketName":
                return output["OutputValue"]
    except Exception:
        pass

    # Fallback: search for hetherau-* buckets
    try:
        s3 = boto3.client("s3")
        response = s3.list_buckets()
        for bucket in response["Buckets"]:
            if "hetherau" in bucket["Name"].lower():
                return bucket["Name"]
    except Exception:
        pass

    return None


def main():
    s3_bucket = os.environ.get("S3_BUCKET")
    s3_key = os.environ.get("S3_KEY", "data/training/training_data.csv")
    num_records = int(os.environ.get("NUM_RECORDS", "10000"))
    random_seed = int(os.environ.get("RANDOM_SEED", "42"))

    logger.info(f"Generating {num_records} synthetic records (seed={random_seed})...")
    df = generate_labelled_data(n=num_records, random_seed=random_seed)

    logger.info(f"Dataset shape: {df.shape}")
    logger.info(f"Label distribution:\n{df['label'].value_counts().to_string()}")
    logger.info(f"Sample:\n{df.head().to_string()}")

    local_file = "training_data.csv"
    df.to_csv(local_file, index=False)
    logger.info(f"Saved local CSV: {local_file} ({os.path.getsize(local_file)} bytes)")

    if not s3_bucket:
        logger.info("S3_BUCKET not set. Attempting auto-detection...")
        s3_bucket = find_bucket_name()

    if s3_bucket:
        logger.info(f"Uploading to s3://{s3_bucket}/{s3_key}...")
        s3 = boto3.client("s3")
        s3.upload_file(local_file, s3_bucket, s3_key)
        logger.info(f"Upload complete: s3://{s3_bucket}/{s3_key}")
    else:
        logger.warning(
            "Could not determine S3 bucket. "
            "Set the S3_BUCKET environment variable and run again, "
            "or upload the file manually."
        )


if __name__ == "__main__":
    main()

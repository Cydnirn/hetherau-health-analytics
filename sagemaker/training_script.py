"""
hetherau_training.py
Hetherau Health Analytics — SageMaker Training & Model Registration
Uses SageMaker built-in LightGBM algorithm to train a binary classifier,
then registers the model in SageMaker Model Registry and deploys to an endpoint.

Configuration via environment variables:
    S3_BUCKET           – S3 bucket containing Glue-processed data
    S3_TRAIN_KEY        – S3 key prefix for training CSV (default: data/train/)
    S3_VAL_KEY          – S3 key prefix for validation CSV (default: data/validation/)
    S3_OUTPUT_KEY       – S3 key prefix for model artifacts (default: output/)
    ENDPOINT_NAME       – SageMaker endpoint name (default: hetherau-endpoint)
    MODEL_GROUP_NAME    – Model Registry group name (default: hetherau-model-group)
    INSTANCE_TYPE       – Training instance type (default: ml.m5.large)
    INFERENCE_INSTANCE  – Inference instance type (default: ml.t2.medium)
    NUM_ROUND           – LightGBM boosting rounds (default: 100)
    AWS_ROLE            – SageMaker execution role ARN (required)
    AWS_REGION          – AWS region (default: us-east-1)

Prerequisites:
    - Glue ETL job must have been run to produce data/train/train.csv and
      data/validation/validation.csv
    - SageMaker execution role must have S3 read/write access
"""

import logging
import os

import boto3
from sagemaker.estimator import Estimator
from sagemaker.inputs import TrainingInput
from sagemaker.model import Model

import sagemaker

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

train_model_id, train_model_version, train_scope = (
    "lightgbm-classification-model",
    "*",
    "training",
)


def main():
    # ── Configuration ──────────────────────────────────────────
    s3_bucket = os.environ.get("S3_BUCKET")
    s3_train_key = os.environ.get("S3_TRAIN_KEY", "data/train/")
    s3_val_key = os.environ.get("S3_VAL_KEY", "data/validation/")
    s3_output_key = os.environ.get("S3_OUTPUT_KEY", "output/")
    endpoint_name = os.environ.get("ENDPOINT_NAME", "hetherau-endpoint")
    model_group_name = os.environ.get("MODEL_GROUP_NAME", "hetherau-model-group")
    instance_type = os.environ.get("INSTANCE_TYPE", "ml.m5.large")
    inference_instance = os.environ.get("INFERENCE_INSTANCE", "ml.t2.medium")
    num_round = int(os.environ.get("NUM_ROUND", "100"))
    aws_role = os.environ.get("AWS_ROLE")
    aws_region = os.environ.get("AWS_REGION", "us-east-1")

    if not s3_bucket:
        logger.error("S3_BUCKET environment variable is required.")
        return
    if not aws_role:
        logger.error(
            "AWS_ROLE environment variable is required (SageMaker execution role ARN)."
        )
        return

    # ── S3 Paths ───────────────────────────────────────────────
    train_s3_path = f"s3://{s3_bucket}/{s3_train_key}"
    val_s3_path = f"s3://{s3_bucket}/{s3_val_key}"
    output_s3_path = f"s3://{s3_bucket}/{s3_output_key}"

    logger.info("=" * 60)
    logger.info("HETHERAU HEALTH ANALYTICS — SAGEMAKER TRAINING")
    logger.info(f"  Train data:     {train_s3_path}")
    logger.info(f"  Validation:     {val_s3_path}")
    logger.info(f"  Output:         {output_s3_path}")
    logger.info(f"  Endpoint:       {endpoint_name}")
    logger.info(f"  Model group:    {model_group_name}")
    logger.info(f"  Region:         {aws_region}")
    logger.info("=" * 60)

    # ── SageMaker Session ──────────────────────────────────────
    boto_session = boto3.Session(region_name=aws_region)
    sm_session = sagemaker.Session(boto_session=boto_session)

    # ═══════════════════════════════════════════════════════════
    # STEP 1 — Retrieve LightGBM Built-in Docker Image
    # ═══════════════════════════════════════════════════════════

    logger.info("STEP 1: Retrieving LightGBM built-in algorithm image...")

    lightgbm_image = sagemaker.image_uris.retrieve(
        framework=None,
        region=aws_region,
        model_id=train_model_id,
        instance_type="ml.m5.large",
        model_version="*",
        image_scope="training",
    )

    logger.info(f"  Training image: {lightgbm_image}")

    # ═══════════════════════════════════════════════════════════
    # STEP 2 — Configure LightGBM Estimator
    # ═══════════════════════════════════════════════════════════

    logger.info("STEP 2: Configuring LightGBM estimator...")

    estimator = Estimator(
        image_uri=lightgbm_image,
        role=aws_role,
        instance_count=1,
        instance_type=instance_type,
        volume_size=10,
        max_run=7200,
        output_path=output_s3_path,
        sagemaker_session=sm_session,
        base_job_name="hetherau-training",
        hyperparameters={
            "num_round": num_round,
            "objective": "binary",
            "metric": "binary_logloss",
            "boosting": "gbdt",
            "num_leaves": 31,
            "learning_rate": 0.1,
            "feature_fraction": 0.8,
            "bagging_fraction": 0.8,
            "bagging_freq": 5,
            "min_data_in_leaf": 20,
            "early_stopping_rounds": 10,
            "seed": 42,
            "verbosity": 1,
        },
    )

    logger.info(
        f"  Instance:    {instance_type}\n"
        f"  Rounds:      {num_round}\n"
        f"  Objective:   binary\n"
        f"  Max runtime: 7200s"
    )

    # ═══════════════════════════════════════════════════════════
    # STEP 3 — Configure Data Channels
    # ═══════════════════════════════════════════════════════════

    logger.info("STEP 3: Configuring data channels...")

    train_input = TrainingInput(
        s3_data=train_s3_path,
        content_type="text/csv",
    )

    val_input = TrainingInput(
        s3_data=val_s3_path,
        content_type="text/csv",
    )

    # ═══════════════════════════════════════════════════════════
    # STEP 4 — Train the Model
    # ═══════════════════════════════════════════════════════════

    logger.info("STEP 4: Starting LightGBM training job...")
    logger.info("  This may take 5-15 minutes depending on dataset size.")

    estimator.fit(
        inputs={
            "train": train_input,
            "validation": val_input,
        },
        wait=True,
        logs="All",
    )

    training_job_name = estimator.latest_training_job.name
    logger.info(f"  Training complete: {training_job_name}")
    logger.info(f"  Model artifacts:   {estimator.model_data}")

    # ═══════════════════════════════════════════════════════════
    # STEP 5 — Create SageMaker Model Object
    # ═══════════════════════════════════════════════════════════

    logger.info("STEP 5: Creating SageMaker Model object...")

    # Retrieve the inference image (same framework, inference scope)
    lightgbm_inference_image = sagemaker.image_uris.retrieve(
        framework="lightgbm",
        region=aws_region,
        version="1.7-1",
        image_scope="inference",
    )

    model = Model(
        image_uri=lightgbm_inference_image,
        model_data=estimator.model_data,
        role=aws_role,
        sagemaker_session=sm_session,
        name=f"hetherau-model-{training_job_name[-8:]}",
    )

    logger.info(f"  Inference image: {lightgbm_inference_image}")
    logger.info(f"  Model name:      {model.name}")

    # ═══════════════════════════════════════════════════════════
    # STEP 6 — Register Model in SageMaker Model Registry
    # ═══════════════════════════════════════════════════════════

    logger.info("STEP 6: Registering model in SageMaker Model Registry...")

    sm_client = boto3.client("sagemaker", region_name=aws_region)

    # Ensure model package group exists
    try:
        sm_client.create_model_package_group(
            ModelPackageGroupName=model_group_name,
            ModelPackageGroupDescription=(
                "Hetherau Health Analytics — LightGBM binary classifier "
                "for citizen health risk prediction"
            ),
        )
        logger.info(f"  Created model package group: {model_group_name}")
    except sm_client.exceptions.ClientError as e:
        if "already exists" in str(e).lower():
            logger.info(f"  Model package group already exists: {model_group_name}")
        else:
            raise

    # Register the model version
    model_package = model.register(
        content_types=["text/csv"],
        response_types=["text/csv"],
        inference_instances=[inference_instance, "ml.m5.large"],
        transform_instances=["ml.m5.large"],
        model_package_group_name=model_group_name,
        approval_status="PendingManualApproval",
        description=(
            f"LightGBM citizen health classifier — "
            f"binary (healthy/unhealthy), {num_round} rounds, "
            f"trained on {train_s3_path}"
        ),
    )

    logger.info(f"  Model registered: {model_package.model_package_arn}")
    logger.info("  Approval status:  PendingManualApproval")
    logger.info("  → Approve the model in SageMaker Studio > Model Registry to deploy.")

    # ═══════════════════════════════════════════════════════════
    # STEP 7 — Deploy Model to Endpoint (optional, auto-approve)
    # ═══════════════════════════════════════════════════════════

    logger.info("STEP 7: Deploying model to SageMaker endpoint...")

    try:
        predictor = model.deploy(
            initial_instance_count=1,
            instance_type=inference_instance,
            endpoint_name=endpoint_name,
            wait=True,
        )
        logger.info(f"  Endpoint deployed: {endpoint_name}")
        logger.info(f"  Instance type:     {inference_instance}")
        logger.info("  → Endpoint is ready for inference requests.")
    except Exception as e:
        logger.warning(f"  Endpoint deployment skipped: {e}")
        logger.info(
            "  → Deploy manually via SageMaker Console or approve the registered model."
        )

    # ═══════════════════════════════════════════════════════════
    # SUMMARY
    # ═══════════════════════════════════════════════════════════

    logger.info("=" * 60)
    logger.info("HETHERAU SAGEMAKER TRAINING COMPLETE")
    logger.info(f"  Training job:   {training_job_name}")
    logger.info(f"  Model data:     {estimator.model_data}")
    logger.info(f"  Model group:    {model_group_name}")
    logger.info(f"  Registered ARN: {model_package.model_package_arn}")
    logger.info(f"  Endpoint:       {endpoint_name}")
    logger.info("")
    logger.info("Next steps:")
    logger.info("  1. Approve model in SageMaker Studio > Model Registry")
    logger.info("  2. OR deploy approved version manually to the endpoint")
    logger.info(f"  3. Test inference with a sample request to {endpoint_name}")
    logger.info("=" * 60)


if __name__ == "__main__":
    main()

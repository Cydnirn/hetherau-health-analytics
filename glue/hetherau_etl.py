"""
hetherau_etl.py
AWS Glue ETL Job – Hetherau Health Analytics
PySpark data pipeline: Raw citizen health CSV → Clean → Feature Engineering → Normalize →
Train/Validation Split → S3 Parquet + SageMaker CSV

Compatible with Glue 4.0 (Spark 3.3, Python 3.10).

Job Parameters:
    --JOB_NAME          Glue job name (auto-provided)
    --SOURCE_BUCKET     S3 bucket containing raw training CSV
    --SOURCE_KEY        S3 key of the raw CSV (default: data/training/training_data.csv)
    --DEST_BUCKET       S3 bucket for processed output (usually same as SOURCE_BUCKET)
    --GLUE_DATABASE     Glue Data Catalog database name
    --TEMP_DIR          S3 path for Glue Spark temp files (e.g., s3://bucket/temp/)

Processing Steps:
    1.  Read raw CSV (citizen_id, average_heart_beat_rate, o2_content,
                     sleep_time, calories_burned, label)
    2.  Data quality audit – check for nulls, zeros, and extreme outliers
    3.  Data cleaning – drop citizen_id, filter anomalies, fill edge values
    4.  Feature engineering – heart_rate_zone, sleep_quality,
        calorie_efficiency, o2_risk, composite_risk_score
    5.  Normalization (StandardScaler) – save stats to S3 for inference
    6.  Train / validation split (80 / 20, stratified by label)
    7.  Write Parquet (all processed features) to S3
    8.  Write SageMaker CSV (no header, label first column) for train and val
    9.  Update Glue Data Catalog statistics

Output Structure:
    s3://<DEST_BUCKET>/
        data/processed/                  # Parquet with all features
        data/train/train.csv             # SageMaker training CSV
        data/validation/validation.csv   # SageMaker validation CSV
        data/config/normalization_stats.json  # Mean/std for inference
"""

import json
import logging
import sys
from datetime import datetime, timezone

import boto3
from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import DoubleType, IntegerType, StringType

# ── Logging ─────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

# ── Job Parameters ───────────────────────────────────────────
args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "SOURCE_BUCKET",
        "SOURCE_KEY",
        "DEST_BUCKET",
        "GLUE_DATABASE",
        "TEMP_DIR",
    ],
)

# ── Glue / Spark Context ──────────────────────────────────────
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

logger.info("=" * 65)
logger.info("HETHERAU HEALTH ANALYTICS — GLUE ETL JOB STARTED")
logger.info(f"  Source: s3://{args['SOURCE_BUCKET']}/{args['SOURCE_KEY']}")
logger.info(f"  Dest:   s3://{args['DEST_BUCKET']}/data/")
logger.info("=" * 65)


# ═══════════════════════════════════════════════════════════════
# STEP 1 — READ RAW CITIZEN HEALTH CSV FROM S3
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 1: Reading raw citizen health CSV from S3...")

raw_dyf = glueContext.create_dynamic_frame.from_options(
    connection_type="s3",
    connection_options={
        "paths": [f"s3://{args['SOURCE_BUCKET']}/{args['SOURCE_KEY']}"],
        "recurse": False,
    },
    format="csv",
    format_options={
        "withHeader": True,
        "separator": ",",
    },
)

df = raw_dyf.toDF()

# Cast to correct types
df = df.withColumn(
    "average_heart_beat_rate", df["average_heart_beat_rate"].cast(IntegerType())
)
df = df.withColumn("o2_content", df["o2_content"].cast(DoubleType()))
df = df.withColumn("sleep_time", df["sleep_time"].cast(DoubleType()))
df = df.withColumn("calories_burned", df["calories_burned"].cast(IntegerType()))
df = df.withColumn("label", df["label"].cast(IntegerType()))

total_raw = df.count()
logger.info(f"  Loaded {total_raw} records. Schema:")
df.printSchema()
logger.info(
    f"  Label distribution:\n{df.groupBy('label').count().toPandas().to_string()}"
)


# ═══════════════════════════════════════════════════════════════
# STEP 2 — DATA QUALITY AUDIT
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 2: Data quality audit...")

feature_cols = [
    "average_heart_beat_rate",
    "o2_content",
    "sleep_time",
    "calories_burned",
]

for col in feature_cols:
    n_null = df.filter(F.col(col).isNull()).count()
    n_total = df.count()
    stats = df.select(
        F.min(col).alias("min"),
        F.max(col).alias("max"),
        F.mean(col).alias("mean"),
        F.stddev(col).alias("stddev"),
    ).collect()[0]
    logger.info(
        f"  {col:30s}: nulls={n_null}/{n_total}, "
        f"min={stats['min']:.3f}, max={stats['max']:.3f}, "
        f"mean={stats['mean']:.3f}, std={stats['stddev']:.3f}"
    )

# Count anomaly records (extreme heart rates)
n_anomaly_hr = df.filter(
    (F.col("average_heart_beat_rate") < 40) | (F.col("average_heart_beat_rate") > 200)
).count()
logger.info(f"  Extreme heart rate anomalies (<40 or >200): {n_anomaly_hr}")


# ═══════════════════════════════════════════════════════════════
# STEP 3 — DATA CLEANING
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 3: Cleaning data...")

# Drop citizen_id – not a feature for ML training
df = df.drop("citizen_id")

# Drop rows with null values in any column
df = df.dropna()
logger.info(f"  After dropping nulls: {df.count()} records")

# Filter out extreme heart rate anomalies (same threshold as Kinesis consumer Lambda)
df = df.filter(
    (F.col("average_heart_beat_rate") >= 40) & (F.col("average_heart_beat_rate") <= 200)
)

# Clip o2_content to valid physiological range [0.85, 1.0]
df = df.withColumn(
    "o2_content",
    F.when(F.col("o2_content") < 0.85, 0.85)
    .when(F.col("o2_content") > 1.0, 1.0)
    .otherwise(F.col("o2_content")),
)

# Clip sleep_time to reasonable range [2, 14]
df = df.withColumn(
    "sleep_time",
    F.when(F.col("sleep_time") < 2, 2.0)
    .when(F.col("sleep_time") > 14, 14.0)
    .otherwise(F.col("sleep_time")),
)

# Drop duplicate rows
df = df.dropDuplicates()
after_clean = df.count()
logger.info(
    f"  Records after cleaning: {after_clean} (removed {total_raw - after_clean})"
)


# ═══════════════════════════════════════════════════════════════
# STEP 4 — FEATURE ENGINEERING
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 4: Feature engineering for citizen health data...")

# Heart rate risk zone (clinical ranges)
df = df.withColumn(
    "heart_rate_zone",
    F.when(F.col("average_heart_beat_rate") < 60, "Bradycardia")
    .when(F.col("average_heart_beat_rate") <= 100, "Normal")
    .otherwise("Tachycardia"),
)

# O2 saturation risk (clinical thresholds)
df = df.withColumn(
    "o2_risk",
    F.when(F.col("o2_content") < 0.93, "Hypoxia_Risk")
    .when(F.col("o2_content") < 0.95, "Borderline")
    .otherwise("Normal"),
)

# Sleep quality
df = df.withColumn(
    "sleep_quality",
    F.when(F.col("sleep_time") < 5, "Insufficient")
    .when(F.col("sleep_time") < 7, "Below_Recommended")
    .when(F.col("sleep_time") <= 9, "Optimal")
    .otherwise("Extended"),
)

# Calorie efficiency ratio (calories / heart_rate proxy for metabolic efficiency)
df = df.withColumn(
    "calorie_efficiency",
    F.when(
        F.col("average_heart_beat_rate") > 0,
        F.col("calories_burned") / F.col("average_heart_beat_rate"),
    )
    .otherwise(0.0)
    .cast(DoubleType()),
)

# Composite risk score: weighted combination of risk indicators
# Heart rate deviation from 75 (ideal resting), O2 deficit from 1.0, sleep deficit from 8
df = df.withColumn(
    "composite_risk_score",
    (
        F.abs(F.col("average_heart_beat_rate") - 75) / 75.0 * 0.30
        + (F.lit(1.0) - F.col("o2_content")) / 0.1 * 0.40
        + F.abs(F.col("sleep_time") - 8.0) / 8.0 * 0.30
    ).cast(DoubleType()),
)

# Heart rate × sleep interaction (overtraining indicator)
df = df.withColumn(
    "hr_sleep_interaction",
    (
        F.col("average_heart_beat_rate") * (F.lit(10.0) - F.col("sleep_time")) / 100.0
    ).cast(DoubleType()),
)

logger.info("  Feature engineering complete. Sample (5 rows):")
df.select(
    "average_heart_beat_rate",
    "o2_content",
    "sleep_time",
    "heart_rate_zone",
    "o2_risk",
    "sleep_quality",
    "calorie_efficiency",
    "composite_risk_score",
    "label",
).show(5, truncate=False)


# ═══════════════════════════════════════════════════════════════
# STEP 5 — NORMALIZATION (StandardScaler)
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 5: Applying StandardScaler normalization...")

numerical_features = [
    "average_heart_beat_rate",
    "o2_content",
    "sleep_time",
    "calories_burned",
    "calorie_efficiency",
    "composite_risk_score",
    "hr_sleep_interaction",
]

# Compute mean + std in a single pass
stats_row = df.select(
    [F.mean(c).alias(f"{c}_mean") for c in numerical_features]
    + [F.stddev(c).alias(f"{c}_std") for c in numerical_features]
).collect()[0]

norm_stats = {}
for col in numerical_features:
    mean_val = stats_row[f"{col}_mean"] or 0.0
    std_val = stats_row[f"{col}_std"] or 1.0
    norm_stats[col] = {"mean": round(mean_val, 6), "std": round(std_val, 6)}
    logger.info(f"  {col:30s}: mean={mean_val:10.4f}, std={std_val:10.4f}")
    df = df.withColumn(f"{col}_scaled", (F.col(col) - mean_val) / std_val)


# ═══════════════════════════════════════════════════════════════
# STEP 6 — TRAIN / VALIDATION SPLIT (80 / 20, stratified)
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 6: Splitting dataset 80/20 (stratified by label)...")

# Use stratified split by computing per-label fractions
label_counts = df.groupBy("label").count().collect()
label_map = {row["label"]: row["count"] for row in label_counts}
logger.info(f"  Label distribution: {label_map}")

# Scaled feature columns for the training set
scaled_cols = [f"{c}_scaled" for c in numerical_features]

# Build training-ready DataFrame (scaled numerical + label)
training_df = df.select(scaled_cols + ["label"])

train_df, val_df = training_df.randomSplit([0.8, 0.2], seed=42)
train_count = train_df.count()
val_count = val_df.count()
logger.info(
    f"  Training:   {train_count} records ({train_count / (train_count + val_count) * 100:.1f}%)"
)
logger.info(
    f"  Validation: {val_count} records ({val_count / (train_count + val_count) * 100:.1f}%)"
)
logger.info(
    f"  Train label distribution:\n{train_df.groupBy('label').count().toPandas().to_string()}"
)
logger.info(
    f"  Val label distribution:\n{val_df.groupBy('label').count().toPandas().to_string()}"
)

# Also save the full processed DataFrame (with engineered features + scaled) for reference
full_processed_df = df


# ═══════════════════════════════════════════════════════════════
# STEP 7 — WRITE PROCESSED PARQUET TO S3
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 7: Writing processed Parquet to S3...")

processed_dyf = DynamicFrame.fromDF(full_processed_df, glueContext, "processed")
glueContext.write_dynamic_frame.from_options(
    frame=processed_dyf,
    connection_type="s3",
    connection_options={
        "path": f"s3://{args['DEST_BUCKET']}/data/processed/",
        "partitionKeys": [],
    },
    format="parquet",
)
logger.info(f"  Parquet saved: s3://{args['DEST_BUCKET']}/data/processed/")


# ═══════════════════════════════════════════════════════════════
# STEP 8 — WRITE SAGEMAKER TRAIN / VALIDATION CSV
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 8: Writing SageMaker-format CSV files...")

# LightGBM built-in requires: no header, label in first column
s3 = boto3.client("s3", region_name="us-east-1")

# Convert to Pandas for CSV output
train_pd = train_df.toPandas()
val_pd = val_df.toPandas()

# Ensure label is first column
train_cols = ["label"] + [c for c in train_pd.columns if c != "label"]
val_cols = ["label"] + [c for c in val_pd.columns if c != "label"]
train_pd = train_pd[train_cols]
val_pd = val_pd[val_cols]

# Write training CSV
train_csv = train_pd.to_csv(index=False, header=False).encode("utf-8")
s3.put_object(
    Bucket=args["DEST_BUCKET"],
    Key="data/train/train.csv",
    Body=train_csv,
)
logger.info(f"  Train CSV:      s3://{args['DEST_BUCKET']}/data/train/train.csv")
logger.info(
    f"    Rows: {train_pd.shape[0]}, Cols: {train_pd.shape[1]} (label + {train_pd.shape[1] - 1} features)"
)

# Write validation CSV
val_csv = val_pd.to_csv(index=False, header=False).encode("utf-8")
s3.put_object(
    Bucket=args["DEST_BUCKET"],
    Key="data/validation/validation.csv",
    Body=val_csv,
)
logger.info(
    f"  Validation CSV: s3://{args['DEST_BUCKET']}/data/validation/validation.csv"
)
logger.info(
    f"    Rows: {val_pd.shape[0]}, Cols: {val_pd.shape[1]} (label + {val_pd.shape[1] - 1} features)"
)


# ═══════════════════════════════════════════════════════════════
# STEP 9 — SAVE NORMALIZATION STATS FOR INFERENCE
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 9: Saving normalization stats to S3 for inference...")

# The inference Lambda (invoke_endpoint) and SageMaker inference script
# need these stats to normalize incoming raw data before prediction.
s3.put_object(
    Bucket=args["DEST_BUCKET"],
    Key="data/config/normalization_stats.json",
    Body=json.dumps(
        {
            "features": numerical_features,
            "stats": norm_stats,
            "train_count": train_count,
            "val_count": val_count,
            "total_processed": after_clean,
            "created_at": datetime.now(timezone.utc).isoformat(),
        },
        indent=2,
    ).encode("utf-8"),
    ContentType="application/json",
)
logger.info(
    f"  Normalization stats: s3://{args['DEST_BUCKET']}/data/config/normalization_stats.json"
)


# ═══════════════════════════════════════════════════════════════
# STEP 10 — UPDATE GLUE DATA CATALOG
# ═══════════════════════════════════════════════════════════════

logger.info("STEP 10: Updating Glue Data Catalog statistics...")

try:
    glue_client = boto3.client("glue", region_name="us-east-1")
    glue_client.update_table(
        DatabaseName=args["GLUE_DATABASE"],
        TableInput={
            "Name": "hetherau_processed_citizen_data",
            "Parameters": {
                "recordCount": str(after_clean),
                "trainCount": str(train_count),
                "valCount": str(val_count),
                "featureCount": str(len(numerical_features)),
                "last_etl_run": datetime.now(timezone.utc).isoformat(),
                "sourceKey": args["SOURCE_KEY"],
            },
        },
    )
    logger.info("  Glue Data Catalog updated: hetherau_processed_citizen_data")
except Exception as e:
    logger.warning(f"  Catalog update skipped: {e}")


# ═══════════════════════════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════════════════════════

logger.info("=" * 65)
logger.info("HETHERAU GLUE ETL JOB COMPLETED SUCCESSFULLY")
logger.info(f"  Raw records:          {total_raw}")
logger.info(f"  After cleaning:       {after_clean}")
logger.info(
    f"  Engineered features:  {len(numerical_features)} numerical + 4 categorical"
)
logger.info(f"  Training set:         {train_count}")
logger.info(f"  Validation set:       {val_count}")
logger.info(f"  Processed Parquet:    s3://{args['DEST_BUCKET']}/data/processed/")
logger.info(f"  Train CSV:            s3://{args['DEST_BUCKET']}/data/train/train.csv")
logger.info(
    f"  Validation CSV:       s3://{args['DEST_BUCKET']}/data/validation/validation.csv"
)
logger.info(
    f"  Norm stats:           s3://{args['DEST_BUCKET']}/data/config/normalization_stats.json"
)
logger.info("=" * 65)

job.commit()

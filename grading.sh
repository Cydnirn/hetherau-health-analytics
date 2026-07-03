#!/bin/bash
# =============================================================================
# Hetherau Health Analytics – Grading & Validation Script
# =============================================================================
# Evaluates the deployed Hetherau infrastructure by checking:
#   1. CloudFormation stack existence and health
#   2. All resources use the 'hetherau' naming prefix
#   3. All required AWS resources exist and are in the correct state
#   4. Resources deployed via CloudFormation earn full points; manual deployment
#      earns reduced points (except Step Functions, which is exempt)
#
# Scoring:
#   +2 pts = Resource exists AND deployed via CloudFormation (or exempt)
#   +1 pt  = Resource exists but NOT deployed via CloudFormation (manual)
#   +0 pts = Resource is missing
#
# Usage:
#   chmod +x grading.sh
#   ./grading.sh [--stack-name hetherau-core] [--prefix hetherau] [--region us-east-1]
#
# Prerequisites:
#   - AWS CLI installed and configured (`aws configure`)
#   - jq installed (`sudo apt-get install jq` or `brew install jq`)
# =============================================================================

set -o pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
STACK_NAME="${STACK_NAME:-hetherau-core}"
NAMING_PREFIX="${NAMING_PREFIX:-hetherau}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-30}"  # seconds before timing out individual checks

# Score Tracking
TOTAL_POINTS=0
EARNED_POINTS=0
declare -A SECTION_SCORES
SECTION_PASS_COUNT=0
SECTION_TOTAL_COUNT=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Helper Functions ───────────────────────────────────────────────────────

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BOLD}${BLUE}--- $1 ---${NC}"
}

# Evaluate a metric: +2 pts for pass, +0 for fail
# Usage: evaluate "Section" "SubSection" "Check Description" 0|1|2|3
#   0 = pass (+2 pts, CF-managed or exempt)
#   1 = fail (+0 pts, missing)
#   2 = manual (+1 pt, exists but NOT deployed via CloudFormation)
#   3 = warn/skipped (+1 pt)
evaluate() {
    local section="$1"
    local subsection="$2"
    local check_name="$3"
    local status="${4:-1}"  # 0=pass, 1=fail, 2=manual, 3=warn

    TOTAL_POINTS=$((TOTAL_POINTS + 2))
    SECTION_TOTAL_COUNT=$((SECTION_TOTAL_COUNT + 1))

    printf "  ${CYAN}[%-15s]${NC} %-30s " "$subsection" "$check_name"

    case "$status" in
        0)
            echo -e "-> ${GREEN}PASS (+2 pts)${NC}"
            EARNED_POINTS=$((EARNED_POINTS + 2))
            SECTION_PASS_COUNT=$((SECTION_PASS_COUNT + 1))
            ;;
        2)
            echo -e "-> ${YELLOW}MANUAL (+1 pt) — not deployed via CloudFormation${NC}"
            EARNED_POINTS=$((EARNED_POINTS + 1))
            ;;
        3)
            echo -e "-> ${YELLOW}WARN (+1 pt)${NC}"
            EARNED_POINTS=$((EARNED_POINTS + 1))
            ;;
        *)
            echo -e "-> ${RED}FAIL (+0 pts)${NC}"
            ;;
    esac
}

# Check if a value is non-empty and not "None"
is_valid() {
    local val="$1"
    [[ -n "$val" && "$val" != "None" && "$val" != "null" ]]
}

# Check if a resource name contains the naming prefix
has_prefix() {
    local name="$1"
    [[ "$name" == *"${NAMING_PREFIX}"* || "$name" == *"${NAMING_PREFIX^}"* || "$name" == *"${NAMING_PREFIX^^}"* ]]
}

# Run AWS CLI command with timeout and error handling
aws_safe() {
    aws --region "$AWS_REGION" --no-cli-pager "$@" 2>/dev/null
}

# ─── CloudFormation Resource Tracking ────────────────────────────────────────
# Build a lookup table of physical resource IDs managed by the CloudFormation stack.
# Used to determine whether each resource was deployed via CF or manually.
# Key format: physical_resource_id (or logical ID as fallback)

# Global variables populated later after stack is queried
declare -A CF_RESOURCE_MAP  # physical_id -> resource_type
CF_STACK_EXISTS=false

# Populate the CF resource map from the stack
build_cf_resource_map() {
    local stack_name="$1"
    local resources_json
    resources_json=$(aws_safe cloudformation list-stack-resources --stack-name "$stack_name" 2>/dev/null)

    if ! echo "$resources_json" | jq -e '.StackResourceSummaries' &>/dev/null; then
        return 1
    fi

    CF_STACK_EXISTS=true

    # Read each resource into the map
    local count
    count=$(echo "$resources_json" | jq '.StackResourceSummaries | length' 2>/dev/null || echo "0")

    for ((i=0; i<count; i++)); do
        local physical_id
        local logical_id
        local resource_type
        physical_id=$(echo "$resources_json" | jq -r ".StackResourceSummaries[$i].PhysicalResourceId // empty" 2>/dev/null)
        logical_id=$(echo "$resources_json" | jq -r ".StackResourceSummaries[$i].LogicalResourceId // empty" 2>/dev/null)
        resource_type=$(echo "$resources_json" | jq -r ".StackResourceSummaries[$i].ResourceType // empty" 2>/dev/null)

        # Index by physical ID (most AWS resources use ARN or name as physical ID)
        if is_valid "$physical_id"; then
            CF_RESOURCE_MAP["$physical_id"]="$resource_type"
        fi
        # Also index by logical ID (for resources whose physical ID might differ)
        if is_valid "$logical_id"; then
            CF_RESOURCE_MAP["logical:$logical_id"]="$resource_type"
        fi
    done

    return 0
}

# Check if a given resource name/ARN is in the CloudFormation stack.
# Searches both exact physical IDs and partial name matches.
# Returns 0 (true) if found in CF, 1 (false) if not.
is_resource_in_cf_stack() {
    local search_term="$1"

    if ! $CF_STACK_EXISTS; then
        return 1
    fi

    # Exact match on physical ID
    if [[ -n "${CF_RESOURCE_MAP[$search_term]}" ]]; then
        return 0
    fi

    # Substring match: check if any key contains the search term
    for key in "${!CF_RESOURCE_MAP[@]}"; do
        if [[ "$key" == *"$search_term"* ]]; then
            return 0
        fi
    done

    return 1
}

# Shorthand: check CF status and return evaluate status code
# 0 = CF-managed (full points), 2 = exists but manual (reduced points), 1 = missing
# Usage: cf_status=$(check_cf_deployment "resource_name_or_arn")
check_cf_deployment() {
    local resource_id="$1"
    if ! is_valid "$resource_id"; then
        echo "1"  # missing
    elif is_resource_in_cf_stack "$resource_id"; then
        echo "0"  # CF-managed
    else
        echo "2"  # exists but manual
    fi
}

# ─── Pre-flight Checks ──────────────────────────────────────────────────────

print_header "Hetherau Health Analytics – Grading & Validation"
echo "  Stack Name:    ${STACK_NAME}"
echo "  Naming Prefix: ${NAMING_PREFIX}"
echo "  AWS Region:    ${AWS_REGION}"
echo "  Time:          $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Check prerequisites
print_section "Pre-flight Checks"

if ! command -v aws &> /dev/null; then
    echo -e "  ${RED}ERROR: AWS CLI is not installed.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓ AWS CLI found${NC}: $(aws --version 2>&1 | head -1)"

if ! command -v jq &> /dev/null; then
    echo -e "  ${YELLOW}⚠ jq is not installed. JSON parsing will be limited.${NC}"
    echo -e "  ${YELLOW}  Install: apt-get install jq  or  brew install jq${NC}"
    USE_JQ=false
else
    USE_JQ=true
    echo -e "  ${GREEN}✓ jq found${NC}: $(jq --version)"
fi

# Check AWS credentials
AWS_ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null)
if ! is_valid "$AWS_ACCOUNT"; then
    echo -e "  ${RED}ERROR: AWS credentials not configured or expired.${NC}"
    echo -e "  ${RED}  Run 'aws configure' to set up your credentials.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓ AWS credentials valid${NC} (Account: ${AWS_ACCOUNT})"
echo ""

# =============================================================================
# SECTION 1: CloudFormation Stack Verification
# =============================================================================
print_header "SECTION 1: CloudFormation Stack Verification (12 pts)"

print_section "Stack Existence"

STACK_JSON=$(aws_safe cloudformation describe-stacks --stack-name "$STACK_NAME")
STACK_STATUS=$(echo "$STACK_JSON" | jq -r '.Stacks[0].StackStatus // "NOT_FOUND"' 2>/dev/null)
STACK_ID=$(echo "$STACK_JSON" | jq -r '.Stacks[0].StackId // empty' 2>/dev/null)
STACK_CREATION_TIME=$(echo "$STACK_JSON" | jq -r '.Stacks[0].CreationTime // empty' 2>/dev/null)
STACK_DESC=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Description // empty' 2>/dev/null)

if is_valid "$STACK_ID"; then
    evaluate "CloudFormation" "Stack" "Stack '${STACK_NAME}' exists" 0
else
    evaluate "CloudFormation" "Stack" "Stack '${STACK_NAME}' exists" 1
    echo ""
    echo -e "  ${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}║  CRITICAL: CloudFormation stack not found!              ║${NC}"
    echo -e "  ${RED}║  The stack '${STACK_NAME}' does not exist in ${AWS_REGION}.${NC}"
    echo -e "  ${RED}║  Deploy it first:                                       ║${NC}"
    echo -e "  ${RED}║    aws cloudformation create-stack \\                    ║${NC}"
    echo -e "  ${RED}║      --stack-name ${STACK_NAME} \\                       ║${NC}"
    echo -e "  ${RED}║      --template-body file://cloudformation/template.yaml \\${NC}"
    echo -e "  ${RED}║      --capabilities CAPABILITY_IAM                       ║${NC}"
    echo -e "  ${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    # Continue checking – some resources might exist even without CF
fi

print_section "Stack Health"
if is_valid "$STACK_STATUS"; then
    case "$STACK_STATUS" in
        CREATE_COMPLETE|UPDATE_COMPLETE)
            evaluate "CloudFormation" "Health" "Stack status is healthy (${STACK_STATUS})" 0
            ;;
        CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS)
            evaluate "CloudFormation" "Health" "Stack is in progress (${STACK_STATUS})" 3
            ;;
        ROLLBACK_*|DELETE_*|*_FAILED)
            evaluate "CloudFormation" "Health" "Stack status is unhealthy (${STACK_STATUS})" 1
            ;;
        *)
            evaluate "CloudFormation" "Health" "Stack status: ${STACK_STATUS}" 1
            ;;
    esac
else
    evaluate "CloudFormation" "Health" "Stack health check" 1
fi

print_section "Stack Description"
if is_valid "$STACK_DESC" && echo "$STACK_DESC" | grep -qi "hetherau"; then
    evaluate "CloudFormation" "Metadata" "Stack description mentions Hetherau" 0
else
    evaluate "CloudFormation" "Metadata" "Stack description mentions Hetherau" 1
fi

print_section "Stack Resource Count"
STACK_RESOURCE_COUNT=$(echo "$STACK_JSON" | jq '.Stacks[0].Outputs | length' 2>/dev/null || echo "0")
# Count all resources via list-stack-resources
STACK_RESOURCES_JSON=$(aws_safe cloudformation list-stack-resources --stack-name "$STACK_NAME" 2>/dev/null)
STACK_TOTAL_RESOURCES=$(echo "$STACK_RESOURCES_JSON" | jq '.StackResourceSummaries | length' 2>/dev/null || echo "0")

if [ "$STACK_TOTAL_RESOURCES" -gt 0 ] 2>/dev/null; then
    evaluate "CloudFormation" "Resources" "Stack contains ${STACK_TOTAL_RESOURCES} resources" 0
else
    evaluate "CloudFormation" "Resources" "Stack contains resources" 1
fi

print_section "Stack Outputs"
STACK_OUTPUT_COUNT=$(echo "$STACK_JSON" | jq '.Stacks[0].Outputs | length' 2>/dev/null || echo "0")
if [ "$STACK_OUTPUT_COUNT" -ge 5 ] 2>/dev/null; then
    evaluate "CloudFormation" "Outputs" "Stack has ${STACK_OUTPUT_COUNT} outputs (expected ≥5)" 0
else
    evaluate "CloudFormation" "Outputs" "Stack has ${STACK_OUTPUT_COUNT}/5 expected outputs" 1
fi

# Check stack tags
STACK_TAGS=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Tags // []' 2>/dev/null)
HAS_PROJECT_TAG=$(echo "$STACK_TAGS" | jq -r '.[] | select(.Key=="Project" and (.Value | test("hetherau"; "i"))) | .Value' 2>/dev/null)
if is_valid "$HAS_PROJECT_TAG"; then
    evaluate "CloudFormation" "Tags" "Stack has Project=hetherau tag" 0
else
    evaluate "CloudFormation" "Tags" "Stack has Project=hetherau tag" 1
fi

# Build the CF resource lookup map for per-resource origin checks
if is_valid "$STACK_ID"; then
    build_cf_resource_map "$STACK_NAME"
    echo -e "  ${GREEN}✓ CF resource map built${NC}: ${#CF_RESOURCE_MAP[@]} entries indexed"
else
    echo -e "  ${YELLOW}⚠ No CF stack – all resources will be graded as manual deployment${NC}"
fi

# =============================================================================
# SECTION 2: S3 Bucket
# =============================================================================
print_header "SECTION 2: S3 Storage (8 pts)"

print_section "Bucket Detection"
# Try to find bucket from CloudFormation output first
S3_BUCKET=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="S3BucketName") | .OutputValue' 2>/dev/null)

# Fallback: search for hetherau buckets
if ! is_valid "$S3_BUCKET"; then
    S3_BUCKET=$(aws_safe s3api list-buckets --query "Buckets[?contains(Name, '${NAMING_PREFIX}')].Name | [0]" --output text 2>/dev/null)
fi

if is_valid "$S3_BUCKET"; then
    evaluate "Storage" "S3" "S3 bucket found: ${S3_BUCKET}" 0
else
    evaluate "Storage" "S3" "S3 bucket found (hetherau-*)" 1
    echo -e "  ${YELLOW}  (No hetherau-prefixed bucket found in this account/region)${NC}"
fi

print_section "Bucket Properties"
if is_valid "$S3_BUCKET"; then
    BUCKET_REGION=$(aws_safe s3api get-bucket-location --bucket "$S3_BUCKET" --query "LocationConstraint" --output text)
    if is_valid "$BUCKET_REGION" && [ "$BUCKET_REGION" != "None" ]; then
        evaluate "Storage" "S3" "Bucket region: ${BUCKET_REGION}" 0
    elif [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ]; then
        evaluate "Storage" "S3" "Bucket region: us-east-1 (default)" 0
    else
        evaluate "Storage" "S3" "Bucket region determined" 0
    fi
else
    evaluate "Storage" "S3" "Bucket region determined" 1
fi

print_section "Bucket Naming"
if is_valid "$S3_BUCKET" && has_prefix "$S3_BUCKET"; then
    evaluate "Storage" "S3" "Bucket name uses '${NAMING_PREFIX}' prefix" 0
elif is_valid "$S3_BUCKET"; then
    evaluate "Storage" "S3" "Bucket name uses '${NAMING_PREFIX}' prefix" 1
else
    evaluate "Storage" "S3" "Bucket name uses '${NAMING_PREFIX}' prefix" 1
fi

print_section "S3 CF Deployment"
if is_valid "$S3_BUCKET"; then
    S3_CF_STATUS=$(check_cf_deployment "$S3_BUCKET")
    evaluate "Storage" "S3" "Deployed via CloudFormation" "$S3_CF_STATUS"
else
    evaluate "Storage" "S3" "Deployed via CloudFormation" 1
fi

# =============================================================================
# SECTION 3: DynamoDB Tables
# =============================================================================
print_header "SECTION 3: DynamoDB Tables (14 pts)"

check_dynamodb_table() {
    local table_suffix="$1"
    local display_name="$2"
    local cf_key="$3"

    print_section "${display_name} Table"

    # Try CF output first
    local table_name=""
    if [ -n "$cf_key" ]; then
        table_name=$(echo "$STACK_JSON" | jq -r ".Stacks[0].Outputs[] | select(.OutputKey==\"${cf_key}\") | .OutputValue" 2>/dev/null)
    fi

    # Fallback: search by name pattern
    if ! is_valid "$table_name"; then
        table_name="${NAMING_PREFIX}-${table_suffix}"
    fi

    local table_json
    table_json=$(aws_safe dynamodb describe-table --table-name "$table_name" 2>/dev/null)

    local table_status
    table_status=$(echo "$table_json" | jq -r '.Table.TableStatus // "NOT_FOUND"' 2>/dev/null)
    local table_arn
    table_arn=$(echo "$table_json" | jq -r '.Table.TableArn // empty' 2>/dev/null)

    if is_valid "$table_arn"; then
        evaluate "DynamoDB" "$display_name" "Table '${table_name}' exists" 0
    else
        evaluate "DynamoDB" "$display_name" "Table '${table_name}' exists" 1
        return
    fi

    # Table status
    if [ "$table_status" == "ACTIVE" ]; then
        evaluate "DynamoDB" "$display_name" "Table status is ACTIVE" 0
    else
        evaluate "DynamoDB" "$display_name" "Table status: ${table_status}" 1
    fi

    # Naming prefix check
    if has_prefix "$table_name"; then
        evaluate "DynamoDB" "$display_name" "Table name uses '${NAMING_PREFIX}' prefix" 0
    else
        evaluate "DynamoDB" "$display_name" "Table name uses '${NAMING_PREFIX}' prefix" 1
    fi

    # Billing mode check
    local billing_mode
    billing_mode=$(echo "$table_json" | jq -r '.Table.BillingModeSummary.BillingMode // "PROVISIONED"' 2>/dev/null)
    if [ "$billing_mode" == "PAY_PER_REQUEST" ]; then
        evaluate "DynamoDB" "$display_name" "Billing mode: PAY_PER_REQUEST (cost-effective)" 0
    else
        evaluate "DynamoDB" "$display_name" "Billing mode: ${billing_mode}" 3
    fi

    # Key schema check
    local key_count
    key_count=$(echo "$table_json" | jq '.Table.KeySchema | length' 2>/dev/null || echo "0")
    if [ "$key_count" -ge 2 ] 2>/dev/null; then
        evaluate "DynamoDB" "$display_name" "Has composite key (≥2 attributes)" 0
    else
        evaluate "DynamoDB" "$display_name" "Has composite key" 1
    fi

    # TTL check
    local ttl_enabled
    ttl_enabled=$(echo "$table_json" | jq -r '.Table.TimeToLiveDescription.TimeToLiveStatus // "DISABLED"' 2>/dev/null)
    if [ "$ttl_enabled" == "ENABLED" ]; then
        evaluate "DynamoDB" "$display_name" "TTL is enabled" 0
    else
        evaluate "DynamoDB" "$display_name" "TTL is enabled" 3
    fi

    # CF Deployment check
    local cf_status
    cf_status=$(check_cf_deployment "$table_name")
    evaluate "DynamoDB" "$display_name" "Deployed via CloudFormation" "$cf_status"
}

check_dynamodb_table "RawCitizenData" "RawCitizenData" "RawDynamoDBTable"
check_dynamodb_table "Analytics" "Analytics" "AnalyticsDynamoDBTable"

# =============================================================================
# SECTION 4: Kinesis Data Stream
# =============================================================================
print_header "SECTION 4: Kinesis Data Stream (8 pts)"

print_section "Stream Detection"
KINESIS_STREAM=""
KINESIS_STREAM=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="KinesisStreamName") | .OutputValue' 2>/dev/null)

if ! is_valid "$KINESIS_STREAM"; then
    # Search for hetherau-prefixed streams
    KINESIS_STREAM=$(aws_safe kinesis list-streams --query "StreamNames[?contains(@, '${NAMING_PREFIX}')] | [0]" --output text 2>/dev/null)
fi

if is_valid "$KINESIS_STREAM"; then
    evaluate "Kinesis" "Stream" "Stream '${KINESIS_STREAM}' exists" 0
else
    evaluate "Kinesis" "Stream" "Stream '${NAMING_PREFIX}-health-stream' exists" 1
    echo -e "  ${YELLOW}  (No hetherau-prefixed Kinesis stream found)${NC}"
fi

print_section "Stream Properties"
if is_valid "$KINESIS_STREAM"; then
    STREAM_DESC=$(aws_safe kinesis describe-stream --stream-name "$KINESIS_STREAM" 2>/dev/null)
    STREAM_STATUS=$(echo "$STREAM_DESC" | jq -r '.StreamDescription.StreamStatus // "UNKNOWN"' 2>/dev/null)
    STREAM_SHARDS=$(echo "$STREAM_DESC" | jq -r '.StreamDescription.Shards | length' 2>/dev/null || echo "0")
    STREAM_RETENTION=$(echo "$STREAM_DESC" | jq -r '.StreamDescription.RetentionPeriodHours // 0' 2>/dev/null)

    if [ "$STREAM_STATUS" == "ACTIVE" ]; then
        evaluate "Kinesis" "Stream" "Stream status is ACTIVE" 0
    else
        evaluate "Kinesis" "Stream" "Stream status: ${STREAM_STATUS}" 1
    fi

    if [ "$STREAM_SHARDS" -ge 1 ] 2>/dev/null; then
        evaluate "Kinesis" "Stream" "Shard count: ${STREAM_SHARDS}" 0
    else
        evaluate "Kinesis" "Stream" "Has at least 1 shard" 1
    fi

    if has_prefix "$KINESIS_STREAM"; then
        evaluate "Kinesis" "Stream" "Name uses '${NAMING_PREFIX}' prefix" 0
    else
        evaluate "Kinesis" "Stream" "Name uses '${NAMING_PREFIX}' prefix" 1
    fi

    # CF Deployment check
    local cf_status
    cf_status=$(check_cf_deployment "$KINESIS_STREAM")
    evaluate "Kinesis" "Stream" "Deployed via CloudFormation" "$cf_status"
else
    evaluate "Kinesis" "Stream" "Stream status" 1
    evaluate "Kinesis" "Stream" "Has shards" 1
    evaluate "Kinesis" "Stream" "Naming prefix check" 1
    evaluate "Kinesis" "Stream" "Deployed via CloudFormation" 1
fi

# =============================================================================
# SECTION 5: Lambda Functions
# =============================================================================
print_header "SECTION 5: Lambda Functions (20 pts)"

check_lambda_function() {
    local func_suffix="$1"
    local display_name="$2"

    print_section "${display_name} Lambda"

    local func_name="${NAMING_PREFIX}-${func_suffix}"
    local func_json
    func_json=$(aws_safe lambda get-function --function-name "$func_name" 2>/dev/null)

    # If not found by exact name, search
    if ! echo "$func_json" | jq -e '.Configuration' &>/dev/null; then
        local found_func
        found_func=$(aws_safe lambda list-functions --query "Functions[?contains(FunctionName, '${func_suffix}') && contains(FunctionName, '${NAMING_PREFIX}')].FunctionName | [0]" --output text 2>/dev/null)
        if is_valid "$found_func"; then
            func_name="$found_func"
            func_json=$(aws_safe lambda get-function --function-name "$func_name" 2>/dev/null)
        fi
    fi

    local func_arn
    func_arn=$(echo "$func_json" | jq -r '.Configuration.FunctionArn // empty' 2>/dev/null)

    if is_valid "$func_arn"; then
        evaluate "Lambda" "$display_name" "Function '${func_name}' exists" 0
    else
        evaluate "Lambda" "$display_name" "Function '${func_name}' exists" 1
        evaluate "Lambda" "$display_name" "Runtime check" 1
        evaluate "Lambda" "$display_name" "Memory check" 1
        evaluate "Lambda" "$display_name" "Timeout check" 1
        evaluate "Lambda" "$display_name" "Deployed via CloudFormation" 1
        return
    fi

    # Runtime
    local runtime
    runtime=$(echo "$func_json" | jq -r '.Configuration.Runtime // empty' 2>/dev/null)
    if [[ "$runtime" == python* ]]; then
        evaluate "Lambda" "$display_name" "Runtime: ${runtime}" 0
    else
        evaluate "Lambda" "$display_name" "Runtime: ${runtime:-unknown}" 1
    fi

    # Memory
    local memory
    memory=$(echo "$func_json" | jq -r '.Configuration.MemorySize // 0' 2>/dev/null)
    if [ "$memory" -ge 128 ] 2>/dev/null; then
        evaluate "Lambda" "$display_name" "Memory: ${memory} MB" 0
    else
        evaluate "Lambda" "$display_name" "Memory: ${memory} MB" 1
    fi

    # Timeout
    local timeout
    timeout=$(echo "$func_json" | jq -r '.Configuration.Timeout // 0' 2>/dev/null)
    if [ "$timeout" -ge 10 ] 2>/dev/null; then
        evaluate "Lambda" "$display_name" "Timeout: ${timeout}s" 0
    else
        evaluate "Lambda" "$display_name" "Timeout: ${timeout}s" 1
    fi

    # CF Deployment check (Lambda ARN contains function name, search by the function name itself)
    local cf_status
    cf_status=$(check_cf_deployment "$func_name")
    evaluate "Lambda" "$display_name" "Deployed via CloudFormation" "$cf_status"
}

check_lambda_function "kinesis-consumer" "KinesisConsumer"
check_lambda_function "get-data" "GetData"
check_lambda_function "invoke-endpoint" "InvokeEndpoint"
check_lambda_function "get-analytics" "GetAnalytics"

# =============================================================================
# SECTION 6: Step Functions State Machine
# =============================================================================
print_header "SECTION 6: Step Functions (8 pts)"

print_section "State Machine Detection"
SF_NAME="${NAMING_PREFIX}-batch-inference"
SF_ARN=""
SF_ARN=$(echo "$STACK_JSON" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="StateMachineArn") | .OutputValue' 2>/dev/null)

if ! is_valid "$SF_ARN"; then
    SF_ARN=$(aws_safe stepfunctions list-state-machines --query "stateMachines[?contains(name, '${NAMING_PREFIX}')].stateMachineArn | [0]" --output text 2>/dev/null)
fi

if is_valid "$SF_ARN"; then
    evaluate "StepFunc" "StateMachine" "State machine '${SF_NAME}' exists" 0
else
    evaluate "StepFunc" "StateMachine" "State machine '${SF_NAME}' exists" 1
    echo -e "  ${YELLOW}  (No hetherau-prefixed state machine found)${NC}"
fi

print_section "State Machine Properties"
if is_valid "$SF_ARN"; then
    SF_DESC=$(aws_safe stepfunctions describe-state-machine --state-machine-arn "$SF_ARN" 2>/dev/null)
    SF_STATUS=$(echo "$SF_DESC" | jq -r '.status // "UNKNOWN"' 2>/dev/null)
    SF_TYPE=$(echo "$SF_DESC" | jq -r '.type // "UNKNOWN"' 2>/dev/null)

    if [ "$SF_STATUS" == "ACTIVE" ]; then
        evaluate "StepFunc" "StateMachine" "Status: ACTIVE" 0
    else
        evaluate "StepFunc" "StateMachine" "Status: ${SF_STATUS}" 1
    fi

    if has_prefix "$(echo "$SF_DESC" | jq -r '.name // ""' 2>/dev/null)" ; then
        evaluate "StepFunc" "StateMachine" "Name uses '${NAMING_PREFIX}' prefix" 0
    else
        evaluate "StepFunc" "StateMachine" "Name uses '${NAMING_PREFIX}' prefix" 1
    fi

    # CF Deployment check – Step Function is EXEMPT (always full points)
    local sf_cf_status
    sf_cf_status=$(check_cf_deployment "$SF_NAME")
    if [ "$sf_cf_status" == "1" ]; then
        sf_cf_status=0  # Force full points even if not CF-managed (exempt)
    fi
    evaluate "StepFunc" "StateMachine" "Deployment method (CF exempt)" "$sf_cf_status"
else
    evaluate "StepFunc" "StateMachine" "Status check" 1
    evaluate "StepFunc" "StateMachine" "Naming prefix check" 1
    evaluate "StepFunc" "StateMachine" "Deployment method (CF exempt)" 1
fi

# =============================================================================
# SECTION 7: EventBridge Rule
# =============================================================================
print_header "SECTION 7: EventBridge Scheduler (8 pts)"

print_section "Rule Detection"
EB_RULE_NAME="${NAMING_PREFIX}-batch-inference-rule"
EB_RULE_JSON=$(aws_safe events describe-rule --name "$EB_RULE_NAME" 2>/dev/null)

if ! echo "$EB_RULE_JSON" | jq -e '.Arn' &>/dev/null; then
    EB_RULE_JSON=$(aws_safe events list-rules --name-prefix "$NAMING_PREFIX" --query "Rules[0]" 2>/dev/null)
    EB_RULE_NAME=$(echo "$EB_RULE_JSON" | jq -r '.Name // empty' 2>/dev/null)
    if is_valid "$EB_RULE_NAME"; then
        EB_RULE_JSON=$(aws_safe events describe-rule --name "$EB_RULE_NAME" 2>/dev/null)
    fi
fi

EB_RULE_ARN=$(echo "$EB_RULE_JSON" | jq -r '.Arn // empty' 2>/dev/null)
if is_valid "$EB_RULE_ARN"; then
    evaluate "EventBridge" "Rule" "Rule '${EB_RULE_NAME}' exists" 0
else
    evaluate "EventBridge" "Rule" "Rule '${EB_RULE_NAME}' exists" 1
    echo -e "  ${YELLOW}  (No hetherau-prefixed EventBridge rule found)${NC}"
fi

print_section "Rule Properties"
if is_valid "$EB_RULE_ARN"; then
    EB_STATE=$(echo "$EB_RULE_JSON" | jq -r '.State // "UNKNOWN"' 2>/dev/null)
    EB_SCHEDULE=$(echo "$EB_RULE_JSON" | jq -r '.ScheduleExpression // "NONE"' 2>/dev/null)

    if [ "$EB_STATE" == "ENABLED" ]; then
        evaluate "EventBridge" "Rule" "Rule state: ENABLED" 0
    elif [ "$EB_STATE" == "DISABLED" ]; then
        evaluate "EventBridge" "Rule" "Rule state: DISABLED" 3
    else
        evaluate "EventBridge" "Rule" "Rule state: ${EB_STATE}" 1
    fi

    if [ -n "$EB_SCHEDULE" ] && [ "$EB_SCHEDULE" != "NONE" ]; then
        evaluate "EventBridge" "Rule" "Schedule: ${EB_SCHEDULE}" 0
    else
        evaluate "EventBridge" "Rule" "Has schedule expression" 1
    fi

    # Check targets
    EB_TARGETS=$(aws_safe events list-targets-by-rule --rule "$EB_RULE_NAME" 2>/dev/null)
    EB_TARGET_COUNT=$(echo "$EB_TARGETS" | jq '.Targets | length' 2>/dev/null || echo "0")
    if [ "$EB_TARGET_COUNT" -ge 1 ] 2>/dev/null; then
        evaluate "EventBridge" "Rule" "Has ${EB_TARGET_COUNT} target(s)" 0
    else
        evaluate "EventBridge" "Rule" "Has targets configured" 1
    fi

    # CF Deployment check
    local eb_cf_status
    eb_cf_status=$(check_cf_deployment "$EB_RULE_NAME")
    evaluate "EventBridge" "Rule" "Deployed via CloudFormation" "$eb_cf_status"
else
    evaluate "EventBridge" "Rule" "Rule state" 1
    evaluate "EventBridge" "Rule" "Schedule check" 1
    evaluate "EventBridge" "Rule" "Targets check" 1
    evaluate "EventBridge" "Rule" "Deployed via CloudFormation" 1
fi

# =============================================================================
# SECTION 8: API Gateway
# =============================================================================
print_header "SECTION 8: API Gateway (10 pts)"

print_section "API Detection"
API_NAME="${NAMING_PREFIX}-api"
API_JSON=$(aws_safe apigateway get-rest-apis --query "items[?contains(name, '${NAMING_PREFIX}')] | [0]" 2>/dev/null)

API_ID=$(echo "$API_JSON" | jq -r '.id // empty' 2>/dev/null)
API_NAME_FOUND=$(echo "$API_JSON" | jq -r '.name // empty' 2>/dev/null)

if is_valid "$API_ID"; then
    evaluate "APIGateway" "REST API" "API '${API_NAME_FOUND}' exists (ID: ${API_ID})" 0
else
    evaluate "APIGateway" "REST API" "API '${API_NAME}' exists" 1
    echo -e "  ${YELLOW}  (No hetherau-prefixed API Gateway found)${NC}"
fi

print_section "API Resources"
if is_valid "$API_ID"; then
    API_RESOURCES=$(aws_safe apigateway get-resources --rest-api-id "$API_ID" 2>/dev/null)
    API_RESOURCE_COUNT=$(echo "$API_RESOURCES" | jq '.items | length' 2>/dev/null || echo "0")
    API_DATA_PATH=$(echo "$API_RESOURCES" | jq -r '.items[] | select(.path=="/data") | .path // empty' 2>/dev/null)

    if [ "$API_RESOURCE_COUNT" -ge 2 ] 2>/dev/null; then
        evaluate "APIGateway" "Resources" "Has ${API_RESOURCE_COUNT} resources (root + /data)" 0
    else
        evaluate "APIGateway" "Resources" "Has /data resource path" 1
    fi

    if [ "$API_DATA_PATH" == "/data" ]; then
        evaluate "APIGateway" "Resources" "GET /data endpoint configured" 0
    else
        evaluate "APIGateway" "Resources" "GET /data endpoint configured" 1
    fi

    # Check deployments
    API_DEPLOYMENTS=$(aws_safe apigateway get-deployments --rest-api-id "$API_ID" 2>/dev/null)
    API_DEPLOY_COUNT=$(echo "$API_DEPLOYMENTS" | jq '.items | length' 2>/dev/null || echo "0")
    if [ "$API_DEPLOY_COUNT" -ge 1 ] 2>/dev/null; then
        evaluate "APIGateway" "Deployment" "API deployed (${API_DEPLOY_COUNT} deployment(s))" 0
    else
        evaluate "APIGateway" "Deployment" "API has a deployment" 1
    fi

    # CF Deployment check
    local api_cf_status
    api_cf_status=$(check_cf_deployment "$API_ID")
    evaluate "APIGateway" "REST API" "Deployed via CloudFormation" "$api_cf_status"
else
    evaluate "APIGateway" "Resources" "Resource check" 1
    evaluate "APIGateway" "Resources" "GET /data endpoint" 1
    evaluate "APIGateway" "Deployment" "API deployment" 1
    evaluate "APIGateway" "REST API" "Deployed via CloudFormation" 1
fi

# =============================================================================
# SECTION 9: IoT Core
# =============================================================================
print_header "SECTION 9: AWS IoT Core (12 pts)"

print_section "IoT Policy"
IOT_POLICY_NAME="${NAMING_PREFIX}-device-policy"
IOT_POLICY_JSON=$(aws_safe iot get-policy --policy-name "$IOT_POLICY_NAME" 2>/dev/null)

IOT_POLICY_ARN=$(echo "$IOT_POLICY_JSON" | jq -r '.policyArn // empty' 2>/dev/null)
if is_valid "$IOT_POLICY_ARN"; then
    evaluate "IoT Core" "Policy" "IoT policy '${IOT_POLICY_NAME}' exists" 0
else
    evaluate "IoT Core" "Policy" "IoT policy '${IOT_POLICY_NAME}' exists" 1
    echo -e "  ${YELLOW}  (No hetherau-prefixed IoT policy found)${NC}"
fi

print_section "IoT Policy Content"
if is_valid "$IOT_POLICY_ARN"; then
    IOT_POLICY_DOC=$(echo "$IOT_POLICY_JSON" | jq -r '.policyDocument // "{}"' 2>/dev/null)
    HAS_MQTT_TOPIC=$(echo "$IOT_POLICY_DOC" | grep -q "citizen/health" && echo "yes" || echo "no")
    if [ "$HAS_MQTT_TOPIC" == "yes" ]; then
        evaluate "IoT Core" "Policy" "Policy references citizen/health topic" 0
    else
        evaluate "IoT Core" "Policy" "Policy references citizen/health topic" 1
    fi

    if has_prefix "$IOT_POLICY_NAME"; then
        evaluate "IoT Core" "Policy" "Policy name uses '${NAMING_PREFIX}' prefix" 0
    else
        evaluate "IoT Core" "Policy" "Policy name uses '${NAMING_PREFIX}' prefix" 1
    fi

    # CF Deployment check
    local pol_cf_status
    pol_cf_status=$(check_cf_deployment "$IOT_POLICY_NAME")
    evaluate "IoT Core" "Policy" "Deployed via CloudFormation" "$pol_cf_status"
else
    evaluate "IoT Core" "Policy" "Topic reference check" 1
    evaluate "IoT Core" "Policy" "Naming prefix check" 1
    evaluate "IoT Core" "Policy" "Deployed via CloudFormation" 1
fi

print_section "IoT Rule"
IOT_RULE_NAME="${NAMING_PREFIX}HealthToKinesis"
IOT_RULE_JSON=$(aws_safe iot get-topic-rule --rule-name "$IOT_RULE_NAME" 2>/dev/null)

IOT_RULE_ARN=$(echo "$IOT_RULE_JSON" | jq -r '.ruleArn // empty' 2>/dev/null)
if is_valid "$IOT_RULE_ARN"; then
    evaluate "IoT Core" "Rule" "IoT rule '${IOT_RULE_NAME}' exists" 0
else
    evaluate "IoT Core" "Rule" "IoT rule '${IOT_RULE_NAME}' exists" 1
    echo -e "  ${YELLOW}  (No hetherau-prefixed IoT rule found)${NC}"
fi

print_section "IoT Rule Properties"
if is_valid "$IOT_RULE_ARN"; then
    IOT_RULE_SQL=$(echo "$IOT_RULE_JSON" | jq -r '.rule.sql // ""' 2>/dev/null)
    IOT_RULE_ENABLED=$(echo "$IOT_RULE_JSON" | jq -r '.rule.ruleDisabled' 2>/dev/null)

    if echo "$IOT_RULE_SQL" | grep -q "citizen/health"; then
        evaluate "IoT Core" "Rule" "SQL selects FROM 'citizen/health'" 0
    else
        evaluate "IoT Core" "Rule" "SQL selects FROM 'citizen/health'" 1
    fi

    if [ "$IOT_RULE_ENABLED" == "false" ]; then
        evaluate "IoT Core" "Rule" "Rule is ENABLED" 0
    else
        evaluate "IoT Core" "Rule" "Rule is ENABLED" 1
    fi

    # CF Deployment check
    local rule_cf_status
    rule_cf_status=$(check_cf_deployment "$IOT_RULE_NAME")
    evaluate "IoT Core" "Rule" "Deployed via CloudFormation" "$rule_cf_status"
else
    evaluate "IoT Core" "Rule" "SQL check" 1
    evaluate "IoT Core" "Rule" "Enabled check" 1
    evaluate "IoT Core" "Rule" "Deployed via CloudFormation" 1
fi

# =============================================================================
# SECTION 10: IAM Roles
# =============================================================================
print_header "SECTION 10: IAM Roles (12 pts) SKIPPED"

# check_iam_role() {
#     local role_suffix="$1"
#     local display_name="$2"

#     print_section "${display_name} IAM Role"
#     local role_name="${NAMING_PREFIX}-${role_suffix}"
#     local role_json
#     role_json=$(aws_safe iam get-role --role-name "$role_name" 2>/dev/null)

#     local role_arn
#     role_arn=$(echo "$role_json" | jq -r '.Role.Arn // empty' 2>/dev/null)

#     if is_valid "$role_arn"; then
#         evaluate "IAM" "$display_name" "Role '${role_name}' exists" 0
#     else
#         evaluate "IAM" "$display_name" "Role '${role_name}' exists" 1
#         evaluate "IAM" "$display_name" "Deployed via CloudFormation" 1
#         return
#     fi

#     if has_prefix "$role_name"; then
#         evaluate "IAM" "$display_name" "Role name uses '${NAMING_PREFIX}' prefix" 0
#     else
#         evaluate "IAM" "$display_name" "Role name uses '${NAMING_PREFIX}' prefix" 1
#     fi

#     # CF Deployment check
#     local role_cf_status
#     role_cf_status=$(check_cf_deployment "$role_name")
#     evaluate "IAM" "$display_name" "Deployed via CloudFormation" "$role_cf_status"
# }

# check_iam_role "kinesis-consumer-role" "KinesisConsumer"
# check_iam_role "step-function-role" "StepFunction"
# check_iam_role "get-analytics-role" "GetAnalytics"
# check_iam_role "iot-rule-role" "IoTRule"

# =============================================================================
# SECTION 11: CloudFormation Resource Origin Verification
# =============================================================================
print_header "SECTION 11: CloudFormation Resource Origin Summary (6 pts)"

print_section "CF-Managed Resource Count"
# List all resources managed by the CloudFormation stack
CF_MANAGED_COUNT=0
CF_MANAGED_RESOURCES=""

if is_valid "$STACK_ID"; then
    CF_RESOURCES=$(aws_safe cloudformation list-stack-resources --stack-name "$STACK_NAME" 2>/dev/null)
    CF_MANAGED_COUNT=$(echo "$CF_RESOURCES" | jq '.StackResourceSummaries | length' 2>/dev/null || echo "0")
    CF_MANAGED_RESOURCES=$(echo "$CF_RESOURCES" | jq -r '.StackResourceSummaries[].LogicalResourceId' 2>/dev/null)
fi

if [ "$CF_MANAGED_COUNT" -ge 15 ] 2>/dev/null; then
    evaluate "CfnOrigin" "Managed" "Stack manages ${CF_MANAGED_COUNT} resources (≥15 expected)" 0
else
    evaluate "CfnOrigin" "Managed" "Stack manages ${CF_MANAGED_COUNT}/15+ resources" 1
fi

print_section "Key Resource Types in Stack"
# Verify key resource types are present in the stack
check_cf_resource_type() {
    local resource_type="$1"
    local check_name="$2"

    local in_stack
    in_stack=$(echo "$CF_RESOURCES" | jq -r ".StackResourceSummaries[] | select(.ResourceType==\"${resource_type}\") | .LogicalResourceId" 2>/dev/null | head -1)

    if is_valid "$in_stack"; then
        evaluate "CfnOrigin" "Resources" "${check_name} in CF stack" 0
    else
        evaluate "CfnOrigin" "Resources" "${check_name} in CF stack" 1
    fi
}

if is_valid "$STACK_ID"; then
    check_cf_resource_type "AWS::DynamoDB::Table" "DynamoDB Tables"
    check_cf_resource_type "AWS::Lambda::Function" "Lambda Functions"
    check_cf_resource_type "AWS::Kinesis::Stream" "Kinesis Stream"
else
    evaluate "CfnOrigin" "Resources" "DynamoDB Tables in CF stack" 1
    evaluate "CfnOrigin" "Resources" "Lambda Functions in CF stack" 1
    evaluate "CfnOrigin" "Resources" "Kinesis Stream in CF stack" 1
fi

print_section "Stack Drift Detection"
if is_valid "$STACK_ID"; then
    DRIFT_ID=$(aws_safe cloudformation detect-stack-drift --stack-name "$STACK_NAME" --query "StackDriftDetectionId" --output text 2>/dev/null)
    if is_valid "$DRIFT_ID"; then
        sleep 3
        DRIFT_STATUS=$(aws_safe cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$DRIFT_ID" --query "StackDriftStatus" --output text 2>/dev/null)
        if [ "$DRIFT_STATUS" == "IN_SYNC" ]; then
            evaluate "CfnOrigin" "Drift" "Stack is IN_SYNC (no drift)" 0
        elif [ "$DRIFT_STATUS" == "DRIFTED" ]; then
            evaluate "CfnOrigin" "Drift" "Stack has DRIFT – modified outside CF" 1
        else
            evaluate "CfnOrigin" "Drift" "Drift status: ${DRIFT_STATUS}" 3
        fi
    else
        evaluate "CfnOrigin" "Drift" "Drift detection check" 3
    fi
else
    evaluate "CfnOrigin" "Drift" "Drift detection (no stack)" 1
fi

# =============================================================================
# SECTION 12: SageMaker Endpoint (Optional)
# =============================================================================
print_header "SECTION 12: SageMaker Endpoint (6 pts) [Bonus]"

print_section "Endpoint Detection"
SM_ENDPOINT_NAME="${NAMING_PREFIX}-endpoint"
SM_ENDPOINT_JSON=$(aws_safe sagemaker describe-endpoint --endpoint-name "$SM_ENDPOINT_NAME" 2>/dev/null)

SM_ENDPOINT_ARN=$(echo "$SM_ENDPOINT_JSON" | jq -r '.EndpointArn // empty' 2>/dev/null)
if is_valid "$SM_ENDPOINT_ARN"; then
    evaluate "SageMaker" "Endpoint" "Endpoint '${SM_ENDPOINT_NAME}' exists" 0
else
    evaluate "SageMaker" "Endpoint" "Endpoint '${SM_ENDPOINT_NAME}' exists" 3
    echo -e "  ${YELLOW}  (SageMaker endpoint is deployed separately by training script)${NC}"
fi

print_section "Endpoint Status"
if is_valid "$SM_ENDPOINT_ARN"; then
    SM_ENDPOINT_STATUS=$(echo "$SM_ENDPOINT_JSON" | jq -r '.EndpointStatus // "UNKNOWN"' 2>/dev/null)
    if [ "$SM_ENDPOINT_STATUS" == "InService" ]; then
        evaluate "SageMaker" "Endpoint" "Endpoint status: InService" 0
    else
        evaluate "SageMaker" "Endpoint" "Endpoint status: ${SM_ENDPOINT_STATUS}" 3
    fi

    if has_prefix "$SM_ENDPOINT_NAME"; then
        evaluate "SageMaker" "Endpoint" "Endpoint name uses '${NAMING_PREFIX}' prefix" 0
    else
        evaluate "SageMaker" "Endpoint" "Endpoint name uses '${NAMING_PREFIX}' prefix" 3
    fi
else
    evaluate "SageMaker" "Endpoint" "Endpoint status" 3
    evaluate "SageMaker" "Endpoint" "Naming prefix check" 3
fi

# =============================================================================
# FINAL SCORE CALCULATION
# =============================================================================
print_header "GRADING SUMMARY"

# Calculate percentage
if [ "$TOTAL_POINTS" -gt 0 ]; then
    PERCENTAGE=$(echo "scale=1; ($EARNED_POINTS / $TOTAL_POINTS) * 100" | bc 2>/dev/null || echo "0")
else
    PERCENTAGE="0"
fi

echo ""
echo -e "  ${BOLD}Total Checks:${NC}  $((TOTAL_POINTS / 2))"
echo -e "  ${BOLD}Points Earned:${NC} ${EARNED_POINTS} / ${TOTAL_POINTS}"
echo ""
echo -e "  ${BOLD}Deployment Method Breakdown:${NC}"
echo -e "    Resources found & CF-managed  → +2 pts each (full credit)"
echo -e "    Resources found but manual     → +1 pt each (reduced credit)"
echo -e "    Resources missing              → +0 pts"
echo -e "    Step Functions                 → exempt (always full credit)"
echo ""

# Grade assignment
if (( $(echo "$PERCENTAGE >= 90" | bc -l 2>/dev/null) )); then
    GRADE="${GREEN}${BOLD}A – Excellent!${NC}"
elif (( $(echo "$PERCENTAGE >= 80" | bc -l 2>/dev/null) )); then
    GRADE="${GREEN}${BOLD}B – Good${NC}"
elif (( $(echo "$PERCENTAGE >= 70" | bc -l 2>/dev/null) )); then
    GRADE="${YELLOW}${BOLD}C – Satisfactory${NC}"
elif (( $(echo "$PERCENTAGE >= 60" | bc -l 2>/dev/null) )); then
    GRADE="${YELLOW}${BOLD}D – Needs Improvement${NC}"
else
    GRADE="${RED}${BOLD}F – Incomplete${NC}"
fi

echo -e "  ${BOLD}Final Grade:${NC} ${PERCENTAGE}% → ${GRADE}"
echo ""

# Critical issues summary
echo -e "  ${BOLD}Status Summary:${NC}"
if is_valid "$STACK_ID"; then
    echo -e "    ${GREEN}✓${NC} CloudFormation stack deployed"
else
    echo -e "    ${RED}✗${NC} CloudFormation stack NOT found – deploy it first!"
fi

if is_valid "$S3_BUCKET"; then
    echo -e "    ${GREEN}✓${NC} S3 bucket found"
else
    echo -e "    ${RED}✗${NC} S3 bucket missing"
fi

# Count how many Lambdas are found
LAMBDA_FOUND=0
for suffix in "kinesis-consumer" "get-data" "invoke-endpoint" "get-analytics"; do
    if aws_safe lambda get-function --function-name "${NAMING_PREFIX}-${suffix}" &>/dev/null; then
        LAMBDA_FOUND=$((LAMBDA_FOUND + 1))
    fi
done
if [ "$LAMBDA_FOUND" -eq 4 ]; then
    echo -e "    ${GREEN}✓${NC} All 4 Lambda functions found"
elif [ "$LAMBDA_FOUND" -gt 0 ]; then
    echo -e "    ${YELLOW}⚠${NC} ${LAMBDA_FOUND}/4 Lambda functions found"
else
    echo -e "    ${RED}✗${NC} No Lambda functions found"
fi

DYNAMODB_FOUND=0
for table in "${NAMING_PREFIX}-RawCitizenData" "${NAMING_PREFIX}-Analytics"; do
    if aws_safe dynamodb describe-table --table-name "$table" &>/dev/null; then
        DYNAMODB_FOUND=$((DYNAMODB_FOUND + 1))
    fi
done
if [ "$DYNAMODB_FOUND" -eq 2 ]; then
    echo -e "    ${GREEN}✓${NC} Both DynamoDB tables found"
elif [ "$DYNAMODB_FOUND" -gt 0 ]; then
    echo -e "    ${YELLOW}⚠${NC} ${DYNAMODB_FOUND}/2 DynamoDB tables found"
else
    echo -e "    ${RED}✗${NC} No DynamoDB tables found"
fi

echo ""
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN}  Grading Complete                                          ${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo ""

# Output JSON for CI/CD integration
if [ "${OUTPUT_JSON:-false}" = "true" ] || [ "${CI:-false}" = "true" ]; then
    echo "--- JSON Output ---"
    cat <<EOF
{
  "stack_name": "${STACK_NAME}",
  "naming_prefix": "${NAMING_PREFIX}",
  "region": "${AWS_REGION}",
  "score": ${EARNED_POINTS},
  "max_score": ${TOTAL_POINTS},
  "percentage": ${PERCENTAGE},
  "grade": "$(echo "$PERCENTAGE >= 90" | bc -l 2>/dev/null && echo 'A' || echo "$PERCENTAGE >= 80" | bc -l 2>/dev/null && echo 'B' || echo "$PERCENTAGE >= 70" | bc -l 2>/dev/null && echo 'C' || echo "$PERCENTAGE >= 60" | bc -l 2>/dev/null && echo 'D' || echo 'F')",
  "stack_exists": $(is_valid "$STACK_ID" && echo "true" || echo "false"),
  "lambdas_found": ${LAMBDA_FOUND},
  "dynamodb_tables_found": ${DYNAMODB_FOUND},
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
fi

exit 0

#!/bin/bash

# End-to-end demo: API Gateway (HTTP API v2) -> Lambda -> DynamoDB on MiniStack.
#
# The script:
#   1. Creates a DynamoDB table.
#   2. Creates a Lambda function that writes an item into that table on each call.
#   3. Creates an API Gateway (HTTP API v2) with a POST route proxying to the Lambda.
#   4. Invokes the endpoint over HTTP via curl.
#   5. Scans the table to prove the item was persisted.
#
# Usage:
#   ./deploy-apig-lambda-dynamodb.sh [ENDPOINT_URL] [API_NAME] [FUNCTION_NAME] [TABLE_NAME]

# --- PARAMETERS (Arguments or Defaults) ---
ENDPOINT_URL="${1:-http://brossi.dev.ministack.local}"
API_NAME="${2:-brossi-http-api-ddb}"
FUNCTION_NAME="${3:-brossi-lambda-ddb}"
TABLE_NAME="${4:-brossi-items}"

RUNTIME="python3.9"
ROLE="arn:aws:iam::000000000000:role/lambda-ex"
HANDLER="index.handler"
REGION="us-east-1"
ACCOUNT_ID="000000000000"

# The Lambda runs in a Docker container (ministack's LAMBDA_EXECUTOR=docker +
# DinD sidecar), so "localhost:4566" is the Lambda container itself, not the
# emulator. MiniStack maps "host.docker.internal" to the host gateway inside
# every Lambda container, so that hostname reaches the ministack API on 4566.
# No web exposure of DynamoDB is required.
DDB_ENDPOINT="http://host.docker.internal:4566"

echo "📌 Using Endpoint URL: $ENDPOINT_URL"
echo "📌 API Gateway Name: $API_NAME"
echo "📌 Function Name: $FUNCTION_NAME"
echo "📌 DynamoDB Table: $TABLE_NAME"
echo "📌 DynamoDB endpoint (used by the Lambda): $DDB_ENDPOINT"
echo "--------------------------------------------------"

# 1. EXPORT MOCK ENVIRONMENT VARIABLES FOR AWS CLI
echo "🔑 Configuring AWS environment variables..."
export AWS_ACCESS_KEY_ID="mock-key"
export AWS_SECRET_ACCESS_KEY="mock-secret"
export AWS_DEFAULT_REGION="$REGION"

# 2. CREATE DYNAMODB TABLE
echo "🗄️  Creating DynamoDB table..."
# Delete first to clean up previous state (ignore errors if it doesn't exist)
aws dynamodb delete-table \
    --endpoint-url=$ENDPOINT_URL \
    --table-name $TABLE_NAME 2>/dev/null || true

aws dynamodb create-table \
    --endpoint-url=$ENDPOINT_URL \
    --table-name $TABLE_NAME \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST

echo "⏳ Waiting for table to become ACTIVE..."
aws dynamodb wait table-exists \
    --endpoint-url=$ENDPOINT_URL \
    --table-name $TABLE_NAME 2>/dev/null || true
echo "✅ DynamoDB table ready: $TABLE_NAME"

# 3. CREATE LAMBDA SOURCE CODE
# Reads the API Gateway v2 payload, writes an item into DynamoDB, returns a JSON reply.
echo "📝 Creating Lambda source code (writes to DynamoDB)..."
cat << 'EOF' > index.py
import json
import os
import time
import uuid

import boto3

# Inside MiniStack the Lambda runs in its own Docker container; it reaches the
# emulator's DynamoDB API through host.docker.internal (mapped to the host
# gateway by MiniStack), not localhost. DDB_ENDPOINT is injected as an env var.
DDB_ENDPOINT = os.environ.get("DDB_ENDPOINT", "http://host.docker.internal:4566")
TABLE_NAME = os.environ.get("TABLE_NAME", "brossi-items")

dynamodb = boto3.resource(
    "dynamodb",
    endpoint_url=DDB_ENDPOINT,
    region_name=os.environ.get("AWS_REGION", "us-east-1"),
)


def handler(event, context):
    print("Received API Gateway Event!")
    print(json.dumps(event))

    # Parse the request body (API Gateway HTTP API payload format 2.0).
    raw_body = event.get("body", "") or "{}"
    try:
        payload = json.loads(raw_body)
    except (ValueError, TypeError):
        payload = {"raw": raw_body}

    item = {
        "id": str(uuid.uuid4()),
        "created_at": str(int(time.time())),
        "message": payload.get("message", "no message provided"),
        "user": payload.get("user", "anonymous"),
    }

    table = dynamodb.Table(TABLE_NAME)
    table.put_item(Item=item)
    print("Stored item in DynamoDB: " + json.dumps(item))

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "message": "Item saved to DynamoDB via MiniStack API Gateway!",
            "table": TABLE_NAME,
            "item": item,
        }),
    }
EOF

# 4. CREATE ZIP PACKAGE
echo "📦 Creating ZIP package..."
zip -q function.zip index.py

# 5. DEPLOY THE LAMBDA FUNCTION
echo "🚀 Deploying Lambda to MiniStack..."
aws lambda delete-function --endpoint-url=$ENDPOINT_URL --function-name $FUNCTION_NAME 2>/dev/null || true

aws lambda create-function \
    --endpoint-url=$ENDPOINT_URL \
    --function-name $FUNCTION_NAME \
    --runtime $RUNTIME \
    --role $ROLE \
    --handler $HANDLER \
    --timeout 30 \
    --environment "Variables={TABLE_NAME=$TABLE_NAME,DDB_ENDPOINT=$DDB_ENDPOINT}" \
    --zip-file fileb://function.zip

LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$FUNCTION_NAME"
echo "✅ Lambda Created! ARN: $LAMBDA_ARN"

# 6. CREATE API GATEWAY (HTTP API v2)
echo "🌐 Creating API Gateway (HTTP API)..."
API_OUTPUT=$(aws apigatewayv2 create-api \
    --endpoint-url=$ENDPOINT_URL \
    --name $API_NAME \
    --protocol-type HTTP \
    --target $LAMBDA_ARN)

API_ID=$(echo "$API_OUTPUT" | grep -o '"ApiId": "[^"]*' | grep -o '[^"]*$')
echo "✅ API Gateway Created! API ID: $API_ID"

# 7. CREATE INTEGRATION (Linking API Gateway to Lambda)
echo "🔗 Creating Lambda Integration..."
INTEGRATION_OUTPUT=$(aws apigatewayv2 create-integration \
    --endpoint-url=$ENDPOINT_URL \
    --api-id $API_ID \
    --integration-type AWS_PROXY \
    --integration-uri $LAMBDA_ARN \
    --payload-format-version "2.0")

INTEGRATION_ID=$(echo "$INTEGRATION_OUTPUT" | grep -o '"IntegrationId": "[^"]*' | head -n 1 | grep -o '[^"]*$')
echo "✅ Integration Created! Integration ID: $INTEGRATION_ID"

# 8. CREATE ROUTE (POST /items)
echo "🛣️ Creating Route (POST /items)..."
aws apigatewayv2 create-route \
    --endpoint-url=$ENDPOINT_URL \
    --api-id $API_ID \
    --route-key "POST /items" \
    --target "integrations/$INTEGRATION_ID"

# 9. CREATE DEFAULT STAGE (auto-deploy)
echo "📦 Creating Stage (\$default)..."
aws apigatewayv2 create-stage \
    --endpoint-url=$ENDPOINT_URL \
    --api-id $API_ID \
    --stage-name "\$default" \
    --auto-deploy

echo "--------------------------------------------------"
echo "✅ Done! API Gateway -> Lambda -> DynamoDB is set up."

# 10. INVOKE THE ENDPOINT VIA CURL
echo "🧪 Invoking the endpoint via HTTP (POST /items)..."
INVOKE_URL="$ENDPOINT_URL/restapis/$API_ID/\$default/_user_request_/items"
# Alternative host-based form on MiniStack:
# INVOKE_URL="http://$API_ID.execute-api.localhost:4566/items"

PAYLOAD_INPUT='{"user": "Brossi", "message": "Hello from API Gateway + Lambda + DynamoDB!"}'

echo "👉 Invoking URL: $INVOKE_URL"
curl -s -X POST "$INVOKE_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD_INPUT"
echo -e "\n--------------------------------------------------"

# 11. VERIFY: SCAN THE TABLE TO SHOW THE PERSISTED ITEM
echo "🔎 Scanning DynamoDB table to verify the stored item..."
aws dynamodb scan \
    --endpoint-url=$ENDPOINT_URL \
    --table-name $TABLE_NAME
echo "--------------------------------------------------"

# Clean up local temporary files
rm -f index.py function.zip

echo "✅ Process completed! Script reached the end successfully."

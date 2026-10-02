#!/bin/bash

# --- PARAMETERS (Arguments or Defaults) ---
ENDPOINT_URL="${1:-http://brossi.dev.ministack.local}"
QUEUE_NAME="${2:-brossi-sqs}"
FUNCTION_NAME="${3:-brossi-lambda-processa-sqs}"

RUNTIME="python3.9"
ROLE="arn:aws:iam::000000000000:role/lambda-ex"
HANDLER="index.handler"

echo "📌 Using Endpoint URL: $ENDPOINT_URL"
echo "📌 Queue Name: $QUEUE_NAME"
echo "📌 Function Name: $FUNCTION_NAME"
echo "--------------------------------------------------"

# 1. EXPORT MOCK ENVIRONMENT VARIABLES FOR AWS CLI
echo "🔑 Configuring AWS environment variables..."
export AWS_ACCESS_KEY_ID="mock-key"
export AWS_SECRET_ACCESS_KEY="mock-secret"
export AWS_DEFAULT_REGION="us-east-1"

# 2. CREATE SQS QUEUE
echo "📥 Creating SQS Queue..."
# Delete the queue first if it exists to clean up previous states
aws sqs delete-queue --endpoint-url=$ENDPOINT_URL --queue-url "$ENDPOINT_URL/000000000000/$QUEUE_NAME" 2>/dev/null || true

QUEUE_OUTPUT=$(aws sqs create-queue --endpoint-url=$ENDPOINT_URL --queue-name $QUEUE_NAME)
QUEUE_ARN="arn:aws:sqs:us-east-1:000000000000:$QUEUE_NAME"
echo "✅ Queue Created! ARN: $QUEUE_ARN"

# 3. CREATE LAMBDA SOURCE CODE (Processes SQS Event Records)
echo "📝 Creating Lambda source code for SQS..."
cat << 'EOF' > index.py
import json

def handler(event, context):
    print("Received SQS Event!")
    
    # SQS events contain a list of Records
    for record in event.get('Records', []):
        message_body = record.get('body', '')
        message_id = record.get('messageId', 'N/A')
        print(f"Processing Message [{message_id}]: {message_body}")
        
    return {
        'statusCode': 200,
        'body': f"Successfully processed {len(event.get('Records', []))} SQS messages."
    }
EOF

# 4. CREATE ZIP PACKAGE
echo "📦 Creating ZIP package..."
zip -q function.zip index.py

# 5. DEPLOY THE NEW LAMBDA
echo "🚀 Deploying Lambda to MiniStack..."
aws lambda delete-function --endpoint-url=$ENDPOINT_URL --function-name $FUNCTION_NAME 2>/dev/null || true

aws lambda create-function \
    --endpoint-url=$ENDPOINT_URL \
    --function-name $FUNCTION_NAME \
    --runtime $RUNTIME \
    --role $ROLE \
    --handler $HANDLER \
    --zip-file fileb://function.zip

# 6. ATTACH SQS QUEUE TO LAMBDA (Event Source Mapping)
echo "🔗 Mapping SQS Queue to Lambda Function..."
aws lambda create-event-source-mapping \
    --endpoint-url=$ENDPOINT_URL \
    --function-name $FUNCTION_NAME \
    --event-source-arn $QUEUE_ARN \
    --batch-size 1

# 7. TEST THE INTEGRATION: SEND A MESSAGE TO SQS
echo "📨 Sending a test message to the SQS queue..."
TEST_MESSAGE="Hello Brossi! This message triggers the Lambda through SQS."

aws sqs send-message \
    --endpoint-url=$ENDPOINT_URL \
    --queue-url "$ENDPOINT_URL/000000000000/$QUEUE_NAME" \
    --message-body "$TEST_MESSAGE"

echo "--------------------------------------------------"
echo "✅ Done! The message has been sent to SQS."
echo "💡 MiniStack will now trigger the sidecar Docker container to run the Lambda."
echo "👉 Run your kubectl logs command to see the Lambda container execution output!"

# Clean up local temporary files
rm -f index.py function.zip

#!/bin/bash

# --- PARAMETERS (Arguments or Defaults) ---
ENDPOINT_URL="${1:-http://brossi.dev.ministack.local}"
API_NAME="${2:-brossi-http-api}"
FUNCTION_NAME="${3:-brossi-lambda-apigw}"

RUNTIME="python3.9"
ROLE="arn:aws:iam::000000000000:role/lambda-ex"
HANDLER="index.handler"
REGION="us-east-1"
ACCOUNT_ID="000000000000"

echo "📌 Using Endpoint URL: $ENDPOINT_URL"
echo "📌 API Gateway Name: $API_NAME"
echo "📌 Function Name: $FUNCTION_NAME"
echo "--------------------------------------------------"

# 1. EXPORT MOCK ENVIRONMENT VARIABLES FOR AWS CLI
echo "🔑 Configuring AWS environment variables..."
export AWS_ACCESS_KEY_ID="mock-key"
export AWS_SECRET_ACCESS_KEY="mock-secret"
export AWS_DEFAULT_REGION="$REGION"

# 2. CREATE LAMBDA SOURCE CODE (Handles API Gateway HTTP API v2 payloads)
echo "📝 Creating Lambda source code for API Gateway..."
cat << 'EOF' > index.py
import json

def handler(event, context):
    print("Received API Gateway Event!")
    print(json.dumps(event))
    
    # API Gateway HTTP API (Payload Format 2.0) parsing
    path = event.get('rawPath', '/')
    method = event.get('requestContext', {}).get('http', {}).get('method', 'GET')
    
    return {
        'statusCode': 200,
        'headers': { 'Content-Type': 'application/json' },
        'body': json.dumps({
            "message": "Hello from Lambda triggered via MiniStack API Gateway!",
            "path": path,
            "method": method
        })
    }
EOF

# 3. CREATE ZIP PACKAGE
echo "📦 Creating ZIP package..."
zip -q function.zip index.py

# 4. DEPLOY THE LAMBDA FUNCTION
echo "🚀 Deploying Lambda to MiniStack..."
aws lambda delete-function --endpoint-url=$ENDPOINT_URL --function-name $FUNCTION_NAME 2>/dev/null || true

aws lambda create-function \
    --endpoint-url=$ENDPOINT_URL \
    --function-name $FUNCTION_NAME \
    --runtime $RUNTIME \
    --role $ROLE \
    --handler $HANDLER \
    --zip-file fileb://function.zip

LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT_ID:function:$FUNCTION_NAME"
echo "✅ Lambda Created! ARN: $LAMBDA_ARN"

# 5. CREATE API GATEWAY (HTTP API v2)
echo "🌐 Creating API Gateway (HTTP API)..."
API_OUTPUT=$(aws apigatewayv2 create-api \
    --endpoint-url=$ENDPOINT_URL \
    --name $API_NAME \
    --protocol-type HTTP \
    --target $LAMBDA_ARN)

API_ID=$(echo "$API_OUTPUT" | grep -o '"ApiId": "[^"]*' | grep -o '[^"]*$')
echo "✅ API Gateway Created! API ID: $API_ID"

# 6. CREATE INTEGRATION (Linking API Gateway to Lambda)
echo "🔗 Creating Lambda Integration..."
INTEGRATION_OUTPUT=$(aws apigatewayv2 create-integration \
    --endpoint-url=$ENDPOINT_URL \
    --api-id $API_ID \
    --integration-type AWS_PROXY \
    --integration-uri $LAMBDA_ARN \
    --payload-format-version "2.0")

INTEGRATION_ID=$(echo "$INTEGRATION_OUTPUT" | grep -o '"IntegrationId": "[^"]*' | head -n 1 | grep -o '[^"]*$')
echo "✅ Integration Created! Integration ID: $INTEGRATION_ID"

# 7. CREATE ROUTE (e.g., GET /test)
echo "🛣️ Creating Route (GET /test)..."
aws apigatewayv2 create-route \
    --endpoint-url=$ENDPOINT_URL \
    --api-id $API_ID \
    --route-key "GET /test" \
    --target "integrations/$INTEGRATION_ID"

# 8. CREATE DEFAULT STAGE (Auto-deploy or explicit stage)
echo "📦 Creating Stage ($default)..."
aws apigatewayv2 create-stage \
    --endpoint-url=$ENDPOINT_URL \
    --api-id $API_ID \
    --stage-name "\$default" \
    --auto-deploy

echo "--------------------------------------------------"
echo "✅ Done! API Gateway is set up."
echo "🧪 Testing the endpoint..."

# Costruisce l'URL di invocazione locale tipico di MiniStack / API Gateway v2
# (Su MiniStack l'invocazione risponde sull'endpoint delle API o tramite formato host/path locale)
INVOKE_URL="$ENDPOINT_URL/restapis/$API_ID/\$default/_user_request_/test"
# In alternativa, se usi l'indirizzo basato su header custom di MiniStack:
# INVOKE_URL="http://$API_ID.execute-api.localhost:4566/test"

echo "👉 Invoking URL: $INVOKE_URL"
curl -s "$INVOKE_URL"
echo -e "\n--------------------------------------------------"

# Clean up local temporary files
rm -f index.py function.zip

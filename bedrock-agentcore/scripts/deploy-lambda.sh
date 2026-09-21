#!/usr/bin/env bash
# Package and deploy the incident-orchestrator Lambda.
# The code is standard library + boto3 only, both already in the Lambda Python
# runtime, so the zip carries no vendored dependencies.
. "$(dirname "$0")/_common.sh"
require_tools aws jq zip; require_state

ACCOUNT_ID=$(jq -r .accountId "$STATE_FILE")
GATEWAY_URL=$(jq -r .gatewayUrl "$STATE_FILE")
GATEWAY_ARN=$(jq -r .gatewayArn "$STATE_FILE")

step "[1/3] Execution role"
if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
  info "reusing $LAMBDA_ROLE_NAME"
else
  aws iam create-role --role-name "$LAMBDA_ROLE_NAME" \
    --description "Execution role for the Operata incident orchestrator" \
    --tags Key=ManagedBy,Value=operata-mcp-recipes/bedrock-agentcore \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{
      "Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},
      "Action":"sts:AssumeRole"}]}' >/dev/null
  info "created $LAMBDA_ROLE_NAME, waiting for IAM propagation"
  sleep 20
fi

# Two permissions beyond logging. InvokeGateway is the inbound half of AWS_IAM
# auth: this role is what authorizes the call, so there is no token to manage.
aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name OperataIncidentOrchestrator \
  --policy-document "$(jq -nc --arg a "$ACCOUNT_ID" --arg r "$AWS_REGION" --arg g "$GATEWAY_ARN" '
    {Version:"2012-10-17",Statement:[
     {Sid:"Logs",Effect:"Allow",
      Action:["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
      Resource:("arn:aws:logs:"+$r+":"+$a+":*")},
     {Sid:"InvokeClaude",Effect:"Allow",
      Action:["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],Resource:"*"},
     {Sid:"InvokeGateway",Effect:"Allow",
      Action:["bedrock-agentcore:InvokeGateway"],Resource:[$g,($g+"/*")]}]}')"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
info "$LAMBDA_ROLE_ARN"

step "[2/3] Package"
ZIP="$ROOT/function.zip"; rm -f "$ZIP"
( cd "$ROOT/lambda" && zip -q "$ZIP" handler.py incident_agent.py mcp_gateway_client.py )
info "$(basename "$ZIP"), $(du -h "$ZIP" | cut -f1)"

step "[3/3] Function"
ENVVARS="Variables={GATEWAY_URL=$GATEWAY_URL,GATEWAY_REGION=$AWS_REGION,BEDROCK_REGION=$AWS_REGION,MODEL_ID=$MODEL_ID,MAX_TOOL_TURNS=$MAX_TOOL_TURNS}"
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$ZIP" --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
  aws lambda update-function-configuration --function-name "$FUNCTION_NAME" \
    --role "$LAMBDA_ROLE_ARN" --handler handler.handler --timeout 600 --memory-size 512 \
    --environment "$ENVVARS" --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
  info "updated $FUNCTION_NAME"
else
  aws lambda create-function --function-name "$FUNCTION_NAME" \
    --runtime python3.13 --role "$LAMBDA_ROLE_ARN" --handler handler.handler \
    --zip-file "fileb://$ZIP" --timeout 600 --memory-size 512 \
    --environment "$ENVVARS" --region "$AWS_REGION" \
    --tags ManagedBy=operata-mcp-recipes/bedrock-agentcore \
    --description "Operata incident orchestrator, Bedrock tool loop over AgentCore Gateway" >/dev/null
  aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
  info "created $FUNCTION_NAME"
fi
rm -f "$ZIP"

step "Lambda ready"
info "Run it:  ./scripts/run-incident.sh"

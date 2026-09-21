#!/usr/bin/env bash
# Create the AgentCore Gateway that fronts the Operata MCP server.
# Re-runnable: existing resources are reused and updated in place.
. "$(dirname "$0")/_common.sh"

step "[0/5] Preflight"
require_tools aws curl jq
curl --help all 2>/dev/null | grep -q -- --aws-sigv4 || die "curl lacks --aws-sigv4 (needs curl 7.75+)."
[ -n "${OPERATA_API_KEY:-}" ] && [ "$OPERATA_API_KEY" != "paste-your-key-here" ] \
  || die "Set OPERATA_API_KEY in config.env."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
  || die "No AWS credentials. Run 'aws sso login' or set AWS_PROFILE."
info "account $ACCOUNT_ID, region $AWS_REGION"

# Check the key before creating anything, so a wrong-environment key fails here
# rather than half way through building a gateway.
code=$(curl -sS -o /dev/null -w '%{http_code}' -m 30 -X POST "$OPERATA_MCP_ENDPOINT" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer $OPERATA_API_KEY" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}') || true
[ "$code" = "200" ] || die "Operata returned HTTP $code for this key against
  $OPERATA_MCP_ENDPOINT

  Create the key in the Operata console under Group Settings > API Management,
  not Settings > Config > API — the MCP endpoint rejects the REST token. Check
  the key has not been revoked, and that OPERATA_MCP_ENDPOINT in config.env
  matches the Operata environment the key belongs to."
info "Operata key accepted"

step "[1/5] Gateway service role"
if aws iam get-role --role-name "$GATEWAY_ROLE_NAME" >/dev/null 2>&1; then
  info "reusing $GATEWAY_ROLE_NAME"
else
  aws iam create-role --role-name "$GATEWAY_ROLE_NAME" \
    --description "Assumed by AgentCore Gateway to reach the Operata MCP server" \
    --tags Key=ManagedBy,Value=operata-mcp-recipes/bedrock-agentcore \
    --assume-role-policy-document "$(jq -nc --arg a "$ACCOUNT_ID" --arg r "$AWS_REGION" '
      {Version:"2012-10-17",Statement:[{
        Effect:"Allow",
        Principal:{Service:"bedrock-agentcore.amazonaws.com"},
        Action:"sts:AssumeRole",
        Condition:{StringEquals:{"aws:SourceAccount":$a},
                   ArnLike:{"aws:SourceArn":("arn:aws:bedrock-agentcore:"+$r+":"+$a+":*")}}}]}')" >/dev/null
  info "created $GATEWAY_ROLE_NAME, waiting for IAM propagation"
  sleep 10
fi

aws iam put-role-policy --role-name "$GATEWAY_ROLE_NAME" \
  --policy-name OperataGatewayOutboundAuth \
  --policy-document "$(jq -nc --arg a "$ACCOUNT_ID" --arg r "$AWS_REGION" '
    {Version:"2012-10-17",Statement:[
     {Sid:"FetchOutboundCredentials",Effect:"Allow",
      Action:["bedrock-agentcore:GetWorkloadAccessToken",
              "bedrock-agentcore:GetResourceApiKey",
              "bedrock-agentcore:GetResourceOauth2Token"],Resource:"*"},
     {Sid:"ReadStoredSecret",Effect:"Allow",
      Action:["secretsmanager:GetSecretValue"],
      Resource:("arn:aws:secretsmanager:"+$r+":"+$a+":secret:bedrock-agentcore*")},
     {Sid:"SynchroniseToolCatalog",Effect:"Allow",
      Action:["bedrock-agentcore:SynchronizeGatewayTargets"],Resource:"*"}]}')"
GATEWAY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${GATEWAY_ROLE_NAME}"
info "$GATEWAY_ROLE_ARN"

step "[2/5] Operata API key credential provider"
if aws bedrock-agentcore-control get-api-key-credential-provider \
     --name "$PROVIDER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws bedrock-agentcore-control update-api-key-credential-provider \
    --name "$PROVIDER_NAME" --api-key "$OPERATA_API_KEY" --region "$AWS_REGION" >/dev/null
  info "updated $PROVIDER_NAME"
else
  aws bedrock-agentcore-control create-api-key-credential-provider \
    --name "$PROVIDER_NAME" --api-key "$OPERATA_API_KEY" --region "$AWS_REGION" >/dev/null
  info "created $PROVIDER_NAME"
fi
PROVIDER_ARN=$(aws bedrock-agentcore-control get-api-key-credential-provider \
  --name "$PROVIDER_NAME" --region "$AWS_REGION" --query credentialProviderArn --output text)
info "key stored in AWS, never in this repo or the Lambda"

step "[3/5] MCP gateway, AWS_IAM inbound auth"
GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways --region "$AWS_REGION" \
  --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" --output text)
if [ "$GATEWAY_ID" = "None" ] || [ -z "$GATEWAY_ID" ]; then
  GATEWAY_ID=$(aws bedrock-agentcore-control create-gateway \
    --name "$GATEWAY_NAME" --role-arn "$GATEWAY_ROLE_ARN" \
    --protocol-type MCP --authorizer-type AWS_IAM \
    --description "Tool-access layer fronting the Operata MCP server" \
    --protocol-configuration '{"mcp":{"searchType":"SEMANTIC"}}' \
    --exception-level DEBUG --region "$AWS_REGION" --query gatewayId --output text)
  info "created $GATEWAY_ID"
else
  info "reusing $GATEWAY_ID"
fi

for _ in $(seq 1 30); do
  S=$(aws bedrock-agentcore-control get-gateway --gateway-identifier "$GATEWAY_ID" \
      --region "$AWS_REGION" --query status --output text)
  [ "$S" = "READY" ] && break
  case "$S" in *FAILED*) die "gateway $S: $(aws bedrock-agentcore-control get-gateway \
      --gateway-identifier "$GATEWAY_ID" --region "$AWS_REGION" --query statusReasons --output text)";; esac
  info "status $S"; sleep 10
done
[ "$S" = "READY" ] || die "gateway did not reach READY"
read -r GATEWAY_URL GATEWAY_ARN <<<"$(aws bedrock-agentcore-control get-gateway \
  --gateway-identifier "$GATEWAY_ID" --region "$AWS_REGION" \
  --query '[gatewayUrl,gatewayArn]' --output text)"
info "READY"

step "[4/5] Operata MCP target"
TARGET_ID=$(aws bedrock-agentcore-control list-gateway-targets \
  --gateway-identifier "$GATEWAY_ID" --region "$AWS_REGION" \
  --query "items[?name=='$TARGET_NAME'].targetId | [0]" --output text)
# Operata authenticates with `Authorization: Bearer <key>`, so the credential
# goes in the standard header with a Bearer prefix.
TC=$(jq -nc --arg e "$OPERATA_MCP_ENDPOINT" '{mcp:{mcpServer:{endpoint:$e,listingMode:"DEFAULT"}}}')
CC=$(jq -nc --arg a "$PROVIDER_ARN" '[{credentialProviderType:"API_KEY",
      credentialProvider:{apiKeyCredentialProvider:{providerArn:$a,
        credentialLocation:"HEADER",credentialParameterName:"Authorization",
        credentialPrefix:"Bearer"}}}]')
if [ "$TARGET_ID" = "None" ] || [ -z "$TARGET_ID" ]; then
  TARGET_ID=$(aws bedrock-agentcore-control create-gateway-target \
    --gateway-identifier "$GATEWAY_ID" --name "$TARGET_NAME" \
    --description "Operata MCP server, API key endpoint" \
    --target-configuration "$TC" --credential-provider-configurations "$CC" \
    --region "$AWS_REGION" --query targetId --output text)
  info "created $TARGET_ID"
else
  aws bedrock-agentcore-control update-gateway-target \
    --gateway-identifier "$GATEWAY_ID" --target-id "$TARGET_ID" --name "$TARGET_NAME" \
    --target-configuration "$TC" --credential-provider-configurations "$CC" \
    --region "$AWS_REGION" >/dev/null
  info "updated $TARGET_ID"
fi

for _ in $(seq 1 30); do
  S=$(aws bedrock-agentcore-control get-gateway-target --gateway-identifier "$GATEWAY_ID" \
      --target-id "$TARGET_ID" --region "$AWS_REGION" --query status --output text)
  [ "$S" = "READY" ] && break
  case "$S" in *FAILED*|*UNSUCCESSFUL*) die "target $S: $(aws bedrock-agentcore-control \
      get-gateway-target --gateway-identifier "$GATEWAY_ID" --target-id "$TARGET_ID" \
      --region "$AWS_REGION" --query statusReasons --output text)";; esac
  info "status $S"; sleep 10
done
[ "$S" = "READY" ] || die "target did not reach READY"
info "READY"

step "[5/5] State"
jq -n --arg a "$ACCOUNT_ID" --arg r "$AWS_REGION" --arg gi "$GATEWAY_ID" \
      --arg gu "$GATEWAY_URL" --arg ga "$GATEWAY_ARN" --arg ti "$TARGET_ID" \
      --arg gr "$GATEWAY_ROLE_NAME" --arg pn "$PROVIDER_NAME" --arg ep "$OPERATA_MCP_ENDPOINT" \
  '{accountId:$a,region:$r,gatewayId:$gi,gatewayUrl:$gu,gatewayArn:$ga,targetId:$ti,
    gatewayRoleName:$gr,providerName:$pn,operataEndpoint:$ep}' > "$STATE_FILE"
info "wrote $(basename "$STATE_FILE")"

step "Gateway ready"
info "$GATEWAY_URL"
info ""
info "Next:  ./scripts/verify.sh"

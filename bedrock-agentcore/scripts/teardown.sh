#!/usr/bin/env bash
# Remove everything the other scripts created.
. "$(dirname "$0")/_common.sh"
require_tools aws jq

MANAGED_BY="operata-mcp-recipes/bedrock-agentcore"

# Only ever delete resources this recipe created. A name collision with
# something of yours must not cost you the resource.
lambda_is_ours () {
  local arn; arn=$(aws lambda get-function --function-name "$1" --region "$AWS_REGION" \
    --query Configuration.FunctionArn --output text 2>/dev/null) || return 1
  [ "$(aws lambda list-tags --resource "$arn" --region "$AWS_REGION" \
      --query 'Tags.ManagedBy' --output text 2>/dev/null)" = "$MANAGED_BY" ]
}
role_is_ours () {
  [ "$(aws iam list-role-tags --role-name "$1" \
      --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" = "$MANAGED_BY" ]
}

if [ -f "$STATE_FILE" ]; then
  GATEWAY_ID=$(jq -r .gatewayId "$STATE_FILE"); TARGET_ID=$(jq -r .targetId "$STATE_FILE")
else
  GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways --region "$AWS_REGION" \
    --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" --output text)
  TARGET_ID=$(aws bedrock-agentcore-control list-gateway-targets --gateway-identifier "$GATEWAY_ID" \
    --region "$AWS_REGION" --query 'items[0].targetId' --output text 2>/dev/null || echo None)
fi

step "Will delete, in $AWS_REGION"
info "lambda    $FUNCTION_NAME"
info "target    $TARGET_ID"
info "gateway   $GATEWAY_ID"
info "provider  $PROVIDER_NAME"
info "roles     $GATEWAY_ROLE_NAME, $LAMBDA_ROLE_NAME"
if [ "${FORCE:-no}" != "yes" ]; then
  read -r -p "Proceed? [y/N] " a; [ "$a" = "y" ] || { echo "Aborted."; exit 0; }
fi

step "Deleting"
if lambda_is_ours "$FUNCTION_NAME"; then
  aws lambda delete-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1 \
    && info "lambda deleted" || info "lambda already gone"
else
  info "lambda $FUNCTION_NAME not created by this recipe, left alone"
fi

if [ "$TARGET_ID" != "None" ] && [ -n "$TARGET_ID" ]; then
  aws bedrock-agentcore-control delete-gateway-target --gateway-identifier "$GATEWAY_ID" \
    --target-id "$TARGET_ID" --region "$AWS_REGION" >/dev/null 2>&1 && info "target deleted" || info "target already gone"
  for _ in $(seq 1 30); do
    aws bedrock-agentcore-control get-gateway-target --gateway-identifier "$GATEWAY_ID" \
      --target-id "$TARGET_ID" --region "$AWS_REGION" >/dev/null 2>&1 || break
    sleep 5
  done
fi
if [ "$GATEWAY_ID" != "None" ] && [ -n "$GATEWAY_ID" ]; then
  aws bedrock-agentcore-control delete-gateway --gateway-identifier "$GATEWAY_ID" \
    --region "$AWS_REGION" >/dev/null 2>&1 && info "gateway deleted" || info "gateway already gone"
fi
aws bedrock-agentcore-control delete-api-key-credential-provider --name "$PROVIDER_NAME" \
  --region "$AWS_REGION" >/dev/null 2>&1 && info "credential provider deleted" || info "provider already gone"

for R in "$GATEWAY_ROLE_NAME:OperataGatewayOutboundAuth" "$LAMBDA_ROLE_NAME:OperataIncidentOrchestrator"; do
  RN="${R%%:*}"; PN="${R##*:}"
  if aws iam get-role --role-name "$RN" >/dev/null 2>&1 && ! role_is_ours "$RN"; then
    info "role $RN not created by this recipe, left alone"; continue
  fi
  aws iam delete-role-policy --role-name "$RN" --policy-name "$PN" >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$RN" >/dev/null 2>&1 && info "role $RN deleted" || info "role $RN already gone"
done

rm -f "$STATE_FILE"
step "Done"

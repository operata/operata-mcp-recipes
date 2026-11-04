#!/usr/bin/env bash
# Remove everything the other scripts created.
. "$(dirname "$0")/_common.sh"
require_tools aws jq

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
# Found by name and tag, so it is cleaned up even if standin-state.json is gone.
if [ -f "$STANDIN_STATE" ] || lambda_is_ours "$STANDIN_FUNCTION_NAME" \
   || role_is_ours "$STANDIN_ROLE_NAME"; then
  info "stand-in  $STANDIN_FUNCTION_NAME, $STANDIN_ROLE_NAME"
fi
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

STANDIN_CLEAN=yes
if aws lambda get-function --function-name "$STANDIN_FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  if lambda_is_ours "$STANDIN_FUNCTION_NAME"; then
    # The URL config goes with the function. Remove it first anyway, so the public
    # URL is closed even if delete-function then fails.
    aws lambda delete-function-url-config --function-name "$STANDIN_FUNCTION_NAME" \
      --region "$AWS_REGION" >/dev/null 2>&1 || true
    if aws lambda delete-function --function-name "$STANDIN_FUNCTION_NAME" --region "$AWS_REGION" >/dev/null; then
      info "stand-in deleted"
    else
      info "stand-in $STANDIN_FUNCTION_NAME could not be deleted"; STANDIN_CLEAN=no
    fi
  else
    info "stand-in $STANDIN_FUNCTION_NAME not created by this recipe, left alone"
  fi
fi
if aws iam get-role --role-name "$STANDIN_ROLE_NAME" >/dev/null 2>&1; then
  if role_is_ours "$STANDIN_ROLE_NAME"; then
    aws iam delete-role-policy --role-name "$STANDIN_ROLE_NAME" --policy-name OperataMcpStandin >/dev/null 2>&1 || true
    if aws iam delete-role --role-name "$STANDIN_ROLE_NAME" >/dev/null; then
      info "role $STANDIN_ROLE_NAME deleted"
    else
      info "role $STANDIN_ROLE_NAME could not be deleted"; STANDIN_CLEAN=no
    fi
  else
    info "role $STANDIN_ROLE_NAME not created by this recipe, left alone"
  fi
fi

rm -f "$STATE_FILE"
# Keep standin-state.json until the stand-in is really gone: it is the only record of its URL.
if [ "$STANDIN_CLEAN" = yes ]; then
  rm -f "$STANDIN_STATE"
else
  die "The stand-in is not fully removed (see above). Fix the error and re-run teardown.sh."
fi
step "Done"

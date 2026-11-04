#!/usr/bin/env bash
# Deploy a stand-in for the Operata MCP server, for running the recipe before you
# have an Operata key. It serves twelve tools, named as in the Operata tool reference, with sample data.
# While OPERATA_API_KEY in config.env is still the placeholder, the other scripts
# use the stand-in. Paste a real key and re-run deploy-gateway.sh to switch.
# Re-runnable: existing resources are reused and updated in place, and a run that
# stopped half way picks up where it left off.
. "$(dirname "$0")/_common.sh"
require_tools aws jq zip

# Never overwrite a same-named role or function that this recipe did not create.
if aws iam get-role --role-name "$STANDIN_ROLE_NAME" >/dev/null 2>&1; then
  role_is_ours "$STANDIN_ROLE_NAME" \
    || die "Role $STANDIN_ROLE_NAME exists and was not created by this recipe. Set STANDIN_ROLE_NAME to another name."
fi
if aws lambda get-function --function-name "$STANDIN_FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  lambda_is_ours "$STANDIN_FUNCTION_NAME" \
    || die "Function $STANDIN_FUNCTION_NAME exists and was not created by this recipe. Set STANDIN_FUNCTION_NAME to another name."
fi

step "[1/3] Execution role"
if aws iam get-role --role-name "$STANDIN_ROLE_NAME" >/dev/null 2>&1; then
  info "reusing $STANDIN_ROLE_NAME"
else
  aws iam create-role --role-name "$STANDIN_ROLE_NAME" \
    --description "Execution role for the Operata MCP stand-in" \
    --tags Key=ManagedBy,Value="$MANAGED_BY" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{
      "Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},
      "Action":"sts:AssumeRole"}]}' >/dev/null
  info "created $STANDIN_ROLE_NAME, waiting for IAM propagation"
  sleep 20
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws iam put-role-policy --role-name "$STANDIN_ROLE_NAME" --policy-name OperataMcpStandin \
  --policy-document "$(jq -nc --arg a "$ACCOUNT_ID" --arg r "$AWS_REGION" '
    {Version:"2012-10-17",Statement:[{Sid:"Logs",Effect:"Allow",
      Action:["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
      Resource:("arn:aws:logs:"+$r+":"+$a+":*")}]}')"
STANDIN_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${STANDIN_ROLE_NAME}"

step "[2/3] Function"
ZIP="$ROOT/standin.zip"; rm -f "$ZIP"
( cd "$ROOT/standin" && zip -q "$ZIP" operata_standin.py tools.json )
# The stand-in's key only guards sample data, but it is still kept out of the repo.
if [ -f "$STANDIN_STATE" ]; then
  STANDIN_KEY=$(jq -r .key "$STANDIN_STATE")
else
  # Read a fixed amount first: tr on an endless /dev/urandom dies of SIGPIPE under pipefail.
  STANDIN_KEY=$(head -c 48 /dev/urandom | base64 | LC_ALL=C tr -dc 'A-Za-z0-9')
fi
ENVVARS="Variables={STANDIN_KEY=$STANDIN_KEY}"
if aws lambda get-function --function-name "$STANDIN_FUNCTION_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$STANDIN_FUNCTION_NAME" \
    --zip-file "fileb://$ZIP" --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$STANDIN_FUNCTION_NAME" --region "$AWS_REGION"
  aws lambda update-function-configuration --function-name "$STANDIN_FUNCTION_NAME" \
    --environment "$ENVVARS" --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$STANDIN_FUNCTION_NAME" --region "$AWS_REGION"
  info "updated $STANDIN_FUNCTION_NAME"
else
  aws lambda create-function --function-name "$STANDIN_FUNCTION_NAME" \
    --runtime python3.13 --role "$STANDIN_ROLE_ARN" --handler operata_standin.handler \
    --zip-file "fileb://$ZIP" --timeout 30 --memory-size 256 \
    --environment "$ENVVARS" --region "$AWS_REGION" \
    --tags ManagedBy="$MANAGED_BY" \
    --description "Stand-in for the Operata MCP server, sample data only" >/dev/null
  aws lambda wait function-active-v2 --function-name "$STANDIN_FUNCTION_NAME" --region "$AWS_REGION"
  info "created $STANDIN_FUNCTION_NAME"
fi
rm -f "$ZIP"
# The URL is public, so cap what a flood of requests can run. A new account may not
# have the spare concurrency to reserve; the stand-in still works without the cap.
aws lambda put-function-concurrency --function-name "$STANDIN_FUNCTION_NAME" \
  --reserved-concurrent-executions 5 --region "$AWS_REGION" >/dev/null \
  || info "could not reserve concurrency; the URL is not capped, so teardown when you are done"

step "[3/3] Function URL"
# The gateway reaches MCP servers over HTTPS with a Bearer key, so the stand-in
# needs a URL. It answers only requests that carry its key.
# Each piece is checked on its own, so a run that stopped half way can be re-run.
if URL=$(aws lambda get-function-url-config --function-name "$STANDIN_FUNCTION_NAME" \
     --region "$AWS_REGION" --query FunctionUrl --output text 2>/dev/null); then
  info "reusing the function URL"
else
  URL=$(aws lambda create-function-url-config --function-name "$STANDIN_FUNCTION_NAME" \
    --auth-type NONE --region "$AWS_REGION" --query FunctionUrl --output text) \
    || die "Could not create a function URL. Some organisations block public function URLs;
  if yours does, use a real Operata key instead of the stand-in."
  info "created the function URL"
fi
POLICY=$(aws lambda get-policy --function-name "$STANDIN_FUNCTION_NAME" --region "$AWS_REGION" \
  --query Policy --output text 2>/dev/null || echo '{}')
has_statement () {
  printf '%s' "$POLICY" | jq -e --arg s "$1" '.Statement[]? | select(.Sid == $s)' >/dev/null
}
if ! has_statement url; then
  aws lambda add-permission --function-name "$STANDIN_FUNCTION_NAME" --statement-id url \
    --action lambda:InvokeFunctionUrl --principal '*' --function-url-auth-type NONE \
    --region "$AWS_REGION" >/dev/null
  info "allowed public invoke of the URL"
fi
if ! has_statement invoke; then
  aws lambda add-permission --function-name "$STANDIN_FUNCTION_NAME" --statement-id invoke \
    --action lambda:InvokeFunction --principal '*' --invoked-via-function-url \
    --region "$AWS_REGION" >/dev/null
  info "allowed invoke via the URL"
fi
info "$URL"

( umask 077; jq -n --arg u "$URL" --arg k "$STANDIN_KEY" --arg f "$STANDIN_FUNCTION_NAME" \
    --arg r "$STANDIN_ROLE_NAME" '{url:$u,key:$k,functionName:$f,roleName:$r}' > "$STANDIN_STATE" )
info "wrote $(basename "$STANDIN_STATE")"

step "Stand-in ready"
info "Leave OPERATA_API_KEY as the placeholder in config.env and run the usual steps:"
info "  ./scripts/deploy-gateway.sh"

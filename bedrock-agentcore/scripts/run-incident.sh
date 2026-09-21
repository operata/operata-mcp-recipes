#!/usr/bin/env bash
# Invoke the Lambda with a sample incident and print the diagnosis.
#   ./scripts/run-incident.sh [path/to/event.json]
. "$(dirname "$0")/_common.sh"
require_tools aws jq
EVENT="${1:-$ROOT/events/incident.json}"
[ -f "$EVENT" ] || die "No such event file: $EVENT"

step "Invoking $FUNCTION_NAME"
info "this takes a couple of minutes while the model works"
OUT="$ROOT/out.json"

invoke () {
  aws lambda invoke --function-name "$FUNCTION_NAME" --region "$AWS_REGION" \
    --cli-binary-format raw-in-base64-out --cli-read-timeout 660 \
    --payload "file://$EVENT" "$OUT" >/dev/null
  jq -r '.statusCode // "?"' "$OUT"
}

CODE=$(invoke)
# A freshly created execution role can take a minute to be visible to the
# gateway. Retry once on the permission error that produces.
if [ "$CODE" != "200" ] && jq -r '.body' "$OUT" | grep -q 'Insufficient permissions'; then
  info "execution role not visible to the gateway yet, waiting 45s and retrying"
  sleep 45
  CODE=$(invoke)
fi

if [ "$CODE" != "200" ]; then
  step "Failed (statusCode $CODE)"; jq -r '.body' "$OUT"; exit 1
fi

step "Tool calls"
jq -r '.body|fromjson|.toolCalls[]|"  turn \(.turn)  \(.tool)  \(if .is_error then "ERROR" else "ok" end)"' "$OUT"
step "Diagnosis"
jq -r '.body|fromjson|.troubleshooting' "$OUT"
step "Run"
jq -r '.body|fromjson|"  \(.turns) turns, \(.toolCalls|length) tool calls, \(.usage.totalTokens // "?") tokens"' "$OUT"

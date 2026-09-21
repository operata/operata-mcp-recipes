#!/usr/bin/env bash
# Call any Operata tool through the gateway.
#   ./scripts/call.sh list_groups
#   ./scripts/call.sh knowledge '{"query":"What is MOS?"}'
#   ./scripts/call.sh traces_list '{"startTime":"2026-01-01T00:00:00Z","endTime":"2026-01-02T00:00:00Z","limit":1}'
. "$(dirname "$0")/_common.sh"
require_tools aws curl jq; require_state
[ $# -ge 1 ] || die "Usage: $0 <tool-name> ['<json-arguments>']"
GATEWAY_URL=$(jq -r .gatewayUrl "$STATE_FILE"); export GATEWAY_URL

TOOL="$1"
case "$TOOL" in *___*) ;; *) TOOL="${TARGET_NAME}___${TOOL}";; esac
ARGS="${2:-{\}}"

sigv4_args; mcp_init
REQ=$(jq -nc --arg n "$TOOL" --argjson a "$ARGS" \
  '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$n,arguments:$a}}')
OUT=$(mcp_rpc "$REQ" | jq -r '.result.content[0].text // (.error|tostring)')
# Operata's payload arrives as JSON inside the MCP text block, so decode twice.
echo "$OUT" | jq . 2>/dev/null || echo "$OUT"

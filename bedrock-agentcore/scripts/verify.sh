#!/usr/bin/env bash
# Prove the whole path: your credentials -> gateway -> Operata -> real data.
. "$(dirname "$0")/_common.sh"
require_tools aws curl jq; require_state
GATEWAY_URL=$(jq -r .gatewayUrl "$STATE_FILE"); export GATEWAY_URL
sigv4_args; mcp_init

step "Tools exposed by the gateway"
TOOLS=$(mcp_rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
N=$(printf '%s' "$TOOLS" | jq '.result.tools | length')
[ "${N:-0}" -gt 0 ] || die "tools/list returned nothing: $TOOLS"
printf '%s' "$TOOLS" | jq -r '.result.tools[].name' | sed 's/^/  /'
info ""
info "$N tools"

step "Live call: list_groups"
mcp_rpc '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"'"${TARGET_NAME}"'___list_groups","arguments":{}}}' \
  | jq -r '.result.content[0].text // (.error|tostring)' | jq . | sed 's/^/  /'

step "Verified"
info "The gateway holds the Operata key. Nothing here sent it."

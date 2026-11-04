# Shared setup. Sourced by every script; not executable on its own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${STATE_FILE:-$ROOT/gateway-state.json}"

[ -f "$ROOT/config.env" ] || {
  echo "config.env not found. Copy it and fill in your values:" >&2
  echo "  cp config.env.example config.env" >&2
  exit 1
}
# shellcheck disable=SC1091
set -a; . "$ROOT/config.env"; set +a
export AWS_REGION

step () { printf '\n\033[1m%s\033[0m\n' "$*"; }
info () { printf '  %s\n' "$*"; }
die  () { printf '\nError: %s\n' "$*" >&2; exit 1; }

# What this recipe tags on the IAM roles and Lambda functions it creates.
MANAGED_BY="operata-mcp-recipes/bedrock-agentcore"

# No Operata key yet? deploy-standin.sh leaves a stand-in serving sample data.
# While the key is still the placeholder, every script points at the stand-in.
STANDIN_STATE="${STANDIN_STATE:-$ROOT/standin-state.json}"
STANDIN_FUNCTION_NAME="${STANDIN_FUNCTION_NAME:-operata-mcp-standin}"
STANDIN_ROLE_NAME="${STANDIN_ROLE_NAME:-OperataMcpStandinRole}"
USING_STANDIN=no
if [ "${OPERATA_API_KEY:-}" = "paste-your-key-here" ] && [ -f "$STANDIN_STATE" ]; then
  command -v jq >/dev/null || die "jq is not installed."
  OPERATA_API_KEY=$(jq -r .key "$STANDIN_STATE")
  OPERATA_MCP_ENDPOINT=$(jq -r .url "$STANDIN_STATE")
  export OPERATA_API_KEY OPERATA_MCP_ENDPOINT
  USING_STANDIN=yes
  echo "Using the stand-in (sample data): OPERATA_API_KEY in config.env is still the placeholder." >&2
fi

require_tools () {
  for c in "$@"; do command -v "$c" >/dev/null || die "$c is not installed."; done
}

# Only ever touch resources this recipe created. A name collision with
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

require_state () {
  [ -f "$STATE_FILE" ] || die "No $STATE_FILE. Run ./scripts/deploy-gateway.sh first."
}

# Build the curl args that sign a request to the gateway with your own
# credentials. AWS_IAM inbound auth means there is no token to mint.
sigv4_args () {
  eval "$(aws configure export-credentials --format env)"
  SIGV4=(--aws-sigv4 "aws:amz:${AWS_REGION}:bedrock-agentcore"
         --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}")
  [ -n "${AWS_SESSION_TOKEN:-}" ] && SIGV4+=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
}

# One MCP JSON-RPC call. The gateway answers with plain JSON or an SSE stream
# depending on the call, so strip SSE framing before the caller parses it.
mcp_rpc () {
  curl -sS -m "${MCP_TIMEOUT:-90}" -X POST "$GATEWAY_URL" "${SIGV4[@]}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2025-03-26' \
    -d "$1" | sed -e 's/^data: //' -e '/^event:/d' -e '/^id:/d' -e '/^$/d'
}

mcp_init () {
  mcp_rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"operata-quickstart","version":"1"}}}' >/dev/null
}

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

require_tools () {
  for c in "$@"; do command -v "$c" >/dev/null || die "$c is not installed."; done
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

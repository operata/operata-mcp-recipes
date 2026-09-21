"""Minimal MCP client for an AgentCore Gateway using SigV4 (AWS_IAM inbound auth).

Speaks MCP streamable-HTTP JSON-RPC directly. Uses only the standard library
plus botocore, both of which are present in the Lambda Python runtime, so the
deployment package needs no vendored dependencies.
"""

import json
import urllib.error
import urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

# Preferred first, oldest last. AgentCore Gateway currently negotiates
# 2025-03-26; the client falls back to whatever the server advertises rather
# than pinning a version that later stops being accepted.
PREFERRED_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26"]
SERVICE = "bedrock-agentcore"


class McpError(RuntimeError):
    pass


class GatewayMcpClient:
    """Calls an AgentCore Gateway's MCP endpoint, signing each request with SigV4.

    The gateway is created with authorizerType=AWS_IAM, so the caller's own
    credentials (the Lambda execution role) are the only thing needed. There is
    no token to mint, cache or rotate.
    """

    def __init__(self, gateway_url, region, session=None, timeout=60):
        self.gateway_url = gateway_url
        self.region = region
        self.timeout = timeout
        self._session = session or boto3.Session()
        self._credentials = self._session.get_credentials()
        if self._credentials is None:
            raise McpError("No AWS credentials available to sign gateway requests.")
        self._signer = SigV4Auth(self._credentials, SERVICE, region)
        self._session_id = None
        self._next_id = 0
        self._initialized = False
        self._protocol_version = PREFERRED_PROTOCOL_VERSIONS[0]

    # -- transport ---------------------------------------------------------

    def _rpc(self, method, params=None, is_notification=False):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not is_notification:
            self._next_id += 1
            body["id"] = self._next_id

        payload = json.dumps(body).encode()
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self._protocol_version,
        }
        if self._session_id:
            headers["Mcp-Session-Id"] = self._session_id

        # Sign after all headers that travel with the request are set, so the
        # signature covers them.
        aws_req = AWSRequest(method="POST", url=self.gateway_url, data=payload, headers=headers)
        self._signer.add_auth(aws_req)
        signed_headers = dict(aws_req.headers)

        req = urllib.request.Request(self.gateway_url, data=payload, headers=signed_headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                session_id = resp.headers.get("Mcp-Session-Id")
                if session_id:
                    self._session_id = session_id
                raw = resp.read().decode()
                content_type = resp.headers.get("Content-Type", "")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            negotiated = self._version_from_error(detail)
            if negotiated and negotiated != self._protocol_version:
                # The server told us which versions it accepts. Adopt one and retry.
                self._protocol_version = negotiated
                return self._rpc(method, params, is_notification)
            raise McpError(f"Gateway returned HTTP {exc.code} for {method}: {detail}") from exc

        if is_notification:
            return None
        return self._parse(raw, content_type, method)

    def _version_from_error(self, detail):
        """Pull a usable protocol version out of an unsupported-version error."""
        try:
            supported = json.loads(detail)["error"]["data"]["supported"]
        except (ValueError, KeyError, TypeError):
            return None
        for candidate in PREFERRED_PROTOCOL_VERSIONS:
            if candidate in supported:
                return candidate
        return supported[0] if supported else None

    @staticmethod
    def _parse(raw, content_type, method):
        """Handle both a plain JSON body and an SSE stream carrying one result."""
        message = None
        if "text/event-stream" in content_type:
            for line in raw.splitlines():
                if line.startswith("data:"):
                    candidate = json.loads(line[len("data:"):].strip())
                    if "result" in candidate or "error" in candidate:
                        message = candidate
                        break
        elif raw.strip():
            message = json.loads(raw)

        if message is None:
            raise McpError(f"Empty or unparseable response for {method}: {raw[:500]!r}")
        if "error" in message:
            raise McpError(f"{method} failed: {json.dumps(message['error'])}")
        return message.get("result", {})

    # -- MCP lifecycle -----------------------------------------------------

    def initialize(self):
        if self._initialized:
            return
        result = self._rpc(
            "initialize",
            {
                "protocolVersion": self._protocol_version,
                "capabilities": {},
                "clientInfo": {"name": "operata-incident-orchestrator", "version": "1.0.0"},
            },
        )
        # Honour whatever the server settled on, not what we asked for.
        agreed = (result or {}).get("protocolVersion")
        if agreed:
            self._protocol_version = agreed
        self._rpc("notifications/initialized", {}, is_notification=True)
        self._initialized = True

    def list_tools(self):
        self.initialize()
        tools, cursor = [], None
        while True:
            params = {"cursor": cursor} if cursor else {}
            result = self._rpc("tools/list", params)
            tools.extend(result.get("tools", []))
            cursor = result.get("nextCursor")
            if not cursor:
                return tools

    def call_tool(self, name, arguments):
        self.initialize()
        return self._rpc("tools/call", {"name": name, "arguments": arguments})

    # -- Bedrock bridge ----------------------------------------------------

    def to_bedrock_tool_config(self, tools):
        """Convert MCP tool definitions into a Bedrock Converse toolConfig."""
        specs = []
        for tool in tools:
            schema = tool.get("inputSchema") or {"type": "object", "properties": {}}
            specs.append(
                {
                    "toolSpec": {
                        "name": tool["name"],
                        "description": (tool.get("description") or tool["name"])[:1000],
                        "inputSchema": {"json": schema},
                    }
                }
            )
        return {"tools": specs}

    @staticmethod
    def flatten_result(result):
        """Reduce an MCP tool result to text for the model."""
        parts = []
        for block in result.get("content", []):
            if block.get("type") == "text":
                parts.append(block.get("text", ""))
            else:
                parts.append(json.dumps(block))
        text = "\n".join(p for p in parts if p)
        if not text:
            text = json.dumps(result)
        return text, bool(result.get("isError"))

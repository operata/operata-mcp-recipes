"""A stand-in for the Operata MCP server, for running this recipe before you have an Operata key.

It serves twelve tool names and arguments copied from the Operata MCP tool reference
(https://docs.operata.com/docs/guides-mcp-tools, as of 2026-11), listed in tools.json, and
answers every call with a fixed sample: one ISP in one city dragging MOS down. Every tool
result says it is sample data. Nothing here talks to Operata.

It checks `Authorization: Bearer <key>` the way the API-key endpoint does, so the gateway's
credential provider is exercised exactly as it will be against Operata.

Standard library only, like the rest of the recipe. Deployed by scripts/deploy-standin.sh.
"""

import base64
import hmac
import json
import logging
import os

log = logging.getLogger()
log.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

NOTE = "SAMPLE DATA from the recipe stand-in, not from Operata."
PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26"]
GROUP = {"groupId": "sample-group", "groupName": "Sample Contact Centre",
         "region": "ap-southeast-2"}

with open(os.path.join(os.path.dirname(__file__), "tools.json")) as f:
    TOOLS = json.load(f)

FLEET = {"calls": 4216, "mos": 4.02, "jitter_ms": 11.3, "rtt_ms": 95, "packet_loss_pct": 0.4}
BY_ISP = [
    {"network.isp": "Sample ISP A", "network.city": "Brisbane", "calls": 130, "mos": 2.93,
     "jitter_ms": 37.8, "rtt_ms": 458, "packet_loss_pct": 3.1},
    {"network.isp": "Sample ISP B", "network.city": "Sydney", "calls": 2210, "mos": 4.12,
     "jitter_ms": 10.9, "rtt_ms": 91, "packet_loss_pct": 0.3},
    {"network.isp": "Sample ISP C", "network.city": "Melbourne", "calls": 1876, "mos": 4.08,
     "jitter_ms": 11.6, "rtt_ms": 97, "packet_loss_pct": 0.3},
]
TRACE_A = "8b1c0813ca3ca75494be82e036177ef1"
TRACE_B = "f3a90c2e5d7b41e88c6a0b9d2e4f1a37"
SPAN = "a1b2c3d4e5f60718"

SCHEMA = {
    "services": ["agent_interaction", "node_interaction", "ai_interaction", "journey_interaction"],
    "queryTypes": ["scalar", "series", "table", "rate", "facet"],
    "queryShape": {
        "scalar": [{"key": "<name>", "service": "agent_interaction",
                    "aggregates": [{"name": "<name>", "fn": "count|avg|p90", "path": "<column>"}]}],
        "facet": [{"key": "<name>", "service": "agent_interaction", "by": "<column>"}],
    },
    "aggregateFunctions": ["count", "avg", "min", "max", "p50", "p90", "p99"],
    "filterOperators": ["eq", "gt", "lt"],
    "columns": {"agent_interaction": ["mos", "jitter_ms", "rtt_ms", "packet_loss_pct",
                                      "network.isp", "network.city", "agent", "had_queue"]},
    "timeFormat": "ISO 8601 UTC",
}
KNOWLEDGE = ("Jitter is the variation in packet arrival time. Above about 30 ms, voice starts "
             "to sound choppy unless the jitter buffer absorbs it.")
TRACES = [
    {"traceId": TRACE_A, "spanName": "cx.interaction.agent", "durationMs": 412000,
     "spanCount": 37, "status": "OK", "network.isp": "Sample ISP A"},
    {"traceId": TRACE_B, "spanName": "cx.interaction.agent", "durationMs": 198000,
     "spanCount": 22, "status": "ERROR", "network.isp": "Sample ISP A"},
]
SPAN_LOG = {"level": "WARN", "component": "webrtc-sdk", "text": "jitter buffer expanded to 120 ms"}
AGENT_LOG = {"level": "ERROR", "component": "softphone",
             "text": "ICE connection state: disconnected"}
ISSUE = {"category": "audio", "scenario": "choppy audio", "count": 17, "city": "Brisbane"}


def _traces_query(args):
    results = {}
    queries = args.get("queries")
    for kind, items in (queries if isinstance(queries, dict) else {}).items():
        for q in items if isinstance(items, list) else [items]:
            key = q.get("key", kind) if isinstance(q, dict) else kind
            if kind in ("facet", "table"):
                results[key] = BY_ISP
            elif kind == "rate":
                results[key] = {"rate": 0.031, "matching": 130, "total": 4216}
            elif kind == "series":
                results[key] = [{"t": "2026-01-01T%02d:00:00Z" % h, "mos": 4.0 if h < 18 else 3.1}
                                for h in range(0, 24, 6)]
            else:
                results[key] = FLEET
    return {"results": results}


def _switch_group(args):
    if args.get("groupId") == GROUP["groupId"]:
        return {"activeGroup": GROUP}
    return {"error": {"status": 403, "message": "API key access is restricted to its own group"}}


def _traces_get(args):
    attributes = {"mos": 2.7, "network.isp": "Sample ISP A", "network.city": "Brisbane"}
    return {"traceId": args.get("traceId"),
            "spans": [{"spanId": SPAN, "name": "cx.interaction.agent", "attributes": attributes}]}


SAMPLES = {
    "get_schema": lambda a: SCHEMA,
    "knowledge": lambda a: {"query": a.get("query"), "answer": KNOWLEDGE},
    "list_groups": lambda a: {"groups": [GROUP]},
    "switch_group": _switch_group,
    "traces_list": lambda a: {"traces": TRACES, "cursor": None},
    "traces_query": _traces_query,
    "traces_get": _traces_get,
    "traces_insights": lambda a: {"insights": [
        {"spanId": SPAN, "type": "high_jitter", "detail": "Jitter 41 ms on the agent leg"}]},
    "traces_span_logs": lambda a: {"logs": [SPAN_LOG], "cursor": None},
    "agent_logs": lambda a: {"total": 1, "logs": [AGENT_LOG], "cursor": None},
    "agent_status": lambda a: {"changes": [
        {"agent": "agent01@example.com", "status": "Available"}], "cursor": None},
    "agent_reported_issues": lambda a: {"issues": [ISSUE], "cursor": None},
}


def _response(status, body=None):
    return {"statusCode": status, "headers": {"Content-Type": "application/json"},
            "body": "" if body is None else json.dumps(body)}


def _error(mid, code, message):
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}


def _handle(message):
    if not isinstance(message, dict):
        return _error(None, -32600, "Invalid Request")
    method, mid, params = message.get("method"), message.get("id"), message.get("params")
    if mid is None:  # notifications need no answer
        return None
    if params is None:
        params = {}
    if not isinstance(params, dict):
        return _error(mid, -32602, "params must be an object")
    if method == "initialize":
        asked = params.get("protocolVersion")
        result = {"protocolVersion": asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                  "capabilities": {"tools": {"listChanged": False}},
                  "serverInfo": {"name": "operata-recipe-standin", "version": "1.0.0"}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        name, arguments = params.get("name"), params.get("arguments")
        if arguments is None:
            arguments = {}
        if not isinstance(name, str) or name not in SAMPLES:
            return _error(mid, -32602, f"Unknown tool: {name}")
        if not isinstance(arguments, dict):
            return _error(mid, -32602, "arguments must be an object")
        text = json.dumps({"_note": NOTE, **SAMPLES[name](arguments)})
        result = {"content": [{"type": "text", "text": text}], "isError": False}
    else:
        return _error(mid, -32601, f"Method not found: {method}")
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def _key_matches(auth):
    expected = f"Bearer {os.environ['STANDIN_KEY']}"
    # Constant-time compare; encode first because compare_digest rejects non-ASCII str.
    return hmac.compare_digest(auth.encode("utf-8", "replace"), expected.encode("utf-8"))


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not _key_matches(str(headers.get("authorization", ""))):
        log.warning("Refused a request without the stand-in key")
        return _response(401, {"error": "Unauthorized"})
    http = (event.get("requestContext") or {}).get("http") or {}
    if http.get("method", "POST") != "POST":
        return _response(405, {"error": "Method not allowed"})
    raw = event.get("body") or ""
    try:
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode()
        message = json.loads(raw)
    except ValueError:
        return _response(400, _error(None, -32700, "Parse error"))
    if isinstance(message, list):
        if not message:
            return _response(400, _error(None, -32600, "Invalid Request"))
        replies = [r for r in map(_handle, message) if r is not None]
        return _response(200, replies) if replies else _response(202)
    if isinstance(message, dict):
        log.info("MCP %s", message.get("method"))
    reply = _handle(message)
    if reply is None:
        return _response(202)
    return _response(400 if "error" in reply and reply["id"] is None else 200, reply)

"""Bedrock Converse tool-calling loop over Operata MCP tools via AgentCore Gateway.

This is the piece that slots into an existing custom Lambda orchestrator. The
Lambda keeps owning the incident workflow; this adds the loop that lets Claude
reach for Operata tools when it needs evidence.
"""

import json
import logging
import os

import boto3

from mcp_gateway_client import GatewayMcpClient

log = logging.getLogger(__name__)

DEFAULT_MODEL_ID = "us.anthropic.claude-sonnet-5"
MAX_TURNS = int(os.environ.get("MAX_TOOL_TURNS", "12"))

SYSTEM_PROMPT = """You are a contact-centre incident analyst for a voice operations team.

You have live access to Operata tools covering call traces, agent status, agent
logs, reported issues and a product knowledge base. Use them to ground every
claim in real data.

Method:
- Start with the incident details you are given. Decide what evidence would
  confirm or rule out a cause, then fetch it. Call `get_schema` before building
  a non-trivial `traces_query` so the fields you use actually exist.
- Prefer several narrow queries over one broad one. Quote the concrete numbers
  you find.
- If a tool errors or returns nothing, say so and adjust rather than guessing.

Finish with:
1. What happened - one or two sentences.
2. Evidence - the specific figures and what tool produced them.
3. Most likely cause - with your confidence and what would raise it.
4. Next steps - concrete actions for the technical support engineer.

Be concise and factual. Do not speculate beyond the data."""


def build_client():
    gateway_url = os.environ["GATEWAY_URL"]
    region = os.environ.get("GATEWAY_REGION") or os.environ.get("AWS_REGION", "us-west-2")
    return GatewayMcpClient(gateway_url=gateway_url, region=region)


def run_incident_analysis(incident_prompt, model_id=None, mcp_client=None, bedrock=None, verbose=False):
    """Run the tool-calling loop until Claude stops asking for tools.

    Returns a dict with the final answer plus a trace of every tool call, which
    is what makes the demo legible to a customer watching it run.
    """
    model_id = model_id or os.environ.get("MODEL_ID", DEFAULT_MODEL_ID)
    region = os.environ.get("BEDROCK_REGION") or os.environ.get("AWS_REGION", "us-west-2")
    mcp = mcp_client or build_client()
    bedrock = bedrock or boto3.client("bedrock-runtime", region_name=region)

    tools = mcp.list_tools()
    tool_config = mcp.to_bedrock_tool_config(tools)
    log.info("Discovered %d tools via gateway: %s", len(tools), [t["name"] for t in tools])
    if verbose:
        print(f"  Gateway exposed {len(tools)} tools: {', '.join(t['name'] for t in tools)}\n")

    messages = [{"role": "user", "content": [{"text": incident_prompt}]}]
    call_trace = []

    for turn in range(1, MAX_TURNS + 1):
        response = bedrock.converse(
            modelId=model_id,
            messages=messages,
            system=[{"text": SYSTEM_PROMPT}],
            toolConfig=tool_config,
            # Sonnet 5 rejects `temperature`; leave sampling at the model default.
            inferenceConfig={"maxTokens": 4096},
        )

        output_message = response["output"]["message"]
        messages.append(output_message)
        stop_reason = response["stopReason"]

        if stop_reason != "tool_use":
            final_text = "".join(
                block["text"] for block in output_message["content"] if "text" in block
            )
            return {
                "answer": final_text,
                "tool_calls": call_trace,
                "turns": turn,
                "stop_reason": stop_reason,
                "usage": response.get("usage", {}),
            }

        tool_results = []
        for block in output_message["content"]:
            if "toolUse" not in block:
                continue
            tool_use = block["toolUse"]
            name, args = tool_use["name"], tool_use["input"]
            if verbose:
                print(f"  [turn {turn}] -> {name}({json.dumps(args)[:180]})")

            try:
                raw = mcp.call_tool(name, args)
                text, is_error = mcp.flatten_result(raw)
            except Exception as exc:  # surface the failure to the model, don't crash the loop
                log.warning("Tool %s failed: %s", name, exc)
                text, is_error = f"Tool call failed: {exc}", True

            call_trace.append(
                {"turn": turn, "tool": name, "arguments": args, "is_error": is_error,
                 "result_preview": text[:500]}
            )
            if verbose:
                flag = "ERROR" if is_error else "ok"
                print(f"             <- {flag}, {len(text)} chars\n")

            tool_results.append(
                {
                    "toolResult": {
                        "toolUseId": tool_use["toolUseId"],
                        "content": [{"text": text[:100_000]}],
                        "status": "error" if is_error else "success",
                    }
                }
            )

        messages.append({"role": "user", "content": tool_results})

    return {
        "answer": "Stopped: reached the maximum number of tool-calling turns without a final answer.",
        "tool_calls": call_trace,
        "turns": MAX_TURNS,
        "stop_reason": "max_turns",
        "usage": {},
    }

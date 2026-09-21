# Operata MCP tools in Amazon Bedrock

One of the [Operata MCP recipes](../README.md).

This repo stands up an Amazon Bedrock AgentCore Gateway that exposes the [Operata MCP server](https://docs.operata.com/docs/guides-mcp-intro) tools to a Bedrock model, plus a Lambda that hands a voice quality incident to Claude and gets back a diagnosis with the figures behind it. It is for engineers with an AWS account and an Operata group who want the integration running before deciding how to build on it. Fork it, set six values, run three scripts.

Companion guide: [Diagnose voice incidents with Amazon Bedrock](https://docs.operata.com/docs/guides-mcp-bedrock-agentcore).

## How it works

```
incident event
      │
      ▼
Lambda (your orchestration)
  ├─ Converse loop ──────▶ Bedrock Claude   (returns toolUse blocks)
  └─ MCP JSON-RPC, SigV4 ─▶ AgentCore Gateway
                              inbound:  AWS_IAM
                              outbound: API key
                              └─ Authorization: Bearer <key> ─▶ Operata MCP
```

The Lambda owns the workflow. The gateway is the tool-access layer and holds the Operata key.

Inbound auth is `AWS_IAM`, so the Lambda's execution role signs each request with SigV4. There is no Cognito user pool, no client secret, and no token cache. Outbound, AgentCore Identity stores your Operata key in Secrets Manager and injects it as `Authorization: Bearer <key>`. The key never reaches the Lambda, the model, or this repo.

## Before you start

- An AWS account with Bedrock model access for Claude, in a region where AgentCore Gateway is available. Verified in `us-west-2`.
- Permission to create IAM roles, AgentCore gateways and targets, and a Lambda function.
- `aws` CLI v2, `curl` 7.75 or later, `jq`, and `zip`. `curl` needs `--aws-sigv4` to sign gateway calls.
- An Operata API key from **Group Settings → API Management → Create New Key**. This is not the REST token under Settings → Config → API; the MCP endpoint rejects that one.

## Steps

```bash
cp config.env.example config.env
$EDITOR config.env          # set OPERATA_API_KEY, check the endpoint and region

./scripts/deploy-gateway.sh # role, credential provider, gateway, Operata target
./scripts/verify.sh         # lists the 13 tools and makes a live call
./scripts/deploy-lambda.sh  # execution role, package, function
./scripts/run-incident.sh   # invoke with events/incident.json and print the diagnosis
```

`deploy-gateway.sh` checks your Operata key against Operata before it creates anything in AWS, so a key from the wrong environment fails in the first few seconds rather than part-way through.

Both deploy scripts are re-runnable. They reuse what exists and update it in place.

## Configuration

Everything lives in `config.env`, which is gitignored.

| Variable | What it is |
| --- | --- |
| `OPERATA_API_KEY` | Your key from Group Settings → API Management |
| `OPERATA_MCP_ENDPOINT` | `https://api.operata.io/v1/mcp` for production, `https://api-dev.operata.io/v1/mcp` for dev. Must match the console the key came from |
| `AWS_REGION` | Where the gateway and Lambda go |
| `MODEL_ID` | Any Claude model your account can reach in that region |
| `GATEWAY_NAME`, `TARGET_NAME`, `FUNCTION_NAME`, and the two role names | Change only if they collide with something you already own |
| `MAX_TOOL_TURNS` | How many tool-calling rounds the model may take |

## What you get

`verify.sh` lists 13 tools. Twelve are Operata's, prefixed with the target name — `operata___traces_query`, `operata___agent_logs`, `operata___knowledge` and the rest, documented in the [MCP tool reference](https://docs.operata.com/docs/guides-mcp-tools). The thirteenth, `x_amz_bedrock_agentcore_search`, comes from the gateway and lets the model search the tool catalogue instead of carrying every schema in context.

`run-incident.sh` prints each tool call the model makes, then its diagnosis. One run against the sample incident took 9 turns and 12 tool calls, and traced a mean opinion score (MOS) of 2.9 to one ISP in one city: 130 calls averaging MOS 2.93, jitter at 37.8 ms against an 11.3 ms fleet baseline, and round-trip time at 458 ms against 95 ms. Your numbers will differ.

## Call a tool directly

```bash
./scripts/call.sh list_groups
./scripts/call.sh knowledge '{"query":"What is jitter?"}'
./scripts/call.sh traces_query '{"startTime":"2026-01-01T00:00:00Z","endTime":"2026-01-02T00:00:00Z","queries":{"scalar":[{"key":"mos","service":"agent_interaction","aggregates":[{"name":"calls","fn":"count","path":"*"}]}]}}'
```

## Use it in your own Lambda

Three files in `lambda/` are the whole integration:

- `mcp_gateway_client.py` — MCP client that signs each request with SigV4 and negotiates the protocol version. Standard library and `botocore` only, both already in the Lambda Python runtime, so the deployment package needs no vendored dependencies.
- `incident_agent.py` — the Bedrock Converse tool-calling loop: list tools, convert them to a `toolConfig`, run the loop until the model stops asking for tools.
- `handler.py` — turns an incident event into a prompt and returns the diagnosis with a trace of every tool call.

Copy the first two into an existing function, set `GATEWAY_URL` and `MODEL_ID`, and add two statements to its execution role: `bedrock:InvokeModel`, and `bedrock-agentcore:InvokeGateway` on the gateway ARN.

## Clean up

```bash
./scripts/teardown.sh
```

Deletes the Lambda, target, gateway, credential provider, and both roles. Nothing else in your account is touched.

## Limits

- An API key is fixed to the group it was created in. `switch_group` to a different group returns `403 "API key access is restricted to its own group"`.
- Operata rate-limits to 100 requests per minute per key, shared across every caller of the gateway.
- The gateway indexes the tool list when the target is created. After Operata changes a tool, re-run `deploy-gateway.sh` or call `SynchronizeGatewayTargets`.
- `deploy-gateway.sh` sets `exceptionLevel: DEBUG` so target errors come back readable. Remove it before production, because it exposes upstream detail in responses.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Operata returned HTTP 401 for this key` during preflight | The key belongs to the other environment, or came from Settings → Config → API instead of Group Settings → API Management. |
| `403 Insufficient permissions` on the first Lambda run | The execution role is not visible to the gateway yet. `run-incident.sh` waits and retries once; if it persists, check `bedrock-agentcore:InvokeGateway` names the gateway ARN. |
| Target reaches `SYNCHRONIZE_UNSUCCESSFUL` | The gateway could not complete `tools/list` upstream. Read `statusReasons` on the target. |
| `temperature is deprecated for this model` | Newer Claude models reject `temperature` in `inferenceConfig`. Remove it. |
| `Unsupported protocol version` | The client negotiates from what the gateway advertises. Remove any pinned version. |
| `curl lacks --aws-sigv4` | curl is older than 7.75. On macOS, `brew install curl`. |

More failure modes in [MCP troubleshooting](https://docs.operata.com/docs/guides-mcp-troubleshooting).

## License

Apache 2.0. See [LICENSE](LICENSE).
